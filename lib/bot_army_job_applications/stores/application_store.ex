defmodule BotArmyJobApplications.ApplicationStore do
  @moduledoc """
  Application storage GenServer.

  Maintains an in-memory cache of applications loaded from the database.
  Provides CRUD operations that update both cache and persistence layer.
  """

  use GenServer
  require Logger

  @behaviour BotArmyJobApplications.ApplicationStoreBehaviour

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  @impl BotArmyJobApplications.ApplicationStoreBehaviour
  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  @impl BotArmyJobApplications.ApplicationStoreBehaviour
  def update(application_id, payload) when is_binary(application_id) and is_map(payload) do
    GenServer.call(@server, {:update, application_id, payload})
  end

  @impl BotArmyJobApplications.ApplicationStoreBehaviour
  def get(application_id) when is_binary(application_id) do
    GenServer.call(@server, {:get, application_id})
  end

  @impl BotArmyJobApplications.ApplicationStoreBehaviour
  def delete(application_id) when is_binary(application_id) do
    GenServer.call(@server, {:delete, application_id})
  end

  @impl BotArmyJobApplications.ApplicationStoreBehaviour
  def list do
    GenServer.call(@server, :list)
  end

  @impl BotArmyJobApplications.ApplicationStoreBehaviour
  def clear do
    GenServer.call(@server, :clear)
  end

  @impl true
  def init(_opts) do
    Logger.info("ApplicationStore started")

    state = try do
      applications = BotArmyJobApplications.Repo.all(BotArmyJobApplications.Schemas.Application)
      Enum.reduce(applications, %{}, fn app, acc ->
        Map.put(acc, app.id |> to_string(), schema_to_map(app))
      end)
    rescue
      _ ->
        Logger.warning("Could not load applications from database. Starting with empty state.")
        %{}
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    application_id = Ecto.UUID.generate()

    changeset = BotArmyJobApplications.Schemas.Application.changeset(
      %BotArmyJobApplications.Schemas.Application{id: application_id},
      %{
        "listing_id" => payload["listing_id"],
        "company" => payload["company"],
        "role_title" => payload["role_title"],
        "jd_url" => Map.get(payload, "jd_url"),
        "jd_text" => Map.get(payload, "jd_text"),
        "jd_tags" => Map.get(payload, "jd_tags"),
        "coverage_score" => Map.get(payload, "coverage_score"),
        "salary_range" => Map.get(payload, "salary_range"),
        "strategy" => Map.get(payload, "strategy"),
        "state" => Map.get(payload, "state", "identified"),
        "history" => Map.get(payload, "history", []),
        "pending_signal" => Map.get(payload, "pending_signal"),
        "next_action" => Map.get(payload, "next_action"),
        "artifacts" => Map.get(payload, "artifacts", %{})
      }
    )

    case BotArmyJobApplications.Repo.insert(changeset) do
      {:ok, db_application} ->
        application = schema_to_map(db_application)
        new_state = Map.put(state, application_id, application)
        Logger.info("Created application in database: #{application_id}")
        {:reply, {:ok, application}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create application: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:update, application_id, payload}, _from, state) do
    case Map.get(state, application_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _application ->
        application_uuid = Ecto.UUID.cast!(application_id)
        db_application = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Application, application_uuid)

        if db_application do
          changeset = BotArmyJobApplications.Schemas.Application.changeset(
            db_application,
            %{
              "listing_id" => Map.get(payload, "listing_id", db_application.listing_id),
              "company" => Map.get(payload, "company", db_application.company),
              "role_title" => Map.get(payload, "role_title", db_application.role_title),
              "jd_url" => Map.get(payload, "jd_url", db_application.jd_url),
              "jd_text" => Map.get(payload, "jd_text", db_application.jd_text),
              "jd_tags" => Map.get(payload, "jd_tags", db_application.jd_tags),
              "coverage_score" => Map.get(payload, "coverage_score", db_application.coverage_score),
              "salary_range" => Map.get(payload, "salary_range", db_application.salary_range),
              "strategy" => Map.get(payload, "strategy", db_application.strategy),
              "state" => Map.get(payload, "state", db_application.state),
              "history" => Map.get(payload, "history", db_application.history),
              "pending_signal" => Map.get(payload, "pending_signal", db_application.pending_signal),
              "next_action" => Map.get(payload, "next_action", db_application.next_action),
              "artifacts" => Map.get(payload, "artifacts", db_application.artifacts)
            }
          )

          case BotArmyJobApplications.Repo.update(changeset) do
            {:ok, updated_db_application} ->
              updated_application = schema_to_map(updated_db_application)
              new_state = Map.put(state, application_id, updated_application)
              Logger.info("Updated application in database: #{application_id}")
              {:reply, {:ok, updated_application}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to update application: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, application_id}, _from, state) do
    case Map.get(state, application_id) do
      nil -> {:reply, {:error, :not_found}, state}
      application -> {:reply, {:ok, application}, state}
    end
  end

  @impl true
  def handle_call({:delete, application_id}, _from, state) do
    case Map.get(state, application_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _ ->
        application_uuid = Ecto.UUID.cast!(application_id)
        db_application = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Application, application_uuid)

        if db_application do
          case BotArmyJobApplications.Repo.delete(db_application) do
            {:ok, _} ->
              new_state = Map.delete(state, application_id)
              Logger.info("Deleted application from database: #{application_id}")
              {:reply, :ok, new_state}

            {:error, changeset} ->
              Logger.error("Failed to delete application: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    applications = state |> Map.values()
    {:reply, {:ok, applications}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all applications from database and state")
    BotArmyJobApplications.Repo.delete_all(BotArmyJobApplications.Schemas.Application)
    {:reply, :ok, %{}}
  end

  defp schema_to_map(%BotArmyJobApplications.Schemas.Application{} = application) do
    %{
      "id" => application.id |> to_string(),
      "listing_id" => application.listing_id,
      "company" => application.company,
      "role_title" => application.role_title,
      "jd_url" => application.jd_url,
      "jd_text" => application.jd_text,
      "jd_tags" => application.jd_tags,
      "coverage_score" => application.coverage_score,
      "salary_range" => application.salary_range,
      "strategy" => application.strategy,
      "state" => application.state,
      "history" => application.history,
      "pending_signal" => application.pending_signal,
      "next_action" => application.next_action,
      "artifacts" => application.artifacts,
      "created_at" => application.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => application.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end
