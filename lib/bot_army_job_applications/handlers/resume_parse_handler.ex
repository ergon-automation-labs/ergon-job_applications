defmodule BotArmyJobApplications.Handlers.ResumeParseHandler do
  @moduledoc """
  Handles resume upload, extraction, LLM parsing, and persistence.

  Three-phase pipeline:
  1. Extract text from uploaded file (PDF/DOCX/MD/TXT)
  2. Parse via LLM to structured JSON (identity, roles, skills)
  3. Persist to database with file metadata
  """

  require Logger

  @doc """
  Handle resume upload event.

  Receives: job.resume.upload with file_path, original_filename
  Extracts text and initiates LLM parsing.
  """
  def handle_upload(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)
    event_id = message["event_id"]
    payload = message["payload"]

    file_path = payload["file_path"]
    original_filename = payload["original_filename"]

    case validate_upload_request(payload) do
      :ok ->
        case extract_resume_text(file_path, original_filename) do
          {:ok, text} ->
            # Initiate LLM parse with file metadata in source_metadata
            initiate_parse(text, event_id, file_path, original_filename, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Failed to extract resume text: #{inspect(reason)}")
            publish_parse_failed(event_id, file_path, :extraction_failed, tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.warning("Invalid upload request: #{inspect(reason)}")
        publish_parse_failed(event_id, file_path, reason, tenant_id, user_id)
    end
  end

  @doc """
  Handle LLM parse response.

  Receives: events.llm.completion with source_domain="resume_parse"
  Persists parsed resume to database.
  """
  def handle_parse_response(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyLibraryCore.Tenant.extract_context(message)
    source_metadata = message["source_metadata"] || %{}
    payload = message["payload"]

    # Only handle resume_parse requests
    if source_metadata["source_domain"] == "resume_parse" do
      file_path = source_metadata["file_path"]
      original_filename = source_metadata["original_filename"]

      case extract_json_field(payload["completion"]) do
        {:ok, full_resume} ->
          # Validate we have required fields
          case validate_parsed_resume(full_resume, payload["completion"]) do
            {:ok, parsed_data} ->
              persist_resume(parsed_data, file_path, original_filename, tenant_id, user_id)

            {:error, reason} ->
              Logger.error("Invalid parsed resume structure: #{inspect(reason)}")
              publish_parse_failed(nil, file_path, :invalid_structure, tenant_id, user_id)
          end

        {:error, reason} ->
          Logger.error("Failed to extract resume JSON: #{inspect(reason)}")
          publish_parse_failed(nil, file_path, :json_extraction_failed, tenant_id, user_id)
      end
    end
  end

  # Private helpers

  defp validate_upload_request(payload) when is_map(payload) do
    with :ok <- require_field(payload, "file_path"),
         :ok <- require_field(payload, "original_filename") do
      :ok
    else
      err -> err
    end
  end

  defp validate_upload_request(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp extract_resume_text(file_path, original_filename) do
    BotArmyJobApplications.TextExtractor.extract(file_path, original_filename)
  end

  defp initiate_parse(text, event_id, file_path, original_filename, tenant_id, user_id) do
    prompt = """
    Parse the following resume text and return ONLY a JSON object with this structure:
    {
      "identity": {
        "name": "Full Name",
        "email": "email@example.com or null if not found",
        "phone": "Phone number or null if not found",
        "linkedin": "LinkedIn URL or null if not found",
        "summary": "Professional summary or objective",
        "summary_variants": ["Alternative summary 1", "Alternative summary 2"]
      },
      "roles": [
        {
          "title": "Job Title",
          "company": "Company Name",
          "start_date": "YYYY-MM",
          "end_date": "YYYY-MM or present",
          "bullets": ["Accomplishment bullet 1", "Accomplishment bullet 2"]
        }
      ],
      "skills": [
        {
          "name": "Skill Name",
          "proficiency": "expert|advanced|intermediate|beginner",
          "years": 0
        }
      ]
    }

    Resume text:
    #{text}
    """

    llm_payload = %{
      "text" => prompt,
      "prompt_id" => "resume_parse_#{event_id}"
    }

    case BotArmyJobApplications.NATS.Publisher.publish_llm_request_with_metadata(
           llm_payload,
           "resume_parse",
           nil,
           %{
             "file_path" => file_path,
             "original_filename" => original_filename,
             "tenant_id" => tenant_id,
             "user_id" => user_id
           }
         ) do
      :ok ->
        Logger.info("Initiated resume parse for: #{original_filename}")

      {:error, reason} ->
        Logger.error("Failed to publish resume parse request: #{inspect(reason)}")
        publish_parse_failed(event_id, file_path, :publish_failed, tenant_id, user_id)
    end
  end

  defp validate_parsed_resume(parsed_resume, _raw_text) when is_map(parsed_resume) do
    # Verify minimal structure: identity should exist
    case parsed_resume do
      %{"identity" => identity} when is_map(identity) ->
        # Include full parsed resume in validated output
        {:ok, parsed_resume}

      _ ->
        {:error, :missing_identity_section}
    end
  end

  defp validate_parsed_resume(_, _), do: {:error, :invalid_resume_format}

  defp persist_resume(parsed_data, file_path, original_filename, tenant_id, user_id) do
    case extract_full_resume_from_llm(parsed_data) do
      {:ok, resume_data} ->
        file_metadata = %{
          "file_path" => file_path,
          "original_filename" => original_filename,
          "tenant_id" => tenant_id,
          "user_id" => user_id
        }

        case BotArmyJobApplications.ResumeStore.create_from_parsed(resume_data, file_metadata) do
          {:ok, resume} ->
            Logger.info("Persisted parsed resume: #{resume["id"]}")
            publish_resume_created(resume, tenant_id, user_id)
            # Clean up temp file
            BotArmyJobApplications.FileStore.delete(file_path)

          {:error, reason} ->
            Logger.error("Failed to persist parsed resume: #{inspect(reason)}")
            publish_parse_failed(nil, file_path, :persistence_failed, tenant_id, user_id)
        end

      {:error, reason} ->
        Logger.error("Failed to extract full resume from LLM response: #{inspect(reason)}")
        publish_parse_failed(nil, file_path, :extraction_failed, tenant_id, user_id)
    end
  end

  # The full parsed resume is already extracted by extract_json_field
  defp extract_full_resume_from_llm(parsed_data) when is_map(parsed_data) do
    {:ok, parsed_data}
  end

  defp extract_full_resume_from_llm(_), do: {:error, :invalid_parsed_data}

  defp publish_resume_created(resume, tenant_id, user_id) do
    event = %{
      "event" => "job.resume.created",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "resume_id" => resume["id"],
        "name" => resume.dig("identity", "name") || "",
        "original_filename" => resume["original_filename"],
        "created_at" => resume["created_at"]
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp publish_parse_failed(event_id, file_path, reason, tenant_id, user_id) do
    event = %{
      "event" => "job.resume.parse.failed",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "file_path" => file_path,
        "reason" => inspect(reason),
        "triggered_by_event_id" => event_id
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end

  defp extract_json_field(text) when is_binary(text) do
    extract_json_field(text, nil)
  end

  defp extract_json_field(text, _field_name) when is_binary(text) do
    # Try to extract JSON from text (may be wrapped in code fences)
    text_clean = String.trim(text)

    # Remove markdown code fences if present
    json_text =
      case text_clean do
        # Remove trailing ```
        "```json\n" <> rest -> String.slice(rest, 0..-5//-1)
        "```" <> rest -> String.slice(rest, 0..-5//-1)
        _ -> text_clean
      end

    case Jason.decode(json_text) do
      {:ok, data} when is_map(data) ->
        {:ok, data}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp extract_json_field(_, _) do
    {:error, :invalid_input}
  end
end
