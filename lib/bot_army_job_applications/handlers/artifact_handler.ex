defmodule BotArmyJobApplications.Handlers.ArtifactHandler do
  @moduledoc """
  Handles artifact generation for job applications.

  Two-phase LLM orchestration:
  1. JD analysis phase - Extract tags from JD text
  2. Compose phase - Select resume bullets and generate cover letter
  """

  require Logger

  defp resume_store do
    Application.get_env(:bot_army_job_applications, :resume_store, BotArmyJobApplications.ResumeStore)
  end

  @doc """
  Handle artifact request.

  Initiates the two-phase artifact generation pipeline.
  """
  def handle_request(message) do
    event_id = message["event_id"]
    payload = message["payload"]

    case validate_artifact_request(payload) do
      :ok ->
        application_id = payload["application_id"]
        resume_id = payload["resume_id"]

        case BotArmyJobApplications.ApplicationServer.get(application_id) do
          {:ok, application} ->
            case resume_store().get(resume_id) do
              {:ok, resume} ->
                # Start JD analysis phase
                initiate_jd_analysis(application, resume, event_id)

              {:error, :not_found} ->
                Logger.error("Resume not found: #{resume_id}")
                BotArmyJobApplications.NATS.Publisher.publish_error(event_id, :not_found, "Resume not found")
            end

          {:error, :not_found} ->
            Logger.error("Application not found: #{application_id}")
            BotArmyJobApplications.NATS.Publisher.publish_error(event_id, :not_found, "Application not found")
        end

      {:error, reason} ->
        Logger.warning("Invalid artifact request: #{inspect(reason)}")
        BotArmyJobApplications.NATS.Publisher.publish_error(event_id, reason, "Invalid artifact request")
    end
  end

  @doc """
  Handle JD analysis response.

  Receives LLM-extracted JD tags and initiates resume composition.
  """
  def handle_jd_analysis_response(message) do
    source_metadata = message["source_metadata"] || %{}
    application_id = source_metadata["application_id"]
    payload = message["payload"]

    case BotArmyJobApplications.ApplicationServer.get(application_id) do
      {:ok, application} ->
        jd_tags = payload["tags"] || []

        case resume_store().get(application["resume_id"]) do
          {:ok, resume} ->
            # Compose resume for this JD
            composed = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

            # Update application with JD tags and coverage score
            BotArmyJobApplications.ApplicationServer.set_artifacts(
              application_id,
              %{
                "jd_tags" => jd_tags,
                "coverage_score" => composed["coverage_score"]
              }
            )

            # Initiate cover letter generation
            initiate_cover_letter_generation(application, composed, jd_tags, application_id)

          {:error, :not_found} ->
            Logger.error("Resume not found during JD analysis")
        end

      {:error, :not_found} ->
        Logger.error("Application not found during JD analysis: #{application_id}")
    end
  end

  @doc """
  Handle cover letter response.

  Receives generated cover letter and completes artifact generation.
  """
  def handle_cover_letter_response(message) do
    source_metadata = message["source_metadata"] || %{}
    application_id = source_metadata["application_id"]
    payload = message["payload"]

    cover_letter_md = payload["cover_letter_md"]

    case BotArmyJobApplications.ApplicationServer.get(application_id) do
      {:ok, application} ->
        # Get the composed resume from artifacts
        artifacts = application["artifacts"] || %{}

        # Update artifacts with cover letter
        final_artifacts = Map.merge(artifacts, %{
          "cover_letter_md" => cover_letter_md,
          "composed_at" => NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601()
        })

        case BotArmyJobApplications.ApplicationServer.set_artifacts(application_id, final_artifacts) do
          {:ok, updated_app} ->
            Logger.info("Artifacts complete for application: #{application_id}")

            # Publish artifact result
            publish_artifact_result(updated_app)

          {:error, reason} ->
            Logger.error("Failed to set final artifacts: #{inspect(reason)}")
        end

      {:error, :not_found} ->
        Logger.error("Application not found during cover letter response: #{application_id}")
    end
  end

  # Private helpers

  defp validate_artifact_request(payload) when is_map(payload) do
    with :ok <- require_field(payload, "application_id"),
         :ok <- require_field(payload, "resume_id") do
      :ok
    else
      err -> err
    end
  end

  defp validate_artifact_request(_), do: {:error, :invalid_payload}

  defp require_field(payload, field) do
    case payload do
      %{^field => value} when value not in [nil, ""] -> :ok
      _ -> {:error, {:missing_field, field}}
    end
  end

  defp initiate_jd_analysis(application, _resume, event_id) do
    jd_text = application["jd_text"] || ""

    # Request JD analysis from LLM Proxy
    llm_payload = %{
      "text" => jd_text,
      "task" => "extract_tags",
      "output_schema" => %{
        "tags" => ["string"]
      }
    }

    case BotArmyJobApplications.NATS.Publisher.publish_llm_request(
      llm_payload,
      "jd_analysis",
      application["id"]
    ) do
      :ok ->
        Logger.info("Initiated JD analysis for application: #{application["id"]}")
        # Update application with pending signal
        BotArmyJobApplications.ApplicationServer.set_pending_signal(
          application["id"],
          %{"waiting_for" => "jd_analysis"}
        )

      {:error, reason} ->
        Logger.error("Failed to publish JD analysis request: #{inspect(reason)}")
        BotArmyJobApplications.NATS.Publisher.publish_error(event_id, reason, "Failed to initiate JD analysis")
    end
  end

  defp initiate_cover_letter_generation(application, composed, jd_tags, application_id) do
    # Prepare context for cover letter generation
    selected_bullets = composed["roles"]
    |> Enum.flat_map(fn role -> role["bullets"] end)
    |> Enum.sort_by(fn bullet -> bullet["tag_score"] end, :desc)
    |> Enum.take(10)

    selected_skills = composed["skills"] |> Enum.take(5)

    llm_payload = %{
      "context" => %{
        "company" => application["company"],
        "role_title" => application["role_title"],
        "jd_text" => application["jd_text"],
        "jd_tags" => jd_tags,
        "resume_summary" => composed["summary"],
        "selected_bullets" => selected_bullets,
        "selected_skills" => selected_skills,
        "coverage_score" => composed["coverage_score"]
      },
      "task" => "generate_cover_letter",
      "output_schema" => %{
        "cover_letter_md" => "string"
      }
    }

    case BotArmyJobApplications.NATS.Publisher.publish_llm_request(
      llm_payload,
      "cover_letter",
      application_id
    ) do
      :ok ->
        Logger.info("Initiated cover letter generation for application: #{application_id}")
        # Store the composed resume for later use
        BotArmyJobApplications.ApplicationServer.set_artifacts(
          application_id,
          %{
            "resume_md" => format_resume_bullets(composed["roles"], composed["summary"])
          }
        )

      {:error, reason} ->
        Logger.error("Failed to publish cover letter request: #{inspect(reason)}")
    end
  end

  defp format_resume_bullets(roles, summary) do
    # Format composed resume as markdown
    header = """
    # Resume

    ## Summary
    #{summary}

    """

    roles_md = roles
    |> Enum.map(fn role ->
      bullets = role["bullets"]
      |> Enum.map(fn bullet -> "- #{bullet["selected_text"]}" end)
      |> Enum.join("\n")

      """
      ### #{role["title"]} at #{role["company"]}
      #{bullets}
      """
    end)
    |> Enum.join("\n\n")

    header <> roles_md
  end

  defp publish_artifact_result(application) do
    event = %{
      "event" => "job.application.artifact.result",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => get_node_name(),
      "triggered_by" => "job_applications.bot",
      "schema_version" => "1.0",
      "payload" => %{
        "application_id" => application["id"],
        "company" => application["company"],
        "role_title" => application["role_title"],
        "cover_letter_md" => application["artifacts"]["cover_letter_md"],
        "resume_md" => application["artifacts"]["resume_md"],
        "coverage_score" => application["coverage_score"]
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp get_node_name do
    node() |> Atom.to_string()
  end
end
