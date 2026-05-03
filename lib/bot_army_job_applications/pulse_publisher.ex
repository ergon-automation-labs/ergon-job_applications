defmodule BotArmyJobApplications.PulsePublisher do
  @moduledoc """
  Publishes periodic health pulses from Job Applications bot to Synapse.

  Job Applications reports on job opportunity processing:
  - Listings fetched and processed
  - Match quality scores and distribution
  - Target industries and skill matches
  - Application pipeline health

  This helps Synapse understand:
  - Whether job pipeline is active
  - Match quality and relevance of opportunities
  - Which industries have fresh listings
  - User opportunity coverage

  Pulse format:
    {
      "bot": "job_applications",
      "timestamp": "2026-04-25T10:25:00Z",
      "observations": {
        "listings_processed": N,
        "avg_match_score": X.X,
        "industries_active": ["...", ...],
        "high_quality_matches": N,
        "health_signal": "nominal|degraded|critical"
      }
    }
  """

  use GenServer
  require Logger

  @health_interval_ms 30 * 1000
  # 5 minutes
  @publish_interval_ms 30 * 60 * 1000
  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @impl true
  def init(_opts) do
    Logger.info("[PulsePublisher] Starting Job Applications pulse publisher")

    state = %{
      listings_processed: 0,
      total_match_score: 0.0,
      high_quality_matches: 0,
      industries_active: MapSet.new()
    }

    Process.send_after(self(), :publish_pulse, @publish_interval_ms)
    Process.send_after(self(), :publish_health, 2_000)
    {:ok, state}
  end

  @impl true
  def handle_info(:publish_health, state) do
    health_signal =
      cond do
        state.listings_processed == 0 -> "degraded"
        state.high_quality_matches == 0 -> "degraded"
        true -> "nominal"
      end

    BotArmyRuntime.SynapseHealth.publish(
      source: "bot_army_job_applications",
      service: "job_applications",
      health_signal: health_signal
    )

    Process.send_after(self(), :publish_health, @health_interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info(:publish_pulse, state) do
    Task.start(fn -> publish_pulse(state) end)
    Process.send_after(self(), :publish_pulse, @publish_interval_ms)

    # Reset counters for next period
    new_state = %{
      state
      | listings_processed: 0,
        total_match_score: 0.0,
        high_quality_matches: 0,
        industries_active: MapSet.new()
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:record_listing, match_score, industry}, _from, state) do
    is_high_quality = match_score >= 0.75

    new_state = %{
      state
      | listings_processed: state.listings_processed + 1,
        total_match_score: state.total_match_score + match_score,
        high_quality_matches: state.high_quality_matches + if(is_high_quality, do: 1, else: 0),
        industries_active: MapSet.put(state.industries_active, industry)
    }

    {:reply, :ok, new_state}
  end

  # API for other modules
  def record_listing(match_score, industry) when is_float(match_score) and is_binary(industry) do
    try do
      GenServer.call(@server, {:record_listing, match_score, industry})
    catch
      :exit, _ -> :ok
    end
  end

  # Private

  defp publish_pulse(state) do
    pulse = build_pulse(state)
    publish_to_nats(pulse)
  end

  defp build_pulse(state) do
    avg_match_score =
      if state.listings_processed > 0,
        do: state.total_match_score / state.listings_processed,
        else: 0.0

    health_signal =
      cond do
        state.listings_processed == 0 -> "degraded"
        state.high_quality_matches == 0 -> "degraded"
        true -> "nominal"
      end

    %{
      "bot" => "job_applications",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "observations" => %{
        "listings_processed" => state.listings_processed,
        "avg_match_score" => Float.round(avg_match_score, 2),
        "high_quality_matches" => state.high_quality_matches,
        "industries_active" => MapSet.to_list(state.industries_active),
        "health_signal" => health_signal
      }
    }
  end

  defp publish_to_nats(pulse) do
    try do
      case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5_000) do
        {:ok, conn} ->
          json = Jason.encode!(pulse)

          case Gnat.pub(conn, "bot.job_applications.pulse", json) do
            :ok ->
              Logger.debug("[PulsePublisher] Published Job Applications pulse")

            {:error, reason} ->
              Logger.warning("[PulsePublisher] Failed to publish pulse: #{inspect(reason)}")
          end

        {:error, reason} ->
          Logger.warning("[PulsePublisher] NATS unavailable, skipping pulse: #{inspect(reason)}")
      end
    rescue
      e ->
        Logger.warning("[PulsePublisher] Error publishing pulse: #{inspect(e)}")
    end
  end
end
