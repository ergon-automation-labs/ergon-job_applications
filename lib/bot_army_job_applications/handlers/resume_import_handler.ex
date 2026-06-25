defmodule BotArmyJobApplications.Handlers.ResumeImportHandler do
  @moduledoc """
  Handles resume file imports from TUI with automatic text extraction and LLM parsing.

  NATS endpoint: job.resume.import

  Payload:
    {
      "file_path": "/path/to/resume.pdf",
      "tenant_id": "uuid",
      "user_id": "uuid" (optional)
    }

  Returns:
    {
      "ok": true,
      "resume_id": "uuid",
      "identity": {...},
      "roles": [...],
      "skills": [...]
    }
  """

  require Logger

  alias BotArmyJobApplications.TextExtractor
  alias BotArmyJobApplications.ResumeStore

  def handle_import(payload) when is_map(payload) do
    file_path = payload["file_path"]
    tenant_id = payload["tenant_id"]
    user_id = payload["user_id"]

    cond do
      not is_binary(file_path) or file_path == "" ->
        %{"ok" => false, "error" => "missing file_path", "stage" => "validation"}

      not is_binary(tenant_id) or tenant_id == "" ->
        %{"ok" => false, "error" => "missing tenant_id", "stage" => "validation"}

      true ->
        import_resume(file_path, tenant_id, user_id)
    end
  end

  def handle_import(_),
    do: %{"ok" => false, "error" => "invalid_payload", "stage" => "validation"}

  defp import_resume(file_path, tenant_id, user_id) do
    with {:ok, resume_text} <- extract_text(file_path),
         {:ok, parsed_data} <- parse_resume(resume_text),
         {:ok, resume} <- store_resume(parsed_data, tenant_id, user_id) do
      %{
        "ok" => true,
        "resume_id" => resume["id"],
        "identity" => resume["identity"],
        "roles" => resume["roles"],
        "skills" => resume["skills"]
      }
    else
      {:error, reason, stage} ->
        Logger.warning("ResumeImportHandler failed at #{stage}: #{inspect(reason)}")
        %{"ok" => false, "error" => to_string(reason), "stage" => stage}

      {:error, reason} ->
        Logger.warning("ResumeImportHandler failed: #{inspect(reason)}")
        %{"ok" => false, "error" => to_string(reason), "stage" => "unknown"}
    end
  end

  defp extract_text(file_path) do
    case TextExtractor.extract(file_path, file_path) do
      {:ok, text} ->
        if String.trim(text) == "" do
          {:error, "file is empty or unreadable", "extraction"}
        else
          {:ok, text}
        end

      {:error, reason} ->
        {:error, reason, "extraction"}
    end
  rescue
    e ->
      {:error, "extraction failed: #{inspect(e)}", "extraction"}
  end

  defp parse_resume(resume_text) do
    system_prompt = """
    You are a resume parser. Extract the candidate's information and return ONLY valid JSON with this structure:
    {
      "identity": {"name": "string", "summary": "string"},
      "roles": [{"title": "string", "company": "string"}],
      "skills": [{"name": "string"}]
    }
    """

    request = %{
      "query" => resume_text,
      "system_prompt" => system_prompt
    }

    case query_llm(request) do
      {:ok, response} ->
        case extract_json_from_response(response) do
          {:ok, parsed} ->
            validate_structure(parsed)

          {:error, reason} ->
            {:error, reason, "parsing"}
        end

      {:error, reason} ->
        {:error, reason, "parsing"}
    end
  rescue
    e ->
      {:error, "parsing failed: #{inspect(e)}", "parsing"}
  end

  defp query_llm(request) do
    nats_conn = Application.get_env(:bot_army_job_applications, :nats_conn)

    case Gnat.request(nats_conn, "llm.converse", Jason.encode!(request), timeout: 30_000) do
      {:ok, %{body: body}} ->
        case Jason.decode(body) do
          {:ok, response} -> {:ok, response}
          {:error, _} -> {:error, "invalid json response"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  catch
    :exit, _ -> {:error, "nats connection error"}
  end

  defp extract_json_from_response(response) when is_map(response) do
    data = response["data"] || response["response"] || response

    if is_map(data) do
      {:ok, data}
    else
      case Jason.decode(to_string(data)) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, _} -> {:error, "could not extract json"}
      end
    end
  end

  defp extract_json_from_response(_), do: {:error, "invalid response format"}

  defp validate_structure(parsed) when is_map(parsed) do
    with true <- is_map(parsed["identity"]),
         true <- is_list(parsed["roles"]),
         true <- is_list(parsed["skills"]) do
      {:ok, parsed}
    else
      _ -> {:error, "missing required fields"}
    end
  end

  defp validate_structure(_), do: {:error, "invalid parsed structure"}

  defp store_resume(parsed_data, tenant_id, user_id) do
    payload = %{
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "identity" => parsed_data["identity"],
      "roles" => parsed_data["roles"],
      "skills" => parsed_data["skills"]
    }

    case ResumeStore.create_from_parsed(payload, %{"tenant_id" => tenant_id, "user_id" => user_id}) do
      {:ok, resume} ->
        {:ok, resume}

      {:error, reason} ->
        {:error, reason, "storage"}
    end
  rescue
    e ->
      {:error, "storage failed: #{inspect(e)}", "storage"}
  end
end
