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
  - job.resume.create — create resume from TUI (request/reply)
  - job.resume.update — update resume from TUI (request/reply)
  - job.resume.delete — delete resume (request/reply)
  - events.llm.completion.job_applications.* — typed LLM responses:
      - cover_letter — artifact cover letter generation
      - jd_analysis — artifact JD tag extraction
      - scoring — job recommendation scoring
      - resume_parse — resume file parsing
      - interview_prep — interview prep generation
  - job.pipeline.query — request/reply queries

  Phase 1 (manual pipeline): Minimal subscriptions for artifact generation.
  Phase 2 (email + discovery): Full email watcher and scraper integration.
  TUI Management: Resume CRUD via request/reply for surface.
  """

  use GenServer
  require Logger

  @reconnect_delay_ms 5000
  @version Mix.Project.config()[:version]
  @registry_heartbeat_ms 20_000

  @subjects [
    %{subject: "job.application.create", type: :subscribe, description: "Create application"},
    %{
      subject: "job.application.command.transition",
      type: :subscribe,
      description: "Transition application"
    },
    %{
      subject: "job.application.command.rank",
      type: :subscribe,
      description: "Rank applications"
    },
    %{subject: "job.application.get", type: :request_reply, description: "Get application"},
    %{subject: "job.application.list", type: :request_reply, description: "List applications"},
    %{subject: "job.listings.list", type: :request_reply, description: "List listings"},
    %{subject: "job.listing.get", type: :request_reply, description: "Get listing"},
    %{
      subject: "job.listings.recommend",
      type: :request_reply,
      description: "Get recommendations"
    },
    %{subject: "job.resume.list", type: :request_reply, description: "List resumes"},
    %{subject: "job.resume.get", type: :request_reply, description: "Get resume"},
    %{subject: "job.resume.create", type: :request_reply, description: "Create resume"},
    %{subject: "job.resume.update", type: :request_reply, description: "Update resume"},
    %{subject: "job.resume.delete", type: :request_reply, description: "Delete resume"},
    %{subject: "job.pipeline.query", type: :request_reply, description: "Query pipeline"},
    %{
      subject: "requests.job_applications.snapshot",
      type: :request_reply,
      description: "Get TUI snapshot"
    }
  ]

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Route decoded message to appropriate handler based on event type.
  """
  def route_message(message) do
    event = message["event"]

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

      "job.application.artifact.update" ->
        BotArmyJobApplications.Handlers.ArtifactHandler.handle_update(message)

      "job.application.interview_prep.request" ->
        BotArmyJobApplications.Handlers.InterviewPrepHandler.handle_request(message)

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

      "llm.completion.job_applications.cover_letter" ->
        BotArmyJobApplications.Handlers.ArtifactHandler.handle_cover_letter_response(message)

      "llm.completion.job_applications.jd_analysis" ->
        BotArmyJobApplications.Handlers.ArtifactHandler.handle_jd_analysis_response(message)

      "llm.completion.job_applications.scoring" ->
        BotArmyJobApplications.Handlers.RecommendationHandler.handle_llm_score_response(message)

      "llm.completion.job_applications.resume_parse" ->
        BotArmyJobApplications.Handlers.ResumeParseHandler.handle_parse_response(message)

      "llm.completion.job_applications.interview_prep" ->
        BotArmyJobApplications.Handlers.InterviewPrepHandler.handle_llm_response(message)

      _ ->
        Logger.debug("Unknown event type: #{event}")
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
        BotArmyRuntime.NATS.Connection.subscribe_to_status()
        Logger.info("Connected to NATS, subscribing to job applications topics")

        subscriptions =
          [
            "job.application.create",
            "job.application.command.transition",
            "job.application.command.rank",
            "job.application.command.confirm_signal",
            "job.application.command.dismiss_signal",
            "job.application.artifact.request",
            "job.application.artifact.update",
            "job.application.interview_prep.request",
            "job.digest.request",
            "job.email.interview_request",
            "job.email.phone_screen",
            "job.email.offer",
            "job.email.rejection",
            "job.listings.ingest",
            "job.listings.fetch.request",
            "job.listings.recommend",
            "job.resume.upload",
            "job.resume.list",
            "job.resume.get",
            "job.resume.create",
            "job.resume.update",
            "job.resume.delete",
            "events.llm.completion.job_applications.cover_letter",
            "events.llm.completion.job_applications.jd_analysis",
            "events.llm.completion.job_applications.scoring",
            "events.llm.completion.job_applications.resume_parse",
            "events.llm.completion.job_applications.interview_prep",
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

        BotArmyRuntime.Registry.register("job_applications", @subjects, @version)
        Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
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
      BotArmyRuntime.NATS.Reply.ok(%{
        status: "ok",
        applications_count: get_applications_count()
      })

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.application.get", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return application by id for LiveView detail page
    response =
      case Jason.decode(body) do
        {:ok, %{"application_id" => app_id}} when is_binary(app_id) ->
          case application_store().get(tenant_id(), app_id) do
            {:ok, app} -> BotArmyRuntime.NATS.Reply.ok(%{"application" => app})
            {:error, :not_found} -> BotArmyRuntime.NATS.Reply.error("not_found", :not_found)
          end

        _ ->
          BotArmyRuntime.NATS.Reply.error("missing application_id", :missing_application_id)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.listings.list", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return paginated list of listings (offset/limit support)
    # Supports sort_by parameter: "date" (newest first), "company" (alphabetical), "score" (recommendation)
    {offset, sort_by} =
      case Jason.decode(body) do
        {:ok, payload} when is_map(payload) ->
          off =
            case payload["offset"] do
              o when is_integer(o) -> max(0, o)
              _ -> 0
            end

          sort =
            case payload["sort_by"] do
              s when is_binary(s) -> s
              _ -> "date"
            end

          {off, sort}

        _ ->
          {0, "date"}
      end

    response =
      case listing_store().list(tenant_id()) do
        {:ok, listings} ->
          # Sort listings based on requested sort_by parameter
          sorted =
            case sort_by do
              "date" ->
                # Newest first (inserted_at descending)
                Enum.sort_by(listings, &(&1["inserted_at"] || ""), :desc)

              "company" ->
                # Alphabetical by company name
                Enum.sort_by(listings, &(&1["company"] || ""))

              "score" ->
                # Recommendation score descending (highest first)
                Enum.sort_by(listings, &(-(&1["recommendation_score"] || 0)), :asc)

              _ ->
                # Default to date (newest first)
                Enum.sort_by(listings, &(&1["inserted_at"] || ""), :desc)
            end

          total = length(sorted)
          limit = 100
          # Apply offset and limit
          paginated = sorted |> Enum.drop(offset) |> Enum.take(limit)
          # Remove jd_text from each listing to reduce payload size
          stripped = Enum.map(paginated, fn listing -> Map.delete(listing, "jd_text") end)

          BotArmyRuntime.NATS.Reply.ok(%{
            "listings" => stripped,
            "total" => total,
            "offset" => offset,
            "limit" => limit,
            "returned" => length(stripped)
          })

        _ ->
          BotArmyRuntime.NATS.Reply.error("failed to list listings", :list_failed)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.listing.get", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return full listing details (including jd_text) by ID
    response =
      case Jason.decode(body) do
        {:ok, %{"listing_id" => listing_id}} when is_binary(listing_id) ->
          case listing_store().get(tenant_id(), listing_id) do
            {:ok, listing} ->
              BotArmyRuntime.NATS.Reply.ok(%{"listing" => listing})

            {:error, :not_found} ->
              BotArmyRuntime.NATS.Reply.error("listing_not_found", :not_found)
          end

        _ ->
          BotArmyRuntime.NATS.Reply.error("missing_listing_id", :missing_listing_id)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.listings.recommend", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: recommendations request (tag-scored immediately, LLM enrichment async)
    # TUI sends empty payload, so just call the handler directly
    case Jason.decode(body) do
      {:ok, _payload} ->
        # Call handler with empty payload - no decoding needed
        BotArmyJobApplications.Handlers.RecommendationHandler.handle_recommend(
          %{},
          reply_to,
          state.conn
        )

      {:error, _} ->
        response = BotArmyRuntime.NATS.Reply.error("invalid_json", :decode_error)
        if state.conn, do: Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: "job.application.list", reply_to: reply_to} = _msg}, state)
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return list of applications for LiveView
    response =
      case application_store().list(tenant_id()) do
        {:ok, applications} -> BotArmyRuntime.NATS.Reply.ok(%{"applications" => applications})
        _ -> BotArmyRuntime.NATS.Reply.error("failed to list applications", :list_failed)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg,
         %{topic: "requests.job_applications.snapshot", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: TUI snapshot format for job-applications-tui
    message = if is_binary(body), do: Jason.decode!(body), else: %{}
    %{tenant_id: tenant_id} = BotArmyCore.Tenant.extract_context(message)
    snapshot = BotArmyJobApplications.Handlers.TuiCommandHandler.get_snapshot(tenant_id)
    response = BotArmyRuntime.NATS.Reply.ok(snapshot)

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
  def handle_info(
        {:msg, %{topic: "commands.job_applications.update_status", body: body} = _msg},
        state
      ) do
    case Jason.decode(body) do
      {:ok, payload} ->
        BotArmyJobApplications.Handlers.TuiCommandHandler.handle_update_status(payload)

      {:error, _} ->
        Logger.warning("TUI update_status: invalid JSON")
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
  def handle_info(
        {:msg, %{topic: "commands.job_applications.add_note", body: body} = _msg},
        state
      ) do
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
      case resume_store().list(tenant_id()) do
        {:ok, resumes} -> BotArmyRuntime.NATS.Reply.ok(%{"resumes" => resumes})
        _ -> BotArmyRuntime.NATS.Reply.error("failed to list resumes", :list_failed)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.resume.get", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: return resume by id for surface detail view
    response =
      case Jason.decode(body) do
        {:ok, %{"resume_id" => resume_id}} when is_binary(resume_id) ->
          case resume_store().get(tenant_id(), resume_id) do
            {:ok, resume} -> BotArmyRuntime.NATS.Reply.ok(%{"resume" => resume})
            {:error, :not_found} -> BotArmyRuntime.NATS.Reply.error("not_found", :not_found)
          end

        _ ->
          BotArmyRuntime.NATS.Reply.error("missing resume_id", :missing_resume_id)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.resume.create", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: create resume from TUI structured payload
    response =
      case Jason.decode(body) do
        {:ok, payload} when is_map(payload) ->
          result = BotArmyJobApplications.Handlers.ResumeTuiHandler.handle_create(payload)

          if result["ok"] == true do
            BotArmyRuntime.NATS.Reply.ok(Map.delete(result, "ok"))
          else
            BotArmyRuntime.NATS.Reply.error(result["error"] || "create failed", :create_failed)
          end

        _ ->
          BotArmyRuntime.NATS.Reply.error("invalid_json", :decode_error)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.resume.update", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: update resume from TUI structured payload
    response =
      case Jason.decode(body) do
        {:ok, payload} when is_map(payload) ->
          result = BotArmyJobApplications.Handlers.ResumeTuiHandler.handle_update(payload)

          # If update succeeded, re-score all listings with new preferences
          if result["ok"] == true do
            BotArmyJobApplications.Handlers.RecommendationHandler.rescore_all()
            BotArmyRuntime.NATS.Reply.ok(Map.delete(result, "ok"))
          else
            BotArmyRuntime.NATS.Reply.error(result["error"] || "update failed", :update_failed)
          end

        _ ->
          BotArmyRuntime.NATS.Reply.error("invalid_json", :decode_error)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:msg, %{topic: "job.resume.delete", reply_to: reply_to, body: body} = _msg},
        state
      )
      when is_binary(reply_to) and reply_to != "" do
    # Request/reply: delete resume
    response =
      case Jason.decode(body) do
        {:ok, payload} when is_map(payload) ->
          result = BotArmyJobApplications.Handlers.ResumeTuiHandler.handle_delete(payload)

          if result["ok"] == true do
            BotArmyRuntime.NATS.Reply.ok(Map.delete(result, "ok"))
          else
            BotArmyRuntime.NATS.Reply.error(result["error"] || "delete failed", :delete_failed)
          end

        _ ->
          BotArmyRuntime.NATS.Reply.error("invalid_json", :decode_error)
      end

    if state.conn do
      Gnat.pub(state.conn, reply_to, response)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, msg}, state) do
    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers, []), fn ->
      Logger.debug("Received NATS message on subject: #{msg.topic}")

      case BotArmyCore.NATS.Decoder.decode(msg.body) do
        {:ok, decoded_message} ->
          route_message(decoded_message)

        {:error, reason} ->
          Logger.warning("Failed to decode message from #{msg.topic}: #{inspect(reason)}")
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("Disconnected from NATS, will attempt to reconnect")
    Process.send_after(self(), :reconnect, @reconnect_delay_ms)
    {:noreply, %{state | subscriptions: [], conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("Connected to NATS, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("Attempting to reconnect to NATS")
    {:noreply, state, {:continue, :connect}}
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
    Application.get_env(
      :bot_army_job_applications,
      :application_store,
      BotArmyJobApplications.ApplicationStore
    )
  end

  defp listing_store do
    Application.get_env(
      :bot_army_job_applications,
      :listing_store,
      BotArmyJobApplications.ListingStore
    )
  end

  defp resume_store do
    Application.get_env(
      :bot_army_job_applications,
      :resume_store,
      BotArmyJobApplications.ResumeStore
    )
  end

  defp tenant_id,
    do: System.get_env("BOT_ARMY_TENANT_ID", "00000000-0000-0000-0000-000000000001")
  @impl true
  def handle_info(:registry_heartbeat, state) do
    if length(state.subscriptions) > 0 do
      BotArmyRuntime.Registry.register("job_applications", @subjects, @version)
      Process.send_after(self(), :registry_heartbeat, @registry_heartbeat_ms)
    end

    {:noreply, state}
  end

end
