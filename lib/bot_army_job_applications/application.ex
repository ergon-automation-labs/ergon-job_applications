defmodule BotArmyJobApplications.Application do
  @moduledoc """
  Application supervision tree for the job applications bot.

  Follows the GTD Bot pattern with environment-aware startup:
  - Repo (Ecto) not started in :test (mocked by tests)
  - Stores (ResumeStore, ListingStore) not started in :test (mocked via config)
  - ApplicationRegistry for process lookup
  - ApplicationSupervisor for per-application GenServers
  - Consumer for NATS subscriptions
  """

  @env Mix.env()

  use Application

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_repo()
      |> maybe_add_registry()
      |> maybe_add_stores()
      |> maybe_add_supervisor()
      |> maybe_add_ingestion_worker()
      |> maybe_add_digest_scheduler()
      |> maybe_add_pulse_publisher()
      |> maybe_add_consumer()
      |> maybe_add_health_responder()

    opts = [strategy: :one_for_one, name: BotArmyJobApplications.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_repo(children) do
    if @env == :test do
      children
    else
      [BotArmyJobApplications.Repo | children]
    end
  end

  defp maybe_add_registry(children) do
    if @env == :test do
      children
    else
      [{Registry, keys: :unique, name: BotArmyJobApplications.ApplicationRegistry} | children]
    end
  end

  defp maybe_add_stores(children) do
    if @env == :test do
      children
    else
      children ++
        [
          {BotArmyJobApplications.ResumeStore, []},
          {BotArmyJobApplications.ListingStore, []},
          {BotArmyJobApplications.ApplicationStore, []}
        ]
    end
  end

  defp maybe_add_supervisor(children) do
    if @env == :test do
      children
    else
      [{BotArmyJobApplications.ApplicationSupervisor, []} | children]
    end
  end

  defp maybe_add_consumer(children) do
    if @env == :test do
      children
    else
      [{BotArmyJobApplications.NATS.Consumer, []} | children]
    end
  end

  defp maybe_add_ingestion_worker(children) do
    if @env == :test do
      children
    else
      [{BotArmyJobApplications.Ingestion.Worker, []} | children]
    end
  end

  defp maybe_add_digest_scheduler(children) do
    if @env == :test do
      children
    else
      [{BotArmyJobApplications.DigestScheduler, []} | children]
    end
  end

  defp maybe_add_pulse_publisher(children) do
    if @env == :test do
      children
    else
      [{BotArmyJobApplications.PulsePublisher, []} | children]
    end
  end

  defp maybe_add_health_responder(children) do
    if @env == :test,
      do: children,
      else: [
        {BotArmyRuntime.Health.Responder,
         [bot_name: :job_applications, repo: BotArmyJobApplications.Repo, version: "0.2.31"]}
        | children
      ]
  end
end
