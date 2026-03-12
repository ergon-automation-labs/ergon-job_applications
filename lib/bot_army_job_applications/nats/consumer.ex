defmodule BotArmyJobApplications.NATS.Consumer do
  @moduledoc """
  NATS consumer for Job Applications bot.

  Subscribes to:
  - job.listings.ingest — raw listings from scrapers
  - job.listing.score.request — trigger scoring
  - job.application.create — new application
  - job.application.command.transition — state transitions
  - job.application.artifact.request — artifact generation
  - job.digest.request — trigger daily digest

  Phase 1 (manual pipeline): Minimal subscriptions for artifact generation.
  Phase 2 (email + discovery): Full email watcher and scraper integration.
  """

  use GenServer
  require Logger

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @impl true
  def init(_opts) do
    Logger.info("BotArmyJobApplications.NATS.Consumer started")
    {:ok, %{}}
  end
end
