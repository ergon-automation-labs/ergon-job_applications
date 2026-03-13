defmodule BotArmyJobApplications.NATS.Consumer do
  @moduledoc """
  NATS consumer for Job Applications bot.

  Subscribes to:
  - job.application.create — new application
  - job.application.command.transition — state transitions
  - job.application.artifact.request — artifact generation
  - events.llm.completion — LLM responses (routed by source_metadata.source_domain)
  - job.pipeline.query — request/reply queries

  Phase 1 (manual pipeline): Minimal subscriptions for artifact generation.
  Phase 2 (email + discovery): Full email watcher and scraper integration.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Route decoded message to appropriate handler based on event type.
  """
  def route_message(message) do
    event = message["event"]
    source_metadata = message["source_metadata"] || %{}

    case event do
      "job.application.create" ->
        BotArmyJobApplications.Handlers.ApplicationHandler.handle_create(message)

      "job.application.command.transition" ->
        BotArmyJobApplications.Handlers.ApplicationHandler.handle_transition(message)

      "job.application.artifact.request" ->
        BotArmyJobApplications.Handlers.ArtifactHandler.handle_request(message)

      "llm.completion" ->
        source_domain = source_metadata["source_domain"]
        route_llm_response(source_domain, message)

      _ ->
        Logger.debug("Unknown event type: #{event}")
    end
  end

  # Private helpers

  defp route_llm_response(source_domain, message) do
    case source_domain do
      "jd_analysis" ->
        BotArmyJobApplications.Handlers.ArtifactHandler.handle_jd_analysis_response(message)

      "cover_letter" ->
        BotArmyJobApplications.Handlers.ArtifactHandler.handle_cover_letter_response(message)

      _ ->
        Logger.debug("Unknown LLM response source_domain: #{source_domain}")
    end
  end

  # Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting job applications NATS consumer")

    state = %{
      subscriptions: [],
      conn: nil,
      opts: opts
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000) do
      {:ok, conn} ->
        Logger.info("Connected to NATS, subscribing to job applications topics")

        subscriptions =
          [
            "job.application.create",
            "job.application.command.transition",
            "job.application.artifact.request",
            "events.llm.completion",
            "job.pipeline.query"
          ]
          |> Enum.map(fn subject ->
            case Gnat.sub(conn, self(), subject) do
              {:ok, sub} ->
                Logger.info("Job applications consumer subscribed to #{subject}")
                sub

              {:error, reason} ->
                Logger.error("Failed to subscribe to #{subject}: #{inspect(reason)}")
                nil
            end
          end)
          |> Enum.filter(&(not is_nil(&1)))

        {:noreply, %{state | subscriptions: subscriptions, conn: conn}}

      {:error, _reason} ->
        Logger.warning("NATS connection not ready, will retry")
        Process.send_after(self(), :connect_retry, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:connect_retry, state) do
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info({:msg, %{topic: "job.pipeline.query", reply_to: reply_to} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply pattern for pipeline info
    response =
      Jason.encode!(%{
        status: "ok",
        applications_count: get_applications_count()
      })

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    Logger.debug("Received NATS message on subject: #{msg.topic}")

    case BotArmyCore.NATS.Decoder.decode(msg.body) do
      {:ok, decoded_message} ->
        route_message(decoded_message)

      {:error, reason} ->
        Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will attempt to reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Connected to NATS")
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to NATS")
    {:noreply, state}
  end

  defp get_applications_count do
    case BotArmyJobApplications.Repo.aggregate(BotArmyJobApplications.Schemas.Application, :count) do
      count when is_integer(count) -> count
      _ -> 0
    end
  rescue
    _ -> 0
  end
end
