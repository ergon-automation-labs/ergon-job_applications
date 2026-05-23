defmodule BotArmyJobApplications.Handlers.RankingHandler do
  @moduledoc """
  Handles job application ranking requests.

  Processes:
  - job.application.command.rank — Request ranked applications

  Response includes applications ranked by actionability score (0-1).
  """

  require Logger

  alias BotArmyJobApplications.{ApplicationStore, Ranking, NATS.Publisher}

  @doc """
  Handle ranking request.

  Payload:
  ```json
  {
    "limit": 10,           // optional, defaults to all
    "tier": "high"         // optional: high|medium|low for filtering
  }
  ```

  Response event: `events.job.application.ranked`
  ```json
  {
    "applications": [
      {
        "id": "...",
        "company": "...",
        "role_title": "...",
        "score": 0.92,
        "state": "ready_to_submit"
      }
    ],
    "total": 3,
    "limit": 10
  }
  ```
  """
  def handle_rank(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_rank_payload(payload) do
      :ok ->
        limit = Map.get(payload, "limit")
        tier_filter = Map.get(payload, "tier")

        case rank_applications(limit, tier_filter, tenant_id) do
          {:ok, ranked_apps, total} ->
            Logger.info("Ranked #{length(ranked_apps)} applications, event_id: #{event_id}")
            publish_ranked(ranked_apps, total, limit, event_id, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Failed to rank applications: #{inspect(reason)}")
            Publisher.publish_error(event_id, reason, "Failed to rank applications")
        end

      {:error, reason} ->
        Logger.warning("Invalid ranking request: #{inspect(reason)}")
        Publisher.publish_error(event_id, reason, "Invalid ranking request")
    end
  end

  # Private helpers

  defp validate_rank_payload(payload) when is_map(payload) do
    # All fields are optional
    case Map.get(payload, "tier") do
      nil -> :ok
      tier when tier in ["high", "medium", "low"] -> :ok
      _ -> {:error, "tier must be high, medium, or low"}
    end
  end

  defp validate_rank_payload(_), do: {:error, "payload must be a map"}

  defp rank_applications(limit, tier_filter, tenant_id) do
    try do
      applications = ApplicationStore.list(tenant_id)
      total = length(applications)
      ranked = Ranking.rank(applications)

      filtered = apply_tier_filter(ranked, tier_filter)
      result = apply_limit(filtered, limit)
      response_apps = format_response(result)

      {:ok, response_apps, total}
    rescue
      reason ->
        {:error, reason}
    end
  end

  defp apply_tier_filter(ranked, "high") do
    Enum.filter(ranked, fn {_, score} -> score >= 0.75 end)
  end

  defp apply_tier_filter(ranked, "medium") do
    Enum.filter(ranked, fn {_, score} -> score >= 0.50 and score < 0.75 end)
  end

  defp apply_tier_filter(ranked, "low") do
    Enum.filter(ranked, fn {_, score} -> score < 0.50 end)
  end

  defp apply_tier_filter(ranked, _), do: ranked

  defp apply_limit(filtered, n) when is_integer(n) and n > 0 do
    Enum.take(filtered, n)
  end

  defp apply_limit(filtered, _), do: filtered

  defp format_response(result) do
    Enum.map(result, fn {app, score} ->
      %{
        "id" => app["id"],
        "company" => app["company"],
        "role_title" => app["role_title"],
        "score" => Float.round(score, 3),
        "state" => app["state"],
        "coverage_score" => app["coverage_score"],
        "salary_range" => app["salary_range"]
      }
    end)
  end

  defp publish_ranked(applications, total, limit, event_id, tenant_id, user_id) do
    event = %{
      "event" => "job.application.ranked",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "applications" => applications,
        "total" => total,
        "limit" => limit || "all",
        "count" => length(applications),
        "triggered_by_event_id" => event_id
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
    Logger.info("Published ranked applications event, event_id: #{event_id}")
  end

  defp get_node_name do
    case System.get_env("NODE_NAME") do
      nil -> "unknown"
      node -> node
    end
  end
end
