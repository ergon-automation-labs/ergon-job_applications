defmodule BotArmyJobApplications.ApplicationServer do
  @moduledoc """
  GenServer for managing a single job application.

  Each non-terminal application gets one ApplicationServer process.
  Registered in ApplicationRegistry via {via, Registry, ...}.

  Handles:
  - :transition - State transitions
  - :get - Get current application state
  - :set_pending_signal - Set a pending signal
  - :clear_pending_signal - Clear the pending signal
  - :set_artifacts - Set artifacts (cover letter, resume)
  """

  use GenServer
  require Logger

  def start_link(application_id) do
    GenServer.start_link(
      __MODULE__,
      application_id,
      name: via_tuple(application_id)
    )
  end

  @doc """
  Get the via tuple for registering in ApplicationRegistry.
  """
  def via_tuple(application_id) do
    {:via, Registry, {BotArmyJobApplications.ApplicationRegistry, application_id}}
  end

  @doc """
  Transition the application to a new state.
  """
  def transition(application_id, to_state, metadata \\ %{}) do
    case Registry.lookup(BotArmyJobApplications.ApplicationRegistry, application_id) do
      [] -> {:error, :not_found}
      [{pid, _}] -> GenServer.call(pid, {:transition, to_state, metadata})
    end
  end

  @doc """
  Get the current application state.
  """
  def get(application_id) do
    case Registry.lookup(BotArmyJobApplications.ApplicationRegistry, application_id) do
      [] -> {:error, :not_found}
      [{pid, _}] -> GenServer.call(pid, :get)
    end
  end

  @doc """
  Set a pending signal (e.g., waiting for LLM response).
  """
  def set_pending_signal(application_id, signal) do
    case Registry.lookup(BotArmyJobApplications.ApplicationRegistry, application_id) do
      [] -> {:error, :not_found}
      [{pid, _}] -> GenServer.call(pid, {:set_pending_signal, signal})
    end
  end

  @doc """
  Clear the pending signal.
  """
  def clear_pending_signal(application_id) do
    case Registry.lookup(BotArmyJobApplications.ApplicationRegistry, application_id) do
      [] -> {:error, :not_found}
      [{pid, _}] -> GenServer.call(pid, :clear_pending_signal)
    end
  end

  @doc """
  Set artifacts (cover letter, resume).
  """
  def set_artifacts(application_id, artifacts) do
    case Registry.lookup(BotArmyJobApplications.ApplicationRegistry, application_id) do
      [] -> {:error, :not_found}
      [{pid, _}] -> GenServer.call(pid, {:set_artifacts, artifacts})
    end
  end

  @impl true
  def init(application_id) do
    Logger.info("ApplicationServer starting for application: #{application_id}")

    # Load application from database
    case BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Application, application_id) do
      nil ->
        Logger.error("Application not found: #{application_id}")
        {:stop, :not_found}

      db_app ->
        application = schema_to_map(db_app)
        {:ok, application}
    end
  end

  @impl true
  def handle_call({:transition, to_state, metadata}, _from, state) do
    from_state = state["state"]

    case BotArmyJobApplications.Commands.valid_transition?(from_state, to_state) do
      false ->
        Logger.error("Invalid transition from #{from_state} to #{to_state}")
        {:reply, {:error, :invalid_transition}, state}

      true ->
        # Create state event
        {:ok, event} = BotArmyJobApplications.Commands.create_state_event(from_state, to_state, metadata)

        # Update history
        new_history = (state["history"] || []) ++ [event]

        # Update database
        app_uuid = Ecto.UUID.cast!(state["id"])
        db_app = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Application, app_uuid)

        changeset = BotArmyJobApplications.Schemas.Application.changeset(
          db_app,
          %{
            "state" => to_state,
            "history" => new_history
          }
        )

        case BotArmyJobApplications.Repo.update(changeset) do
          {:ok, updated_db_app} ->
            updated_app = schema_to_map(updated_db_app)
            Logger.info("Transitioned application #{state["id"]} from #{from_state} to #{to_state}")

            # If terminal state, stop self
            if BotArmyJobApplications.Commands.terminal?(to_state) do
              Logger.info("Application #{state["id"]} reached terminal state: #{to_state}")
              {:reply, {:ok, updated_app}, updated_app, {:continue, :terminate_self}}
            else
              {:reply, {:ok, updated_app}, updated_app}
            end

          {:error, changeset} ->
            Logger.error("Failed to update application: #{inspect(changeset.errors)}")
            {:reply, {:error, :database_error}, state}
        end
    end
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call({:set_pending_signal, signal}, _from, state) do
    app_uuid = Ecto.UUID.cast!(state["id"])
    db_app = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Application, app_uuid)

    changeset = BotArmyJobApplications.Schemas.Application.changeset(
      db_app,
      %{"pending_signal" => signal}
    )

    case BotArmyJobApplications.Repo.update(changeset) do
      {:ok, updated_db_app} ->
        updated_app = schema_to_map(updated_db_app)
        Logger.debug("Set pending signal for application #{state["id"]}")
        {:reply, {:ok, updated_app}, updated_app}

      {:error, changeset} ->
        Logger.error("Failed to set pending signal: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call(:clear_pending_signal, _from, state) do
    app_uuid = Ecto.UUID.cast!(state["id"])
    db_app = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Application, app_uuid)

    changeset = BotArmyJobApplications.Schemas.Application.changeset(
      db_app,
      %{"pending_signal" => nil}
    )

    case BotArmyJobApplications.Repo.update(changeset) do
      {:ok, updated_db_app} ->
        updated_app = schema_to_map(updated_db_app)
        Logger.debug("Cleared pending signal for application #{state["id"]}")
        {:reply, {:ok, updated_app}, updated_app}

      {:error, changeset} ->
        Logger.error("Failed to clear pending signal: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:set_artifacts, artifacts}, _from, state) do
    app_uuid = Ecto.UUID.cast!(state["id"])
    db_app = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Application, app_uuid)

    changeset = BotArmyJobApplications.Schemas.Application.changeset(
      db_app,
      %{"artifacts" => artifacts}
    )

    case BotArmyJobApplications.Repo.update(changeset) do
      {:ok, updated_db_app} ->
        updated_app = schema_to_map(updated_db_app)
        Logger.info("Set artifacts for application #{state["id"]}")
        {:reply, {:ok, updated_app}, updated_app}

      {:error, changeset} ->
        Logger.error("Failed to set artifacts: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_continue(:terminate_self, state) do
    {:stop, :normal, state}
  end

  defp schema_to_map(%BotArmyJobApplications.Schemas.Application{} = app) do
    %{
      "id" => app.id |> to_string(),
      "listing_id" => app.listing_id,
      "company" => app.company,
      "role_title" => app.role_title,
      "jd_url" => app.jd_url,
      "jd_text" => app.jd_text,
      "jd_tags" => app.jd_tags,
      "coverage_score" => app.coverage_score,
      "salary_range" => app.salary_range,
      "strategy" => app.strategy,
      "state" => app.state,
      "history" => app.history || [],
      "pending_signal" => app.pending_signal,
      "next_action" => app.next_action,
      "artifacts" => app.artifacts,
      "created_at" => app.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => app.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end
