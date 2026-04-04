defmodule BotArmyJobApplications.Handlers.ResumeTuiHandler do
  @moduledoc """
  Handles resume CRUD operations from TUI.

  Three synchronous request/reply endpoints:
  - job.resume.create — create new resume from TUI parsed data
  - job.resume.update — replace full resume (identity, roles, skills)
  - job.resume.delete — delete resume and all related data
  """

  require Logger

  defp resume_store do
    Application.get_env(:bot_army_job_applications, :resume_store, BotArmyJobApplications.ResumeStore)
  end

  @doc """
  Create a new resume from TUI structured payload.

  Payload:
    {
      "tenant_id": "uuid",
      "user_id": "uuid" (optional),
      "identity": {
        "name": "...",
        "summary": "...",
        "location_preferences": "San Francisco, Austin, Remote OK" (optional),
        "salary_floor": 150 (optional, in thousands)
      },
      "roles": [
        { "title": "...", "company": "...", "start_date": "YYYY-MM", "end_date": "YYYY-MM", "bullets": ["text1", "text2"] }
      ],
      "skills": [
        { "name": "...", "proficiency": "expert|advanced|intermediate|beginner", "years": 3 }
      ]
    }

  Returns: %{"ok" => true, "resume_id" => id} or %{"ok" => false, "error" => reason}
  """
  def handle_create(payload) when is_map(payload) do
    tenant_id = payload["tenant_id"]

    if not is_binary(tenant_id) or tenant_id == "" do
      %{"ok" => false, "error" => "missing tenant_id"}
    else
      file_metadata = %{
        "tenant_id" => tenant_id,
        "user_id" => payload["user_id"]
      }

      case resume_store().create_from_parsed(payload, file_metadata) do
        {:ok, resume} ->
          %{"ok" => true, "resume_id" => resume["id"]}

        {:error, reason} ->
          Logger.warning("ResumeTuiHandler.handle_create failed: #{inspect(reason)}")
          %{"ok" => false, "error" => to_string(reason)}
      end
    end
  end

  def handle_create(_), do: %{"ok" => false, "error" => "invalid_payload"}

  @doc """
  Update an existing resume, replacing all identity, roles and skills.

  Payload: same as create, plus top-level "resume_id": "uuid" and "tenant_id": "uuid"

  Returns: %{"ok" => true} or %{"ok" => false, "error" => reason}
  """
  def handle_update(payload) when is_map(payload) do
    tenant_id = payload["tenant_id"]
    resume_id = payload["resume_id"]

    if not is_binary(tenant_id) or tenant_id == "" do
      %{"ok" => false, "error" => "missing tenant_id"}
    else
      if not is_binary(resume_id) or resume_id == "" do
        %{"ok" => false, "error" => "missing resume_id"}
      else
        case resume_store().replace_full(tenant_id, resume_id, payload) do
          {:ok, _resume} ->
            %{"ok" => true}

          {:error, reason} ->
            Logger.warning("ResumeTuiHandler.handle_update failed for #{resume_id}: #{inspect(reason)}")
            %{"ok" => false, "error" => to_string(reason)}
        end
      end
    end
  end

  def handle_update(_), do: %{"ok" => false, "error" => "invalid_payload"}

  @doc """
  Delete a resume and all related data.

  Payload: { "tenant_id": "uuid", "resume_id": "uuid" }

  Returns: %{"ok" => true} or %{"ok" => false, "error" => reason}
  """
  def handle_delete(payload) when is_map(payload) do
    tenant_id = payload["tenant_id"]
    resume_id = payload["resume_id"]

    if not is_binary(tenant_id) or tenant_id == "" do
      %{"ok" => false, "error" => "missing tenant_id"}
    else
      if not is_binary(resume_id) or resume_id == "" do
        %{"ok" => false, "error" => "missing resume_id"}
      else
        case resume_store().delete(tenant_id, resume_id) do
          :ok ->
            Logger.info("Deleted resume via TUI: #{resume_id}")
            %{"ok" => true}

          {:error, reason} ->
            Logger.warning("ResumeTuiHandler.handle_delete failed for #{resume_id}: #{inspect(reason)}")
            %{"ok" => false, "error" => to_string(reason)}
        end
      end
    end
  end

  def handle_delete(_), do: %{"ok" => false, "error" => "invalid_payload"}
end
