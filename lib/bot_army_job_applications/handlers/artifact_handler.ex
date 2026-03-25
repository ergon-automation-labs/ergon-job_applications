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

  Receives LLM-generated response with JD tags and initiates resume composition.
  """
  def handle_jd_analysis_response(message) do
    source_metadata = message["source_metadata"] || %{}
    application_id = source_metadata["application_id"]
    resume_id = source_metadata["resume_id"]
    payload = message["payload"]

    # Extract JSON from LLM response completion
    case extract_json_field(payload["completion"], "tags") do
      {:ok, jd_tags} ->
        if resume_id do
          case BotArmyJobApplications.ApplicationServer.get(application_id) do
            {:ok, application} ->
              case resume_store().get(resume_id) do
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
                  initiate_cover_letter_generation(application, composed, jd_tags, application_id, resume_id)

                {:error, :not_found} ->
                  Logger.error("Resume not found during JD analysis")
              end

            {:error, :not_found} ->
              Logger.error("Application not found during JD analysis: #{application_id}")
          end
        else
          Logger.error("No resume_id in source_metadata during JD analysis: #{application_id}")
        end

      {:error, reason} ->
        Logger.error("Failed to extract JD tags from LLM response: #{inspect(reason)}")
    end
  end

  @doc """
  Handle cover letter response.

  Receives LLM-generated cover letter text and completes artifact generation.
  """
  def handle_cover_letter_response(message) do
    source_metadata = message["source_metadata"] || %{}
    application_id = source_metadata["application_id"]
    payload = message["payload"]

    # LLM returns the cover letter text in completion field
    cover_letter_md = payload["completion"] || ""

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

            # Publish cover letter result (arrives after LLM)
            publish_cover_letter_result(updated_app, cover_letter_md)

            # Also publish combined artifact result for backwards compatibility
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

  defp initiate_jd_analysis(application, resume, event_id) do
    jd_text = application["jd_text"] || ""
    resume_id = resume["id"]

    # Build JD analysis prompt for LLM
    prompt = """
    Extract the most important skills, technologies, and qualifications from this job description.
    Return the result as JSON with a "tags" array of strings.

    Job Description:
    #{jd_text}

    Return only valid JSON in this format:
    {"tags": ["tag1", "tag2", "tag3", ...]}
    """

    llm_payload = %{
      "text" => prompt,
      "prompt_id" => "jd_analysis_#{application["id"]}"
    }

    case BotArmyJobApplications.NATS.Publisher.publish_llm_request_with_metadata(
      llm_payload,
      "jd_analysis",
      application["id"],
      %{"resume_id" => resume_id}
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

  defp initiate_cover_letter_generation(application, composed, jd_tags, application_id, resume_id) do
    # Prepare context for cover letter generation
    selected_bullets = composed["roles"]
    |> Enum.flat_map(fn role -> role["bullets"] end)
    |> Enum.sort_by(fn bullet -> bullet["tag_score"] end, :desc)
    |> Enum.take(10)

    selected_skills = composed["skills"] |> Enum.take(5)

    bullets_text = selected_bullets
    |> Enum.map(fn b -> "- #{b["selected_text"]}" end)
    |> Enum.join("\n")

    skills_text = selected_skills |> Enum.join(", ")

    # Build cover letter prompt for LLM
    prompt = """
    Write a professional cover letter for the following position. \
    Use the provided resume excerpts and tailor the letter to the job description keywords.

    Company: #{application["company"]}
    Position: #{application["role_title"]}
    Coverage Score: #{coverage_pct(composed["coverage_score"])}%

    Key Job Requirements (tags): #{Enum.join(jd_tags, ", ")}

    Relevant Resume Bullets:
    #{bullets_text}

    Relevant Skills: #{skills_text}

    Resume Summary: #{composed["summary"]}

    Write a compelling cover letter in markdown format. Return only the markdown content, no code blocks.
    """

    llm_payload = %{
      "text" => prompt,
      "prompt_id" => "cover_letter_#{application_id}"
    }

    case BotArmyJobApplications.NATS.Publisher.publish_llm_request_with_metadata(
      llm_payload,
      "cover_letter",
      application_id,
      %{"resume_id" => resume_id}
    ) do
      :ok ->
        Logger.info("Initiated cover letter generation for application: #{application_id}")
        # Store the composed resume for later use
        resume_md = format_resume_bullets(composed["roles"], composed["summary"])
        BotArmyJobApplications.ApplicationServer.set_artifacts(
          application_id,
          %{
            "resume_md" => resume_md
          }
        )

        # Publish resume variant immediately (no LLM wait)
        publish_resume_variant_result(application, resume_md, composed["coverage_score"])

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
    artifacts = application["artifacts"] || %{}
    coverage = application["coverage_score"] || artifacts["coverage_score"]

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
        "cover_letter_md" => artifacts["cover_letter_md"],
        "resume_md" => artifacts["resume_md"],
        "coverage_score" => coverage
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp publish_resume_variant_result(application, resume_md, coverage_score) do
    event = %{
      "event" => "job.application.resume_variant.result",
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
        "resume_md" => resume_md,
        "coverage_score" => coverage_score
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp publish_cover_letter_result(application, cover_letter_md) do
    event = %{
      "event" => "job.application.cover_letter.result",
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
        "cover_letter_md" => cover_letter_md
      }
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp coverage_pct(n) when is_number(n) and n >= 0 and n <= 1, do: round(n * 100)
  defp coverage_pct(_), do: 0

  defp get_node_name do
    node() |> Atom.to_string()
  end

  defp extract_json_field(text, field_name) when is_binary(text) do
    # Try to extract JSON from text (may be wrapped in code fences)
    text_clean = String.trim(text)

    # Remove markdown code fences if present
    json_text = case text_clean do
      "```json\n" <> rest -> String.slice(rest, 0..-5//-1)  # Remove trailing ```
      "```" <> rest -> String.slice(rest, 0..-5//-1)
      _ -> text_clean
    end

    case Jason.decode(json_text) do
      {:ok, data} when is_map(data) ->
        case Map.get(data, field_name) do
          value when is_list(value) -> {:ok, value}
          value when is_binary(value) -> {:ok, [value]}
          _ -> {:error, :field_not_found}
        end

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp extract_json_field(_, _) do
    {:error, :invalid_input}
  end
end
