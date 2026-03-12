defmodule BotArmyJobApplications.ApplicationSupervisor do
  @moduledoc """
  DynamicSupervisor for ApplicationServer processes.

  On initialization, queries the database for all non-terminal applications
  and starts one ApplicationServer per result.
  """

  use DynamicSupervisor
  import Ecto.Query
  require Logger

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    Logger.info("ApplicationSupervisor starting")

    # Load all non-terminal applications from database
    try do
      terminal_states = BotArmyJobApplications.Commands.all_states()
      |> Enum.filter(&BotArmyJobApplications.Commands.terminal?/1)

      applications = BotArmyJobApplications.Repo.all(
        from app in BotArmyJobApplications.Schemas.Application,
        where: app.state not in ^terminal_states
      )

      # Start one ApplicationServer per non-terminal application
      Enum.each(applications, fn app ->
        start_child(app.id)
      end)

      Logger.info("Started #{length(applications)} ApplicationServers from database")
    rescue
      e ->
        Logger.warning("Error loading applications from database on supervisor init: #{inspect(e)}")
    end

    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Start a new ApplicationServer for the given application ID.
  """
  def start_child(application_id) do
    DynamicSupervisor.start_child(
      __MODULE__,
      {BotArmyJobApplications.ApplicationServer, application_id}
    )
  end

  @doc """
  Stop an ApplicationServer by application ID.
  """
  def stop_child(application_id) do
    case Registry.lookup(BotArmyJobApplications.ApplicationRegistry, application_id) do
      [] ->
        {:error, :not_found}

      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
    end
  end
end
