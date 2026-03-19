defmodule BotArmyJobApplications.NATS.Consumer do
  @moduledoc """
  NATS consumer for Job Applications bot.

  Subscribes to:
  - job.application.create — new application
  - job.application.command.transition — state transitions
  - job.application.command.rank — ranking request
  - job.application.artifact.request — artifact generation
  - job.resume.upload — resume file upload
  - job.resume.list — list all resumes (request/reply)
  - job.resume.get — get single resume (request/reply)
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

      "job.application.command.rank" ->
        BotArmyJobApplications.Handlers.RankingHandler.handle_rank(message)

      "job.application.command.confirm_signal" ->
        BotArmyJobApplications.Handlers.ApplicationHandler.handle_confirm_signal(message)

      "job.application.command.dismiss_signal" ->
        BotArmyJobApplications.Handlers.ApplicationHandler.handle_dismiss_signal(message)

      "job.application.artifact.request" ->
        BotArmyJobApplications.Handlers.ArtifactHandler.handle_request(message)

      "job.digest.request" ->
        BotArmyJobApplications.Handlers.DigestHandler.handle_request(message)

      "job.email.interview_request" ->
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      "job.email.phone_screen" ->
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      "job.email.offer" ->
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      "job.email.rejection" ->
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      "job.listings.ingest" ->
        payload = message["payload"] || message
        BotArmyJobApplications.Handlers.IngestHandler.handle_ingest(payload)

      "job.listings.fetch.request" ->
        BotArmyJobApplications.Ingestion.Worker.run_fetch()

      "job.resume.upload" ->
        BotArmyJobApplications.Handlers.ResumeParseHandler.handle_upload(message)

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

      "resume_parse" ->
        BotArmyJobApplications.Handlers.ResumeParseHandler.handle_parse_response(message)

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
            "job.application.command.rank",
            "job.application.command.confirm_signal",
            "job.application.command.dismiss_signal",
            "job.application.artifact.request",
            "job.digest.request",
            "job.email.interview_request",
            "job.email.phone_screen",
            "job.email.offer",
            "job.email.rejection",
            "job.listings.ingest",
            "job.listings.fetch.request",
            "job.resume.upload",
            "job.resume.list",
            "job.resume.get",
            "events.llm.completion",
            "job.pipeline.query",
            "job.application.get",
            "job.application.list",
            "job.listings.list",
            "requests.job_applications.snapshot",
            "commands.job_applications.create",
            "commands.job_applications.update",
            "commands.job_applications.update_status",
            "commands.job_applications.add_note",
            "commands.job_applications.delete"
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
  def handle_info({:msg, %{topic: "job.application.get", reply_to: reply_to, body: body} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return application by id for LiveView detail page
    response =
      case Jason.decode(body) do
        {:ok, %{"application_id" => app_id}} when is_binary(app_id) ->
          case application_store().get(app_id) do
            {:ok, app} -> Jason.encode!(%{"ok" => true, "application" => app})
            {:error, :not_found} -> Jason.encode!(%{"ok" => false, "error" => "not_found"})
          end
        _ ->
          Jason.encode!(%{"ok" => false, "error" => "missing application_id"})
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "job.listings.list", reply_to: reply_to} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return list of listings for LiveView (limited to avoid NATS payload limits)
    response =
      case listing_store().list([]) do
        {:ok, listings} ->
          # Limit to 100 listings per response and strip jd_text to avoid exceeding NATS max_payload (default 1MB)
          limited = Enum.take(listings, 100)
          # Remove jd_text from each listing to reduce payload size
          stripped = Enum.map(limited, fn listing -> Map.delete(listing, "jd_text") end)
          Jason.encode!(%{"ok" => true, "listings" => stripped, "total" => length(listings)})
        _ -> Jason.encode!(%{"ok" => false, "listings" => [], "total" => 0})
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "job.application.list", reply_to: reply_to} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return list of applications for LiveView
    response =
      case application_store().list() do
        {:ok, applications} -> Jason.encode!(%{"ok" => true, "applications" => applications})
        _ -> Jason.encode!(%{"ok" => false, "applications" => []})
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "requests.job_applications.snapshot", reply_to: reply_to} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: TUI snapshot format for job-applications-tui
    snapshot = BotArmyJobApplications.Handlers.TuiCommandHandler.get_snapshot()
    response = Jason.encode!(snapshot)

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "commands.job_applications.create", body: body} = _msg}, state) do
    case Jason.decode(body) do
      {:ok, payload} -> BotArmyJobApplications.Handlers.TuiCommandHandler.handle_create(payload)
      {:error, _} -> Logger.warning("TUI create: invalid JSON")
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "commands.job_applications.update", body: body} = _msg}, state) do
    case Jason.decode(body) do
      {:ok, payload} -> BotArmyJobApplications.Handlers.TuiCommandHandler.handle_update(payload)
      {:error, _} -> Logger.warning("TUI update: invalid JSON")
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "commands.job_applications.update_status", body: body} = _msg}, state) do
    case Jason.decode(body) do
      {:ok, payload} -> BotArmyJobApplications.Handlers.TuiCommandHandler.handle_update_status(payload)
      {:error, _} -> Logger.warning("TUI update_status: invalid JSON")
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "commands.job_applications.delete", body: body} = _msg}, state) do
    case Jason.decode(body) do
      {:ok, payload} -> BotArmyJobApplications.Handlers.TuiCommandHandler.handle_delete(payload)
      {:error, _} -> Logger.warning("TUI delete: invalid JSON")
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "commands.job_applications.add_note", body: body} = _msg}, state) do
    case Jason.decode(body) do
      {:ok, payload} -> BotArmyJobApplications.Handlers.TuiCommandHandler.handle_add_note(payload)
      {:error, _} -> Logger.warning("TUI add_note: invalid JSON")
    end
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "job.resume.list", reply_to: reply_to} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return list of resumes for surface
    response =
      case resume_store().list() do
        {:ok, resumes} -> Jason.encode!(%{"ok" => true, "resumes" => resumes})
        _ -> Jason.encode!(%{"ok" => false, "resumes" => []})
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "job.resume.get", reply_to: reply_to, body: body} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return resume by id for surface detail view
    response =
      case Jason.decode(body) do
        {:ok, %{"resume_id" => resume_id}} when is_binary(resume_id) ->
          case resume_store().get(resume_id) do
            {:ok, resume} -> Jason.encode!(%{"ok" => true, "resume" => resume})
            {:error, :not_found} -> Jason.encode!(%{"ok" => false, "error" => "not_found"})
          end
        _ ->
          Jason.encode!(%{"ok" => false, "error" => "missing resume_id"})
      end

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

  defp application_store do
    Application.get_env(:bot_army_job_applications, :application_store, BotArmyJobApplications.ApplicationStore)
  end

  defp listing_store do
    Application.get_env(:bot_army_job_applications, :listing_store, BotArmyJobApplications.ListingStore)
  end

  defp resume_store do
    Application.get_env(:bot_army_job_applications, :resume_store, BotArmyJobApplications.ResumeStore)
  end
end
