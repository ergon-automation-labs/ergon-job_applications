defmodule BotArmyJobApplications.Handlers.ApplicationHandler do
  @moduledoc """
  Handles job application lifecycle events.

  Processes:
  - job.application.create - Create new application
  - job.application.command.transition - State transitions
  - Integration with GTD inbox on key transitions
  """

  require Logger

  alias BotArmyJobApplications.ApplicationStore
  alias BotArmyJobApplications.ListingStore
  alias BotArmyJobApplications.ApplicationSupervisor
  alias BotArmyJobApplications.ApplicationServer
  alias BotArmyJobApplications.NATS.Publisher
  alias BotArmyCore.Tenant

  @gtd_trigger_states ["phone_screen", "technical", "offer"]

  defp application_store do
    Application.get_env(
      :bot_army_job_applications,
      :application_store,
      ApplicationStore
    )
  end

  defp listing_store do
    Application.get_env(
      :bot_army_job_applications,
      :listing_store,
      ListingStore
    )
  end

  @doc """
  Handle application creation.

  Creates a new job application and starts the ApplicationServer.
  """
  def handle_create(message) do
    %{tenant_id: tenant_id, user_id: user_id} = Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"] || %{}

    # Enrich payload with listing data if listing_id is provided
    enriched_payload = enrich_payload_from_listing(payload, tenant_id)

    # Stamp payload with tenant/user context
    stamped_payload =
      Map.merge(enriched_payload, %{
        "tenant_id" => tenant_id,
        "user_id" => user_id
      })

    case validate_create_payload(stamped_payload) do
      :ok ->
        case create_application(stamped_payload) do
          {:ok, application} ->
            # Start ApplicationServer for this application
            ApplicationSupervisor.start_child(application["id"])

            Logger.info("Application created: #{application["id"]}, event_id: #{event_id}")
            publish_application_created(application, event_id)

          {:error, reason} ->
            Logger.error("Failed to create application: #{inspect(reason)}")

            Publisher.publish_error(
              event_id,
              reason,
              "Failed to create application"
            )
        end

      {:error, reason} ->
        Logger.warning("Invalid application creation payload: #{inspect(reason)}")

        Publisher.publish_error(
          event_id,
          reason,
          "Invalid application data"
        )
    end
  end

  @doc """
  Handle confirmation of a pending email signal.

  Reads the pending signal's proposed transition and applies it,
  then clears the pending signal.
  """
  def handle_confirm_signal(message) do
    %{tenant_id: tenant_id, user_id: _user_id} = Tenant.extract_context(message)
    payload = message["payload"]
    event_id = message["event_id"]

    case validate_application_payload(payload) do
      :ok ->
        application_id = payload["application_id"]

        case application_store().get(tenant_id, application_id) do
          {:ok, application} ->
            pending_signal = application["pending_signal"]

            if pending_signal do
              to_state = pending_signal["proposed_transition"]

              metadata = %{
                "triggered_by" => "email_signal_confirmed",
                "signal_type" => pending_signal["type"]
              }

              # Transition to the proposed state
              case ApplicationServer.transition(
                     application_id,
                     to_state,
                     metadata
                   ) do
                {:ok, _updated_app} ->
                  # Clear the pending signal
                  case application_store().update(tenant_id, application_id, %{
                         "pending_signal" => nil
                       }) do
                    {:ok, updated_app} ->
                      Logger.info(
                        "Confirmed email signal for application: #{application_id}, transitioned to #{to_state}"
                      )

                      publish_signal_cleared(updated_app, event_id)

                    {:error, reason} ->
                      Logger.error(
                        "Failed to clear pending signal for #{application_id}: #{inspect(reason)}"
                      )
                  end

                {:error, reason} ->
                  Logger.error(
                    "Failed to transition application #{application_id}: #{inspect(reason)}"
                  )

                  Publisher.publish_error(
                    event_id,
                    reason,
                    "Failed to confirm signal"
                  )
              end
            else
              Logger.warning("No pending signal found for application: #{application_id}")
            end

          {:error, :not_found} ->
            Logger.error("Application not found: #{application_id}")

            Publisher.publish_error(
              event_id,
              :not_found,
              "Application not found"
            )

          {:error, reason} ->
            Logger.error("Failed to get application #{application_id}: #{inspect(reason)}")

            Publisher.publish_error(
              event_id,
              reason,
              "Failed to confirm signal"
            )
        end

      {:error, reason} ->
        Logger.warning("Invalid confirm signal payload: #{inspect(reason)}")

        Publisher.publish_error(
          event_id,
          reason,
          "Invalid confirm signal data"
        )
    end
  end

  @doc """
  Handle dismissal of a pending email signal.

  Clears the pending signal without applying any state transition.
  """
  def handle_dismiss_signal(message) do
    %{tenant_id: tenant_id} = Tenant.extract_context(message)
    payload = message["payload"]
    event_id = message["event_id"]

    case validate_application_payload(payload) do
      :ok ->
        application_id = payload["application_id"]

        case application_store().update(tenant_id, application_id, %{"pending_signal" => nil}) do
          {:ok, updated_app} ->
            Logger.info("Dismissed email signal for application: #{application_id}")
            publish_signal_cleared(updated_app, event_id)

          {:error, :not_found} ->
            Logger.error("Application not found: #{application_id}")

            Publisher.publish_error(
              event_id,
              :not_found,
              "Application not found"
            )

          {:error, reason} ->
            Logger.error("Failed to dismiss signal for #{application_id}: #{inspect(reason)}")

            Publisher.publish_error(
              event_id,
              reason,
              "Failed to dismiss signal"
            )
        end

      {:error, reason} ->
        Logger.warning("Invalid dismiss signal payload: #{inspect(reason)}")

        Publisher.publish_error(
          event_id,
          reason,
          "Invalid dismiss signal data"
        )
    end
  end

  @doc """
  Handle application state transition.

  Validates transition, updates database, publishes events, and handles GTD integration.
  """
  def handle_transition(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_transition_payload(payload) do
      :ok ->
        application_id = payload["application_id"]
        to_state = payload["to_state"]
        metadata = Map.get(payload, "metadata", %{})

        case ApplicationServer.transition(
               application_id,
               to_state,
               metadata
             ) do
          {:ok, application} ->
            Logger.info("Application transitioned to #{to_state}: #{application_id}")

            # Publish state updated event
            publish_state_updated(application, event_id)

            # Handle GTD integration (only for valid applications, if enabled)
            if Application.get_env(:bot_army_job_applications, :enable_gtd_integration, true) do
              if to_state in @gtd_trigger_states and is_valid_for_gtd?(application) do
                create_gtd_task(application, to_state)
              end
            end

          {:error, :invalid_transition} ->
            Logger.warning("Invalid transition for application: #{application_id}")

            Publisher.publish_error(
              event_id,
              :invalid_transition,
              "Invalid state transition"
            )

          {:error, :not_found} ->
            Logger.error("Application not found: #{application_id}")

            Publisher.publish_error(
              event_id,
              :not_found,
              "Application not found"
            )

          {:error, reason} ->
            Logger.error("Failed to transition application: #{inspect(reason)}")

            Publisher.publish_error(
              event_id,
              reason,
              "Failed to transition application"
            )
        end

      {:error, reason} ->
        Logger.warning("Invalid transition payload: #{inspect(reason)}")

        Publisher.publish_error(
          event_id,
          reason,
          "Invalid transition data"
        )
    end
  end

  # Private helpers

  defp enrich_payload_from_listing(payload, tenant_id) when is_map(payload) do
    listing_id = payload["listing_id"]

    if listing_id && listing_id != "" do
      case listing_store().get(tenant_id, listing_id) do
        {:ok, listing} ->
          # Merge listing data into payload, preferring explicit fields over listing defaults
          payload
          |> Map.put_new("company", listing["company"])
          |> Map.put_new("role_title", listing["role_title"] || listing["title"])
          |> Map.put_new("jd_url", listing["jd_url"])
          |> Map.put("listing_id", listing_id)

        {:error, _reason} ->
          Logger.warning("Could not find listing #{listing_id}")
          payload
      end
    else
      payload
    end
  end

  defp validate_create_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "company"),
         :ok <- require_field(payload, "role_title") do
      :ok
    else
      err -> err
    end
  end

  defp validate_create_payload(_), do: {:error, :invalid_payload}

  defp validate_transition_payload(payload) when is_map(payload) do
    with :ok <- require_field(payload, "application_id"),
         :ok <- require_field(payload, "to_state") do
      :ok
    else
      err -> err
    end
  end

  defp validate_transition_payload(_), do: {:error, :invalid_payload}

  defp validate_application_payload(payload) when is_map(payload) do
    case require_field(payload, "application_id") do
      :ok -> :ok
      err -> err
    end
  end

  defp validate_application_payload(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp create_application(payload) do
    application_store().create(%{
      "company" => payload["company"],
      "role_title" => payload["role_title"],
      "listing_id" => Map.get(payload, "listing_id"),
      "jd_text" => Map.get(payload, "jd_text"),
      "jd_url" => Map.get(payload, "jd_url"),
      "salary_range" => Map.get(payload, "salary_range"),
      "state" => "identified",
      "history" => [
        %{
          "from_state" => nil,
          "to_state" => "identified",
          "transitioned_at" =>
            NaiveDateTime.utc_now()
            |> NaiveDateTime.truncate(:second)
            |> NaiveDateTime.to_iso8601(),
          "metadata" => %{"reason" => "creation"}
        }
      ]
    })
  end

  defp publish_application_created(application, event_id) do
    event = %{
      "event" => "job.application.created",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "application" => application,
        "triggered_by_event_id" => event_id
      }
    }

    Publisher.publish(event)
  end

  defp publish_state_updated(application, event_id) do
    event = %{
      "event" => "job.application.state.updated",
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
        "state" => application["state"],
        "history" => application["history"],
        "triggered_by_event_id" => event_id
      }
    }

    Publisher.publish(event)
  end

  defp create_gtd_task(application, state) do
    # Create a GTD task for the application milestone
    task_title =
      case state do
        "phone_screen" ->
          "Phone screen: #{application["company"]} - #{application["role_title"]}"

        "technical" ->
          "Technical interview: #{application["company"]} - #{application["role_title"]}"

        "offer" ->
          "Offer negotiation: #{application["company"]} - #{application["role_title"]}"

        _ ->
          "Follow up: #{application["company"]} - #{application["role_title"]}"
      end

    task_context =
      case state do
        "phone_screen" -> "recruiting"
        "technical" -> "recruiting"
        "offer" -> "recruiting"
        _ -> "inbox"
      end

    gtd_payload = %{
      "title" => task_title,
      "context" => task_context,
      "source" => "job_applications_bot",
      "source_metadata" => %{
        "application_id" => application["id"],
        "state" => state
      }
    }

    # Publish to GTD bot inbox
    gtd_event = %{
      "event" => "gtd.inbox.add",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "payload" => gtd_payload
    }

    Publisher.publish(gtd_event)
  end

  defp is_valid_for_gtd?(application) do
    company = String.trim(application["company"] || "")
    role_title = String.trim(application["role_title"] || "")

    # Reject if either field is too short (likely test/dummy data)
    # Min 3 chars for realistic company/role names
    is_company_valid = String.length(company) >= 3
    is_role_valid = String.length(role_title) >= 3

    # Reject obviously fake combinations (e.g., "Buy" + "milk")
    is_not_suspicious = not is_suspicious_combo(company, role_title)

    unless is_company_valid and is_role_valid and is_not_suspicious do
      Logger.warning(
        "Filtered test/dummy application from GTD integration: " <>
          "company='#{company}', role_title='#{role_title}'"
      )
    end

    is_company_valid and is_role_valid and is_not_suspicious
  end

  defp is_suspicious_combo(company, role_title) do
    # List of patterns that indicate test/dummy data
    suspicious_patterns = [
      "buy",
      "test",
      "dummy",
      "fake",
      "sample",
      "example",
      "milk",
      "foo",
      "bar",
      "baz"
    ]

    company_lower = String.downcase(company)
    role_lower = String.downcase(role_title)

    # Check if either field matches suspicious patterns
    Enum.any?(suspicious_patterns, fn pattern ->
      String.contains?(company_lower, pattern) or String.contains?(role_lower, pattern)
    end)
  end

  defp publish_signal_cleared(application, event_id) do
    event = %{
      "event" => "job.application.signal.cleared",
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
        "triggered_by_event_id" => event_id
      }
    }

    Publisher.publish(event)
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end
