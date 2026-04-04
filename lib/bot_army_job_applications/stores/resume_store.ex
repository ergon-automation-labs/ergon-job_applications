defmodule BotArmyJobApplications.ResumeStore do
  @moduledoc """
  Resume storage GenServer.

  Maintains an in-memory cache of resumes loaded from the database.
  Provides CRUD operations that update both cache and persistence layer.
  get/1 returns a hydrated resume (roles with bullets, skills) for artifact generation.
  """

  use GenServer
  require Logger
  import Ecto.Query

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  def create_from_parsed(parsed_data, file_metadata) when is_map(parsed_data) and is_map(file_metadata) do
    GenServer.call(@server, {:create_from_parsed, parsed_data, file_metadata})
  end

  def update(tenant_id, resume_id, payload) when is_binary(tenant_id) and is_binary(resume_id) and is_map(payload) do
    GenServer.call(@server, {:update, tenant_id, resume_id, payload})
  end

  def replace_full(tenant_id, resume_id, parsed_data) when is_binary(tenant_id) and is_binary(resume_id) and is_map(parsed_data) do
    GenServer.call(@server, {:replace_full, tenant_id, resume_id, parsed_data})
  end

  def delete(tenant_id, resume_id) when is_binary(tenant_id) and is_binary(resume_id) do
    GenServer.call(@server, {:delete, tenant_id, resume_id})
  end

  def get(tenant_id, resume_id) when is_binary(tenant_id) and is_binary(resume_id) do
    GenServer.call(@server, {:get, tenant_id, resume_id})
  end

  def list(tenant_id) when is_binary(tenant_id) do
    GenServer.call(@server, {:list, tenant_id})
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
        "tenant_id" => payload["tenant_id"],
        "user_id" => Map.get(payload, "user_id"),
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
  def handle_call({:create_from_parsed, parsed_data, file_metadata}, _from, state) do
    resume_id = Ecto.UUID.generate()

    # Extract identity (name, summary, summary_variants)
    identity = Map.get(parsed_data, "identity", %{})

    changeset = BotArmyJobApplications.Schemas.Resume.changeset(
      %BotArmyJobApplications.Schemas.Resume{id: resume_id},
      %{
        "tenant_id" => file_metadata["tenant_id"],
        "user_id" => Map.get(file_metadata, "user_id"),
        "identity" => identity,
        "metadata" => %{},
        "source_file_path" => Map.get(file_metadata, "file_path"),
        "original_filename" => Map.get(file_metadata, "original_filename")
      }
    )

    case BotArmyJobApplications.Repo.insert(changeset) do
      {:ok, db_resume} ->
        resume = schema_to_map(db_resume)

        # Create roles and bullets from parsed data
        :ok = create_roles_and_bullets(resume_id, parsed_data)

        # Create skills from parsed data
        :ok = create_skills(resume_id, parsed_data)

        new_state = Map.put(state, resume_id, resume)
        Logger.info("Created resume from parsed data: #{resume_id}")
        {:reply, {:ok, resume}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create resume from parsed data: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:update, tenant_id, resume_id, payload}, _from, state) do
    case Map.get(state, resume_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      resume ->
        if resume["tenant_id"] != tenant_id do
          {:reply, {:error, :not_found}, state}
        else
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
  end

  @impl true
  def handle_call({:replace_full, tenant_id, resume_id, parsed_data}, _from, state) do
    case Map.get(state, resume_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      resume ->
        if resume["tenant_id"] != tenant_id do
          {:reply, {:error, :not_found}, state}
        else
          resume_uuid = Ecto.UUID.cast!(resume_id)
          db_resume = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Resume, resume_uuid)

          if db_resume do
            # Update resume identity field
            identity = Map.get(parsed_data, "identity", %{})

            changeset = BotArmyJobApplications.Schemas.Resume.changeset(
              db_resume,
              %{
                "identity" => identity,
                "metadata" => Map.get(parsed_data, "metadata", %{})
              }
            )

            case BotArmyJobApplications.Repo.update(changeset) do
              {:ok, updated_db_resume} ->
                # Delete all existing roles and bullets for this resume
                BotArmyJobApplications.Repo.delete_all(
                  from r in BotArmyJobApplications.Schemas.ResumeRole,
                    where: r.resume_id == ^resume_id
                )

                # Delete all existing skills for this resume
                BotArmyJobApplications.Repo.delete_all(
                  from s in BotArmyJobApplications.Schemas.Skill,
                    where: s.resume_id == ^resume_id
                )

                # Create new roles and bullets
                :ok = create_roles_and_bullets(resume_id, parsed_data)

                # Create new skills
                :ok = create_skills(resume_id, parsed_data)

                # Update cache with new data
                updated_resume = schema_to_map(updated_db_resume)
                new_state = Map.put(state, resume_id, updated_resume)
                Logger.info("Replaced full resume in database: #{resume_id}")
                {:reply, {:ok, updated_resume}, new_state}

              {:error, changeset} ->
                Logger.error("Failed to replace resume: #{inspect(changeset.errors)}")
                {:reply, {:error, :database_error}, state}
            end
          else
            {:reply, {:error, :not_found}, state}
          end
        end
    end
  end

  @impl true
  def handle_call({:delete, tenant_id, resume_id}, _from, state) do
    case Map.get(state, resume_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      resume ->
        if resume["tenant_id"] != tenant_id do
          {:reply, {:error, :not_found}, state}
        else
          resume_uuid = Ecto.UUID.cast!(resume_id)

        # Get all role IDs for this resume first
        role_ids =
          BotArmyJobApplications.Repo.all(
            from r in BotArmyJobApplications.Schemas.ResumeRole,
              where: r.resume_id == ^resume_id,
              select: r.id
          )

        # Delete all bullets for those roles
        if Enum.any?(role_ids) do
          BotArmyJobApplications.Repo.delete_all(
            from b in BotArmyJobApplications.Schemas.ResumeBullet,
              where: b.role_id in ^role_ids
          )
        end

        # Delete all roles for this resume
        BotArmyJobApplications.Repo.delete_all(
          from r in BotArmyJobApplications.Schemas.ResumeRole,
            where: r.resume_id == ^resume_id
        )

        # Delete all skills for this resume
        BotArmyJobApplications.Repo.delete_all(
          from s in BotArmyJobApplications.Schemas.Skill,
            where: s.resume_id == ^resume_id
        )

          # Delete the resume itself
          case BotArmyJobApplications.Repo.delete_all(
            from r in BotArmyJobApplications.Schemas.Resume,
              where: r.id == ^resume_uuid
          ) do
            {_count, _} ->
              new_state = Map.delete(state, resume_id)
              Logger.info("Deleted resume and all related data: #{resume_id}")
              {:reply, :ok, new_state}

            _ ->
              {:reply, {:error, :delete_failed}, state}
          end
        end
    end
  end

  @impl true
  def handle_call({:get, tenant_id, resume_id}, _from, state) do
    case Map.get(state, resume_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      resume ->
        if resume["tenant_id"] == tenant_id do
          hydrated = hydrate_resume(resume_id, resume)
          {:reply, {:ok, hydrated}, state}
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:list, tenant_id}, _from, state) do
    # Hydrate all resumes (add roles and skills) for consistent data structure
    resumes = state
      |> Map.to_list()
      |> Enum.filter(fn {_resume_id, resume} -> resume["tenant_id"] == tenant_id end)
      |> Enum.map(fn {resume_id, resume} ->
        hydrate_resume(resume_id, resume)
      end)
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
      "tenant_id" => resume.tenant_id |> to_string(),
      "user_id" => if(resume.user_id, do: resume.user_id |> to_string(), else: nil),
      "identity" => resume.identity,
      "metadata" => resume.metadata,
      "source_file_path" => resume.source_file_path,
      "original_filename" => resume.original_filename,
      "created_at" => resume.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => resume.updated_at |> NaiveDateTime.to_iso8601()
    }
  end

  # Load roles (with bullets) and skills so ArtifactHandler/ResumeComposer get full resume
  defp hydrate_resume(resume_id, resume) do
    roles = load_roles_with_bullets(resume_id)
    skills = load_skills(resume_id)
    resume
    |> Map.put("roles", roles)
    |> Map.put("skills", skills)
  end

  defp load_roles_with_bullets(resume_id) do
    roles =
      BotArmyJobApplications.Repo.all(
        from r in BotArmyJobApplications.Schemas.ResumeRole,
          where: r.resume_id == ^resume_id,
          order_by: [asc: r.sort_order]
      )

    Enum.map(roles, fn role ->
      role_id = role.id |> to_string()
      bullets =
        BotArmyJobApplications.Repo.all(
          from b in BotArmyJobApplications.Schemas.ResumeBullet,
            where: b.role_id == ^role_id,
            order_by: [asc: b.sort_order]
        )
        |> Enum.map(&bullet_to_map/1)

      %{
        "id" => role_id,
        "title" => role.title,
        "company" => role.company,
        "start_date" => role.start_date,
        "end_date" => role.end_date,
        "framing_profiles" => role.framing_profiles,
        "bullets" => bullets
      }
    end)
  end

  defp bullet_to_map(b) do
    %{
      "id" => b.id |> to_string(),
      "text" => b.text,
      "alt_phrasings" => map_to_list(b.alt_phrasings),
      "tags" => map_to_list(b.tags),
      "metrics" => b.metrics,
      "strength" => b.strength
    }
  end

  defp load_skills(resume_id) do
    BotArmyJobApplications.Repo.all(
      from s in BotArmyJobApplications.Schemas.Skill,
        where: s.resume_id == ^resume_id
    )
    |> Enum.map(fn s ->
      %{
        "id" => s.id |> to_string(),
        "name" => s.name,
        "tags" => map_to_list(s.tags),
        "proficiency" => s.proficiency,
        "years" => s.years
      }
    end)
  end

  defp map_to_list(nil), do: []
  defp map_to_list(m) when is_list(m), do: m
  defp map_to_list(m) when is_map(m), do: Map.values(m)

  # Helper for creating roles and bullets from parsed resume data
  defp create_roles_and_bullets(resume_id, parsed_data) do
    roles = Map.get(parsed_data, "roles", [])

    Enum.with_index(roles)
    |> Enum.each(fn {role, idx} ->
      role_changeset = BotArmyJobApplications.Schemas.ResumeRole.changeset(
        %BotArmyJobApplications.Schemas.ResumeRole{resume_id: resume_id},
        %{
          "title" => Map.get(role, "title", ""),
          "company" => Map.get(role, "company", ""),
          "start_date" => Map.get(role, "start_date"),
          "end_date" => Map.get(role, "end_date"),
          "sort_order" => idx
        }
      )

      case BotArmyJobApplications.Repo.insert(role_changeset) do
        {:ok, db_role} ->
          bullets = Map.get(role, "bullets", [])

          Enum.with_index(bullets)
          |> Enum.each(fn {bullet, bullet_idx} ->
            bullet_changeset = BotArmyJobApplications.Schemas.ResumeBullet.changeset(
              %BotArmyJobApplications.Schemas.ResumeBullet{role_id: db_role.id},
              %{
                "text" => bullet,
                "sort_order" => bullet_idx
              }
            )

            BotArmyJobApplications.Repo.insert(bullet_changeset)
          end)

        {:error, reason} ->
          Logger.error("Failed to create role: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Helper for creating skills from parsed resume data
  defp create_skills(resume_id, parsed_data) do
    skills = Map.get(parsed_data, "skills", [])

    Enum.each(skills, fn skill ->
      skill_changeset = BotArmyJobApplications.Schemas.Skill.changeset(
        %BotArmyJobApplications.Schemas.Skill{resume_id: resume_id},
        %{
          "name" => Map.get(skill, "name", ""),
          "proficiency" => Map.get(skill, "proficiency", "intermediate"),
          "years" => Map.get(skill, "years", 0)
        }
      )

      BotArmyJobApplications.Repo.insert(skill_changeset)
    end)

    :ok
  end
end
