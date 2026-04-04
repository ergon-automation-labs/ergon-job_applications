defmodule BotArmyJobApplications.DigestScheduler do
  @moduledoc """
  GenServer that drives the 24-hour digest generation loop.

  Reads configuration, schedules a daily digest via send_after, and publishes
  digest events when the timer fires.

  Configuration keys (via Application env):
  - digest_interval_ms: interval between digest generations in milliseconds
                        (default: 86_400_000 = 24 hours)
  - application_store: module providing application_store interface
                       (default: BotArmyJobApplications.ApplicationStore)
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if digest_enabled?() do
      # Schedule first digest immediately
      ref = schedule_digest()
      {:ok, %{timer_ref: ref}}
    else
      Logger.info("Digest scheduler disabled")
      {:ok, %{timer_ref: nil}}
    end
  end

  @impl true
  def handle_info(:run_digest, state) do
    # Cancel existing timer if any
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)

    # Run the digest generation
    run_digest()

    # Schedule next digest
    ref = schedule_digest()
    {:noreply, %{state | timer_ref: ref}}
  end

  # Private functions

  defp run_digest do
    default_tenant_id = BotArmyCore.Tenant.default_tenant_id()
    case application_store().list(default_tenant_id) do
      {:ok, apps} ->
        digest = BotArmyJobApplications.Handlers.DigestHandler.build_digest(apps)
        BotArmyJobApplications.Handlers.DigestHandler.publish_digest(digest, nil, default_tenant_id, nil)
        Logger.info("Scheduled digest generated and published")

      {:error, reason} ->
        Logger.error("Scheduled digest failed: #{inspect(reason)}")
    end
  rescue
    e ->
      Logger.error("Exception during scheduled digest: #{inspect(e)}")
  end

  defp schedule_digest do
    Process.send_after(self(), :run_digest, digest_interval_ms())
  end

  defp digest_enabled? do
    digest_interval_ms() != :disabled
  end

  defp digest_interval_ms do
    Application.get_env(:bot_army_job_applications, :digest_interval_ms, 86_400_000)
  end

  defp application_store do
    Application.get_env(:bot_army_job_applications, :application_store,
      BotArmyJobApplications.ApplicationStore)
  end
end
