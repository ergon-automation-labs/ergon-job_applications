defmodule BotArmyJobApplications.ResumeStore do
  @moduledoc """
  Resume storage GenServer.

  Maintains an in-memory cache of resumes loaded from the database.
  Provides CRUD operations that update both cache and persistence layer.
  """

  use GenServer
  require Logger

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  def update(resume_id, payload) when is_binary(resume_id) and is_map(payload) do
    GenServer.call(@server, {:update, resume_id, payload})
  end

  def get(resume_id) when is_binary(resume_id) do
    GenServer.call(@server, {:get, resume_id})
  end

  def list do
    GenServer.call(@server, :list)
  end

  def clear do
    GenServer.call(@server, :clear)
  end

  @impl true
  def init(_opts) do
    Logger.info("ResumeStore started")

    state = try do
      resumes = BotArmyJobApplications.Repo.all(BotArmyJobApplications.Schemas.Resume)
      Enum.reduce(resumes, %{}, fn resume, acc ->
        Map.put(acc, resume.id |> to_string(), schema_to_map(resume))
      end)
    rescue
      _ ->
        Logger.warning("Could not load resumes from database. Starting with empty state.")
        %{}
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    resume_id = Ecto.UUID.generate()

    changeset = BotArmyJobApplications.Schemas.Resume.changeset(
      %BotArmyJobApplications.Schemas.Resume{id: resume_id},
      %{
        "identity" => payload["identity"],
        "metadata" => Map.get(payload, "metadata")
      }
    )

    case BotArmyJobApplications.Repo.insert(changeset) do
      {:ok, db_resume} ->
        resume = schema_to_map(db_resume)
        new_state = Map.put(state, resume_id, resume)
        Logger.info("Created resume in database: #{resume_id}")
        {:reply, {:ok, resume}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create resume: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:update, resume_id, payload}, _from, state) do
    case Map.get(state, resume_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _resume ->
        resume_uuid = Ecto.UUID.cast!(resume_id)
        db_resume = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Resume, resume_uuid)

        if db_resume do
          changeset = BotArmyJobApplications.Schemas.Resume.changeset(
            db_resume,
            %{
              "identity" => Map.get(payload, "identity", db_resume.identity),
              "metadata" => Map.get(payload, "metadata", db_resume.metadata)
            }
          )

          case BotArmyJobApplications.Repo.update(changeset) do
            {:ok, updated_db_resume} ->
              updated_resume = schema_to_map(updated_db_resume)
              new_state = Map.put(state, resume_id, updated_resume)
              Logger.info("Updated resume in database: #{resume_id}")
              {:reply, {:ok, updated_resume}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to update resume: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, resume_id}, _from, state) do
    case Map.get(state, resume_id) do
      nil -> {:reply, {:error, :not_found}, state}
      resume -> {:reply, {:ok, resume}, state}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    resumes = state |> Map.values()
    {:reply, {:ok, resumes}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all resumes from database and state")
    BotArmyJobApplications.Repo.delete_all(BotArmyJobApplications.Schemas.Resume)
    {:reply, :ok, %{}}
  end

  defp schema_to_map(%BotArmyJobApplications.Schemas.Resume{} = resume) do
    %{
      "id" => resume.id |> to_string(),
      "identity" => resume.identity,
      "metadata" => resume.metadata,
      "created_at" => resume.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => resume.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end
