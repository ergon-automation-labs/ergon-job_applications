defmodule BotArmyJobApplications.Handlers.DigestHandler do
  @moduledoc """
  Handles daily digest generation for job applications.

  Builds a structured summary of job application status:
  - Categorizes applications (pending_signals, recent_activity, stalled)
  - Publishes a NATS event (events.job.application.digest.ready)
  - Publishes a GTD inbox task with brief plaintext summary

  Called by DigestScheduler every 24 hours, or on-demand via job.digest.request.
  """

  require Logger

  @terminal_states ~w(accepted declined rejected ghosted)
  @stale_days 7

  def application_store do
    Application.get_env(:bot_army_job_applications, :application_store, BotArmyJobApplications.ApplicationStore)
  end

  @doc """
  Build a digest map from applications list.

  Returns map with keys:
  - generated_at: ISO8601 timestamp
  - total_active: count of non-terminal applications
  - total_terminal: count of terminal applications
  - by_state: %{state => count} for active applications
  - pending_signals: list of %{company, role_title, signal_type, proposed_transition}
  - recent_activity: list of state changes in last 24 hours
  - stalled: list of applications not updated for 7+ days
  """
  def build_digest(applications) when is_list(applications) do
    now = DateTime.utc_now()
    {terminal, active} = Enum.split_with(applications, &terminal?/1)

    %{
      "generated_at" => DateTime.to_iso8601(now),
      "total_active" => length(active),
      "total_terminal" => length(terminal),
      "by_state" => count_by_state(active),
      "pending_signals" => pending_signals(active),
      "recent_activity" => recent_activity(active, now),
      "stalled" => stalled(active, now)
    }
  end

  @doc """
  Handle a digest request message (job.digest.request).

  Queries all applications, builds digest, and publishes to NATS.
  """
  def handle_request(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    case application_store().list(tenant_id) do
      {:ok, apps} ->
        digest = build_digest(apps)
        publish_digest(digest, message["event_id"], tenant_id, user_id)

      {:error, reason} ->
        Logger.error("Digest request failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Publish digest to NATS and GTD inbox.
  """
  def publish_digest(digest, triggered_by_event_id, tenant_id, user_id) do
    # Publish NATS digest event
    event = %{
      "event" => "job.application.digest.ready",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => digest
    }

    if triggered_by_event_id do
      event = Map.put(event, "triggered_by_event_id", triggered_by_event_id)
      BotArmyJobApplications.NATS.Publisher.publish(event)
    else
      BotArmyJobApplications.NATS.Publisher.publish(event)
    end

    # Publish GTD inbox task (if GTD integration enabled)
    if Application.get_env(:bot_army_job_applications, :enable_gtd_integration, true) do
      publish_gtd_digest(digest, tenant_id, user_id)
    end
  end

  # Private helpers

  defp terminal?(app) do
    state = app["state"] || ""
    Enum.member?(@terminal_states, state)
  end

  defp count_by_state(applications) do
    applications
    |> Enum.group_by(&Map.get(&1, "state"))
    |> Enum.reduce(%{}, fn {state, apps}, acc ->
      Map.put(acc, state, length(apps))
    end)
  end

  defp pending_signals(applications) do
    applications
    |> Enum.filter(&Map.get(&1, "pending_signal"))
    |> Enum.map(fn app ->
      signal = app["pending_signal"]

      %{
        "company" => app["company"],
        "role_title" => app["role_title"],
        "signal_type" => signal["type"],
        "proposed_transition" => signal["proposed_transition"]
      }
    end)
  end

  defp recent_activity(applications, now) do
    one_day_ago = DateTime.add(now, -86400, :second)

    applications
    |> Enum.flat_map(fn app ->
      history = app["history"] || []

      history
      |> Enum.filter(fn entry ->
        case parse_iso8601(entry["transitioned_at"]) do
          {:ok, ts} -> DateTime.compare(ts, one_day_ago) != :lt
          :error -> false
        end
      end)
      |> Enum.map(fn entry ->
        %{
          "company" => app["company"],
          "role_title" => app["role_title"],
          "from_state" => entry["from_state"],
          "to_state" => entry["to_state"],
          "transitioned_at" => entry["transitioned_at"]
        }
      end)
    end)
  end

  defp stalled(applications, now) do
    stale_threshold = DateTime.add(now, -(@stale_days * 86400), :second)

    applications
    |> Enum.filter(fn app ->
      case parse_iso8601(app["updated_at"]) do
        {:ok, updated_at} -> DateTime.compare(updated_at, stale_threshold) == :lt
        :error -> false
      end
    end)
    |> Enum.map(fn app ->
      days_since = days_since_update(app["updated_at"], now)

      %{
        "company" => app["company"],
        "role_title" => app["role_title"],
        "state" => app["state"],
        "days_since_update" => days_since
      }
    end)
  end

  defp days_since_update(updated_at_iso, now) do
    case parse_iso8601(updated_at_iso) do
      {:ok, updated_at} ->
        diff_seconds = DateTime.diff(now, updated_at, :second)
        div(diff_seconds, 86400)

      :error ->
        0
    end
  end

  defp parse_iso8601(iso_string) when is_binary(iso_string) do
    DateTime.from_iso8601(iso_string)
    |> case do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, _reason} -> :error
    end
  end

  defp parse_iso8601(_), do: :error

  defp publish_gtd_digest(digest, tenant_id, user_id) do
    active = digest["total_active"]
    signals = length(digest["pending_signals"] || [])
    stalled_count = length(digest["stalled"] || [])

    title_parts = ["Job search: #{active} active"]
    title_parts = if signals > 0, do: title_parts ++ ["#{signals} signal(s) to review"], else: title_parts
    title_parts = if stalled_count > 0, do: title_parts ++ ["#{stalled_count} stalled"], else: title_parts

    title = Enum.join(title_parts, " · ")

    gtd_event = %{
      "event" => "gtd.inbox.add",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "title" => title,
        "context" => "recruiting",
        "source" => "job_applications_bot",
        "source_metadata" => %{
          "digest" => true,
          "generated_at" => digest["generated_at"],
          "active" => digest["total_active"],
          "signals" => signals,
          "stalled" => stalled_count
        }
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(gtd_event)
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end
