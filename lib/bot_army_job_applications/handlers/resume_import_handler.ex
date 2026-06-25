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
    Logger.info(
      "[ResumeImportHandler] handle_import called with payload keys: #{inspect(Map.keys(payload))}"
    )

    file_path = payload["file_path"]
    tenant_id = payload["tenant_id"]
    user_id = payload["user_id"]

    Logger.debug(
      "[ResumeImportHandler] file_path=#{inspect(file_path)}, tenant_id=#{inspect(tenant_id)}, user_id=#{inspect(user_id)}"
    )

    cond do
      not is_binary(file_path) or file_path == "" ->
        Logger.warning("[ResumeImportHandler] validation failed: missing file_path")
        %{"ok" => false, "error" => "missing file_path", "stage" => "validation"}

      not is_binary(tenant_id) or tenant_id == "" ->
        Logger.warning("[ResumeImportHandler] validation failed: missing tenant_id")
        %{"ok" => false, "error" => "missing tenant_id", "stage" => "validation"}

      true ->
        Logger.info("[ResumeImportHandler] validation passed, starting import")
        import_resume(file_path, tenant_id, user_id)
    end
  end

  def handle_import(payload) do
    Logger.warning(
      "[ResumeImportHandler] handle_import called with invalid payload: #{inspect(payload)}"
    )

    %{"ok" => false, "error" => "invalid_payload", "stage" => "validation"}
  end

  defp import_resume(file_path, tenant_id, user_id) do
    Logger.info("[ResumeImportHandler] starting import_resume for #{file_path}")

    with {:ok, resume_text} <- extract_text(file_path),
         {:ok, parsed_data} <- parse_resume(resume_text),
         {:ok, resume} <- store_resume(parsed_data, tenant_id, user_id) do
      Logger.info("[ResumeImportHandler] import successful, resume_id=#{resume["id"]}")

      %{
        "ok" => true,
        "resume_id" => resume["id"],
        "identity" => resume["identity"],
        "roles" => resume["roles"],
        "skills" => resume["skills"]
      }
    else
      {:error, reason, stage} ->
        Logger.error("ResumeImportHandler failed at #{stage}: #{inspect(reason)}")
        %{"ok" => false, "error" => to_string(reason), "stage" => stage}

      {:error, reason} ->
        Logger.error("ResumeImportHandler failed: #{inspect(reason)}")
        %{"ok" => false, "error" => to_string(reason), "stage" => "unknown"}
    end
  end

  defp extract_text(file_path) do
    Logger.info("[ResumeImportHandler] extract_text starting for #{file_path}")

    case TextExtractor.extract(file_path, file_path) do
      {:ok, text} ->
        Logger.info(
          "[ResumeImportHandler] extract_text succeeded, got #{String.length(text)} bytes"
        )

        if String.trim(text) == "" do
          Logger.warning("[ResumeImportHandler] extract_text: file is empty")
          {:error, "file is empty or unreadable", "extraction"}
        else
          {:ok, text}
        end

      {:error, reason} ->
        Logger.error("[ResumeImportHandler] extract_text failed: #{inspect(reason)}")
        {:error, reason, "extraction"}
    end
  rescue
    e ->
      Logger.error("[ResumeImportHandler] extract_text exception: #{inspect(e)}")
      {:error, "extraction failed: #{inspect(e)}", "extraction"}
  end

  defp parse_resume(resume_text) do
    Logger.info("[ResumeImportHandler] parse_resume starting")

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

    Logger.debug("[ResumeImportHandler] parse_resume: calling query_llm")

    case query_llm(request) do
      {:ok, response} ->
        Logger.info("[ResumeImportHandler] parse_resume: got LLM response")

        case extract_json_from_response(response) do
          {:ok, parsed} ->
            Logger.info("[ResumeImportHandler] parse_resume: extracted JSON, validating")
            validate_structure(parsed)

          {:error, reason} ->
            Logger.error("[ResumeImportHandler] parse_resume: JSON extraction failed: #{reason}")
            {:error, reason, "parsing"}
        end

      {:error, reason} ->
        Logger.error("[ResumeImportHandler] parse_resume: LLM query failed: #{inspect(reason)}")
        {:error, reason, "parsing"}
    end
  rescue
    e ->
      Logger.error("[ResumeImportHandler] parse_resume exception: #{inspect(e)}")
      {:error, "parsing failed: #{inspect(e)}", "parsing"}
  end

  defp query_llm(request) do
    Logger.info("[ResumeImportHandler] query_llm: getting NATS connection")
    nats_conn = Application.get_env(:bot_army_job_applications, :nats_conn)

    Logger.debug("[ResumeImportHandler] query_llm: nats_conn=#{inspect(nats_conn)}")

    if nats_conn == nil do
      Logger.error("[ResumeImportHandler] query_llm: NATS connection not configured")
      {:error, "nats connection not configured"}
    else
      Logger.info("[ResumeImportHandler] query_llm: sending request to llm.converse")

      case Gnat.request(nats_conn, "llm.converse", Jason.encode!(request), timeout: 30_000) do
        {:ok, %{body: body}} ->
          Logger.info("[ResumeImportHandler] query_llm: got response")

          case Jason.decode(body) do
            {:ok, response} ->
              Logger.info("[ResumeImportHandler] query_llm: response decoded")
              {:ok, response}

            {:error, err} ->
              Logger.error("[ResumeImportHandler] query_llm: JSON decode error: #{inspect(err)}")
              {:error, "invalid json response"}
          end

        {:error, reason} ->
          Logger.error("[ResumeImportHandler] query_llm: request failed: #{inspect(reason)}")
          {:error, reason}
      end
    end
  catch
    :exit, err ->
      Logger.error("[ResumeImportHandler] query_llm: exit exception: #{inspect(err)}")
      {:error, "nats connection error"}
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
    Logger.info("[ResumeImportHandler] store_resume: storing to database")

    payload = %{
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "identity" => parsed_data["identity"],
      "roles" => parsed_data["roles"],
      "skills" => parsed_data["skills"]
    }

    Logger.debug("[ResumeImportHandler] store_resume: calling create_from_parsed")

    case ResumeStore.create_from_parsed(payload, %{"tenant_id" => tenant_id, "user_id" => user_id}) do
      {:ok, resume} ->
        Logger.info("[ResumeImportHandler] store_resume: success, resume_id=#{resume["id"]}")
        {:ok, resume}

      {:error, reason} ->
        Logger.error("[ResumeImportHandler] store_resume: database error: #{inspect(reason)}")
        {:error, reason, "storage"}
    end
  rescue
    e ->
      Logger.error("[ResumeImportHandler] store_resume exception: #{inspect(e)}")
      {:error, "storage failed: #{inspect(e)}", "storage"}
  end
end
