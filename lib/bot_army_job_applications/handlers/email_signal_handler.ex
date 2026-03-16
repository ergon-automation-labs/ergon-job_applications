defmodule BotArmyJobApplications.Handlers.EmailSignalHandler do
  @moduledoc """
  Handles email signals from the email triage bot.

  Maps incoming recruiter emails (interview requests, phone screens, offers, rejections)
  to job applications by matching company name. Stores pending signals for user confirmation
  before applying state transitions.

  Email signals are never auto-applied. Always presented to user for confirmation.
  """

  require Logger

  # Signal type mapping: email match_type -> {signal_type, proposed_transition}
  @signal_map %{
    "interview_request" => %{"type" => "interview_invite", "proposed" => "phone_screen"},
    "phone_screen" => %{"type" => "interview_invite", "proposed" => "phone_screen"},
    "offer" => %{"type" => "offer", "proposed" => "offer"},
    "rejection" => %{"type" => "rejection", "proposed" => "rejected"}
  }

  defp application_store do
    Application.get_env(:bot_army_job_applications, :application_store, BotArmyJobApplications.ApplicationStore)
  end

  @doc """
  Handle an email signal from the email triage bot.

  The email signal is matched against existing applications by company name.
  If a match is found, a pending_signal is stored for user confirmation.

  Returns:
  - {:ok, {:signal_detected, signal}} if matched
  - {:ok, :no_match} if no matching application found
  - {:error, :invalid_payload} if required fields are missing
  """
  def handle_email_signal(message) do
    payload = message["payload"]

    case validate_payload(payload) do
      :ok ->
        match_type = payload["match_type"]

        case Map.get(@signal_map, match_type) do
          nil ->
            Logger.warning("Unknown email signal match_type: #{match_type}")
            {:ok, :no_match}

          signal_template ->
            process_signal(message, payload, signal_template)
        end

      {:error, reason} ->
        Logger.warning("Invalid email signal payload: #{inspect(reason)}")
        {:error, :invalid_payload}
    end
  end

  # Private helpers

  defp validate_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "match_type") do
      :ok
    else
      err -> err
    end
  end

  defp validate_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp process_signal(message, payload, signal_template) do
    # Build the pending signal map
    signal = %{
      "type" => signal_template["type"],
      "proposed_transition" => signal_template["proposed"],
      "email_id" => payload["message_id"],
      "from_address" => payload["from"],
      "subject_line" => payload["subject"],
      "confidence" => Map.get(payload, "confidence", 0.0),
      "detected_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    # Match email to application by company name
    case find_matching_application(payload) do
      {:ok, application} ->
        application_id = application["id"]

        # Update application with pending_signal
        case application_store().update(application_id, %{"pending_signal" => signal}) do
          {:ok, updated_app} ->
            Logger.info("Email signal detected for application: #{application_id}")
            publish_signal_detected(updated_app, signal, message["event_id"])
            {:ok, {:signal_detected, signal}}

          {:error, reason} ->
            Logger.error("Failed to store pending signal for #{application_id}: #{inspect(reason)}")
            {:error, reason}
        end

      :no_match ->
        Logger.debug("No matching application found for email signal")
        {:ok, :no_match}
    end
  end

  defp find_matching_application(payload) do
    match_text = extract_match_text(payload)

    case application_store().list() do
      {:ok, applications} ->
        # Try to find application by company name match
        case Enum.find(applications, &application_matches?(&1, match_text)) do
          nil -> :no_match
          app -> {:ok, app}
        end

      {:error, reason} ->
        Logger.error("Failed to list applications: #{inspect(reason)}")
        :no_match
    end
  end

  defp extract_match_text(payload) do
    # Prefer subject line, fallback to from domain
    subject = String.downcase(payload["subject"] || "")
    from = String.downcase(payload["from"] || "")
    %{"subject" => subject, "from" => from}
  end

  defp application_matches?(application, match_text) do
    company = String.downcase(application["company"] || "")
    subject = match_text["subject"]
    from = match_text["from"]

    # Check if company name appears in subject line
    String.contains?(subject, company) or
      # Or if company name appears in email domain
      contains_company_in_domain(from, company)
  end

  defp contains_company_in_domain(email, company) do
    # Extract domain from email
    case String.split(email, "@") do
      [_local, domain] ->
        # Normalize domain: remove common TLDs and separators
        domain_normalized = String.downcase(domain)
        company_normalized = String.downcase(company)

        # Check if company slug appears in domain
        String.contains?(domain_normalized, company_normalized)

      _ ->
        false
    end
  end

  defp publish_signal_detected(application, signal, event_id) do
    event = %{
      "event" => "job.application.signal.detected",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "application_id" => application["id"],
        "company" => application["company"],
        "role_title" => application["role_title"],
        "signal" => signal,
        "triggered_by_event_id" => event_id
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end
