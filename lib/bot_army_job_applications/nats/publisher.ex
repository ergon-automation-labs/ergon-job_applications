defmodule BotArmyJobApplications.NATS.Publisher do
  @moduledoc """
  NATS event publisher for the job applications bot.

  Publishes job application events (created, state updated, artifact results, etc.)
  and LLM requests for artifact generation.
  """

  require Logger

  @doc """
  Publish an event to NATS.

  The event map should contain:
  - "event" - Event type
  - "event_id" - Unique event identifier
  - "timestamp" - ISO8601 timestamp
  - "source" - Source bot
  - "source_node" - Node name
  - "triggered_by" - Audit value
  - "schema_version" - Schema version
  - "payload" - Event payload

  Returns :ok if successful, or {:error, reason} on failure.
  """
  def publish(event) when is_map(event) do
    try do
      subject = derive_subject(event["event"])
      body = Jason.encode!(event)

      case do_publish(subject, body) do
        {:ok, _subject} ->
          Logger.debug("Published event to #{subject}")
          :ok

        :ok ->
          Logger.debug("Published event to #{subject}")
          :ok

        {:error, reason} ->
          Logger.error("Failed to publish to #{subject}: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      e ->
        Logger.error("Exception during publish: #{inspect(e)}")
        {:error, e}
    end
  end

  def publish(_) do
    {:error, :invalid_event}
  end

  @doc """
  Publish an LLM request for artifact generation.
  """
  def publish_llm_request(payload, source_domain, application_id) do
    request = %{
      "event" => "llm.response.parse",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "source_metadata" => %{
        "source_domain" => source_domain,
        "application_id" => application_id
      },
      "payload" => payload
    }

    publish(request)
  end

  @doc """
  Publish an error event.
  """
  def publish_error(event_id, reason, message) do
    error_event = %{
      "event" => "job.error",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "error" => message,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    publish(error_event)
  end

  # Private functions

  defp do_publish(subject, body) do
    case Jason.decode(body) do
      {:ok, payload} ->
        BotArmyRuntime.NATS.Publisher.publish(subject, payload)

      {:error, reason} ->
        Logger.error("Failed to decode body for #{subject}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp derive_subject(event_type) when is_binary(event_type) do
    case event_type do
      "job.application.created" -> "events.job.application.created"
      "job.application.state.updated" -> "events.job.application.state.updated"
      "job.application.artifact.result" -> "events.job.application.artifact.result"
      "job.error" -> "events.job.error"
      "llm.response.parse" -> "llm.response.parse"
      "gtd.inbox.add" -> "gtd.inbox.add"
      _ -> "events.job.unknown"
    end
  end

  defp derive_subject(_) do
    "events.job.unknown"
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end
