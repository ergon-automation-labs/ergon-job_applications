defmodule BotArmyJobApplications.Handlers.InterviewPrepHandler do
  @moduledoc """
  Handles interview preparation requests.

  Two-phase workflow:
  1. Synchronous request handling (fire LLM request)
  2. Async LLM semantic response (store results, push GTD inbox item)

  Subscribes to:
  - job.application.interview_prep.request — Trigger prep generation
  - events.llm.completion with source_domain="interview_prep" — LLM results
  """

  require Logger

  alias BotArmyJobApplications.{
    ApplicationStore,
    ResumeStore,
    NATS.Publisher
  }

  @doc """
  Handle interview prep request from TUI.

  Payload:
  ```json
  {
    "application_id": "uuid"
  }
  ```

  Fires async LLM request to generate behavioral, technical, company research, and cheat sheet content.
  """
  def handle_request(message, reply_to \\ nil, conn \\ nil)

  def handle_request(message, _reply_to, _conn) when is_map(message) do
    %{tenant_id: tenant_id, user_id: _user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    application_id = payload["application_id"]

    case validate_request_payload(payload) do
      :ok ->
        case application_store().get(tenant_id, application_id) do
          {:ok, application} ->
            case get_default_resume(tenant_id) do
              {:ok, resume} ->
                fire_interview_prep_request(application, resume)

              {:error, reason} ->
                Logger.warning("Could not fetch resume for interview prep: #{inspect(reason)}")
            end

          {:error, reason} ->
            Logger.error("Could not fetch application for interview prep: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Invalid interview prep request: #{inspect(reason)}")
    end

    :ok
  end

  def handle_request(_, _, _), do: :ok

  @doc """
  Handle LLM interview prep response.

  Extracts application_id from source_metadata, parses prep content,
  updates application artifacts, pushes to GTD.
  """
  def handle_llm_response(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    source_metadata = message["source_metadata"] || %{}
    application_id = source_metadata["application_id"]
    payload = message["payload"] || %{}
    prep_text = payload["completion"] || ""

    case application_store().get(tenant_id, application_id) do
      {:ok, application} ->
        # Store prep in artifacts
        existing_artifacts = application["artifacts"] || %{}

        updated_artifacts =
          Map.merge(existing_artifacts, %{
            "interview_prep_md" => prep_text,
            "interview_prep_at" => NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()
          })

        case application_store().update(tenant_id, application_id, %{
               "artifacts" => updated_artifacts
             }) do
          {:ok, updated_application} ->
            Logger.info(
              "Interview prep generated and stored for application #{application_id} (#{updated_application["company"]} — #{updated_application["role_title"]})"
            )

            # Publish result event
            publish_interview_prep_result(updated_application, prep_text, tenant_id, user_id)

            # Push to GTD inbox
            if Application.get_env(:bot_army_job_applications, :enable_gtd_integration, true) do
              publish_gtd_prep_task(updated_application, tenant_id, user_id)
            end

          {:error, reason} ->
            Logger.error(
              "Failed to store interview prep for #{application_id}: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.error(
          "Failed to fetch application #{application_id} for prep storage: #{inspect(reason)}"
        )
    end
  end

  def handle_llm_response(_), do: :ok

  # Private helpers

  defp validate_request_payload(payload) when is_map(payload) do
    case payload["application_id"] do
      nil -> {:error, :missing_application_id}
      _id -> :ok
    end
  end

  defp validate_request_payload(_), do: {:error, "payload must be a map"}

  defp get_default_resume(tenant_id) do
    case resume_store().list(tenant_id) do
      {:ok, resumes} when is_list(resumes) and resumes != [] ->
        {:ok, List.first(resumes)}

      {:ok, _} ->
        {:error, :no_resumes}

      error ->
        error
    end
  end

  defp fire_interview_prep_request(application, resume) do
    application_id = application["id"]
    company = application["company"]
    role_title = application["role_title"]
    jd_tags = application["jd_tags"] || []
    salary_range = application["salary_range"]

    prompt = build_prep_prompt(application, resume, jd_tags, salary_range)

    Logger.info(
      "Firing interview prep LLM request for application #{application_id} (#{company} — #{role_title})"
    )

    Publisher.publish_llm_request_with_metadata(
      %{
        "text" => prompt,
        "prompt_id" => "interview_prep_#{application_id}"
      },
      "interview_prep",
      application_id,
      %{}
    )
  end

  defp build_prep_prompt(application, resume, jd_tags, salary_range) do
    company = application["company"]
    role_title = application["role_title"]

    resume_summary = resume["identity"]["summary"] || ""

    # Top 8 skills
    skills = resume["skills"] || []
    top_skills = Enum.take(skills, 8)
    skills_text = top_skills |> Enum.map(fn s -> s["name"] end) |> Enum.join(", ")

    # Top 10 bullets from most recent roles
    roles = resume["roles"] || []
    bullets = Enum.flat_map(roles, fn role -> role["bullets"] || [] end)
    top_bullets = Enum.take(bullets, 10) |> Enum.map(fn b -> "- #{b}" end) |> Enum.join("\n")

    jd_tags_text = Enum.join(jd_tags, ", ")

    salary_section =
      if salary_range && Map.has_key?(salary_range, "min") do
        min = salary_range["min"]
        max = salary_range["max"]
        "Salary Range: $#{min / 1000}k - $#{max / 1000}k\n"
      else
        ""
      end

    """
    You are a career coach helping prepare for a job interview.

    APPLICATION:
    Company: #{company}
    Role: #{role_title}
    JD Tags: #{jd_tags_text}
    #{salary_section}
    RESUME SUMMARY:
    #{resume_summary}

    TOP SKILLS: #{skills_text}

    RECENT EXPERIENCE BULLETS:
    #{top_bullets}

    Generate comprehensive interview prep in EXACTLY this format (use these exact headers):

    ## Behavioral Questions
    [5 STAR-format questions tailored to this role. For each: **Q: ...** then *Situation/Task:* ... *Action:* ... *Result:* ... — draw answers from the resume bullets above]

    ## Technical Questions
    [8-10 questions based specifically on these JD tags: #{jd_tags_text}. Mix conceptual and hands-on questions.]

    ## Company Research
    [3-4 sentences on likely company culture/values based on the role. Then: **Questions to ask:** 5 smart questions for the interviewer.]

    ## Cheat Sheet
    [**Top 3 bullets to highlight:** ... | **Key talking points:** 3-4 points | **Salary anchoring:** {tip based on salary range, or omit if no range}]
    """
  end

  defp publish_interview_prep_result(application, prep_text, tenant_id, user_id) do
    event = %{
      "event" => "job.application.interview_prep.result",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "job_applications.interview_prep",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "application_id" => application["id"],
        "company" => application["company"],
        "role_title" => application["role_title"],
        "interview_prep_md" => prep_text
      }
    }

    Publisher.publish(event)
  end

  defp publish_gtd_prep_task(application, tenant_id, user_id) do
    company = application["company"]
    role_title = application["role_title"]

    event = %{
      "event" => "gtd.inbox.add",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "job_applications.interview_prep",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "title" => "Interview prep ready: #{company} — #{role_title}",
        "context" => "recruiting",
        "source" => "job_applications_bot",
        "source_metadata" => %{
          "application_id" => application["id"],
          "type" => "interview_prep"
        }
      }
    }

    Publisher.publish(event)
  end

  defp application_store do
    Application.get_env(:bot_army_job_applications, :application_store, ApplicationStore)
  end

  defp resume_store do
    Application.get_env(:bot_army_job_applications, :resume_store, ResumeStore)
  end
end
