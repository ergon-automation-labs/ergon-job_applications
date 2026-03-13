defmodule BotArmyJobApplications.Handlers.ApplicationHandler do
  @moduledoc """
  Handles job application lifecycle events.

  Processes:
  - job.application.create - Create new application
  - job.application.command.transition - State transitions
  - Integration with GTD inbox on key transitions
  """

  require Logger

  @gtd_trigger_states ["phone_screen", "technical", "offer"]

  defp application_store do
    Application.get_env(:bot_army_job_applications, :application_store, BotArmyJobApplications.ApplicationStore)
  end

  @doc """
  Handle application creation.

  Creates a new job application and starts the ApplicationServer.
  """
  def handle_create(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_create_payload(payload) do
      :ok ->
        case create_application(payload) do
          {:ok, application} ->
            # Start ApplicationServer for this application
            BotArmyJobApplications.ApplicationSupervisor.start_child(application["id"])

            Logger.info("Application created: #{application["id"]}, event_id: #{event_id}")
            publish_application_created(application, event_id)

          {:error, reason} ->
            Logger.error("Failed to create application: #{inspect(reason)}")
            BotArmyJobApplications.NATS.Publisher.publish_error(event_id, reason, "Failed to create application")
        end

      {:error, reason} ->
        Logger.warning("Invalid application creation payload: #{inspect(reason)}")
        BotArmyJobApplications.NATS.Publisher.publish_error(event_id, reason, "Invalid application data")
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

        case BotArmyJobApplications.ApplicationServer.transition(application_id, to_state, metadata) do
          {:ok, application} ->
            Logger.info("Application transitioned to #{to_state}: #{application_id}")

            # Publish state updated event
            publish_state_updated(application, event_id)

            # Handle GTD integration
            if to_state in @gtd_trigger_states do
              create_gtd_task(application, to_state)
            end

          {:error, :invalid_transition} ->
            Logger.warning("Invalid transition for application: #{application_id}")
            BotArmyJobApplications.NATS.Publisher.publish_error(
              event_id,
              :invalid_transition,
              "Invalid state transition"
            )

          {:error, :not_found} ->
            Logger.error("Application not found: #{application_id}")
            BotArmyJobApplications.NATS.Publisher.publish_error(
              event_id,
              :not_found,
              "Application not found"
            )

          {:error, reason} ->
            Logger.error("Failed to transition application: #{inspect(reason)}")
            BotArmyJobApplications.NATS.Publisher.publish_error(event_id, reason, "Failed to transition application")
        end

      {:error, reason} ->
        Logger.warning("Invalid transition payload: #{inspect(reason)}")
        BotArmyJobApplications.NATS.Publisher.publish_error(event_id, reason, "Invalid transition data")
    end
  end

  # Private helpers

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
          "transitioned_at" => NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601(),
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

    BotArmyJobApplications.NATS.Publisher.publish(event)
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

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp create_gtd_task(application, state) do
    # Create a GTD task for the application milestone
    task_title = case state do
      "phone_screen" -> "Phone screen: #{application["company"]} - #{application["role_title"]}"
      "technical" -> "Technical interview: #{application["company"]} - #{application["role_title"]}"
      "offer" -> "Offer negotiation: #{application["company"]} - #{application["role_title"]}"
      _ -> "Follow up: #{application["company"]} - #{application["role_title"]}"
    end

    task_context = case state do
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

    BotArmyJobApplications.NATS.Publisher.publish(gtd_event)
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end
