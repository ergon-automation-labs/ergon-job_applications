defmodule BotArmyJobApplications.Handlers.RecommendationHandler do
  @moduledoc """
  Handles job listing recommendation requests.

  Two-phase workflow:
  1. Synchronous tag-overlap pre-filter (reply immediately with top 20 results)
  2. Async LLM semantic scoring (update listings in background, publish GTD inbox items for high scores)

  Subscribes to:
  - job.listings.recommend — Trigger recommendations (TUI or scheduled)
  - events.llm.completion with source_domain="job_recommendation" — LLM scoring results
  """

  require Logger

  alias BotArmyJobApplications.{
    RecommendationScorer,
    ListingStore,
    ResumeStore,
    NATS.Publisher
  }

  @doc """
  Handle recommend request from TUI or scheduler.

  Payload:
  ```json
  {
    "resume_id": "uuid",  // optional, defaults to first resume
    "limit": 20           // optional, defaults to 20
  }
  ```

  Synchronously returns tag-scored results immediately,
  then fires async LLM requests for each result.
  """
  def handle_recommend(message, reply_to, conn) when is_map(message) and is_binary(reply_to) and is_binary(reply_to) do
    %{tenant_id: tenant_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}

    resume_id = Map.get(payload, "resume_id")
    limit = Map.get(payload, "limit", 20)

    case validate_recommend_payload(payload) do
      :ok ->
        case get_default_resume(tenant_id, resume_id) do
          {:ok, resume} ->
            case listing_store().list(tenant_id, []) do
              {:ok, listings} ->
                # Synchronous: tag overlap scoring
                Logger.info("handle_recommend: Resume has #{length(resume["skills"] || [])} skills and #{length(resume["roles"] || [])} roles")
                Logger.debug("Resume skills: #{inspect(resume["skills"])}")
                Logger.debug("Sample listing: #{inspect(List.first(listings))}")

                scored_pairs = RecommendationScorer.shortlist(listings, resume, limit)
                recommendations = Enum.map(scored_pairs, fn {listing, score} ->
                  role_title = listing["role_title"]
                  jd_text = listing["jd_text"]
                  required_skills = extract_required_skills(jd_text)

                  # Merge extracted fields into listing
                  enriched_listing = Map.merge(listing, %{
                    "seniority_level" => extract_seniority(role_title),
                    "role_type" => extract_role_type(role_title),
                    "salary_range" => listing["salary_range"] || extract_salary(jd_text),
                    "location" => listing["location"] || extract_location(jd_text),
                    "required_skills" => required_skills
                  })

                  # Check if matches target profile and apply score boost
                  target_match = matches_target_profile?(enriched_listing, resume)
                  boosted_score = if target_match, do: score * 1.25, else: score

                  %{
                    "listing" => enriched_listing,
                    "score" => (boosted_score * 100) |> Float.round(0) |> trunc(),
                    "reason" => "Tag match",
                    "target_match" => target_match
                  }
                end)

                # Reply immediately with tag-scored results
                reply_body = Jason.encode!(%{
                  "ok" => true,
                  "recommendations" => recommendations,
                  "total_scored" => length(recommendations)
                })

                if conn do
                  Gnat.pub(conn, reply_to, reply_body)
                end

                Logger.info("Sent recommendations: #{length(recommendations)} scored (tag overlap), LLM enrichment in background")

                # Asynchronously: fire LLM requests for each shortlist item
                fire_async_llm_requests(scored_pairs, resume)

              {:error, reason} ->
                Logger.error("Failed to fetch listings: #{inspect(reason)}")
                reply_error(conn, reply_to, "Failed to fetch listings")
            end

          {:error, reason} ->
            Logger.error("Failed to fetch resume: #{inspect(reason)}")
            reply_error(conn, reply_to, "Resume not found")
        end

      {:error, reason} ->
        Logger.warning("Invalid recommend request: #{inspect(reason)}")
        reply_error(conn, reply_to, "Invalid request")
    end
  end

  def handle_recommend(_, _, _), do: :ok

  @doc """
  Handle LLM scoring response.

  Extracts listing_id and resume_id from source_metadata,
  parses score + reason, updates listing, pushes to GTD if >= 0.80.
  """
  def handle_llm_score_response(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    source_metadata = message["source_metadata"] || %{}
    listing_id = source_metadata["listing_id"]
    resume_id = source_metadata["resume_id"]
    payload = message["payload"] || %{}

    case RecommendationScorer.parse_llm_score_response(payload["completion"] || "") do
      {:ok, score, reason} ->
        Logger.info("LLM scored listing #{listing_id} (resume: #{resume_id}): #{(score * 100) |> trunc()}%")

        # Update listing with score + reason
        case listing_store().update(tenant_id, listing_id, %{
          "recommendation_score" => score,
          "recommendation_reason" => reason,
          "scored_at" => NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()
        }) do
          {:ok, listing} ->
            Logger.info("Updated listing #{listing_id} with recommendation score: #{(score * 100) |> trunc()}%")

            # If score >= 0.80 and not yet pushed to GTD, push it (if GTD integration enabled)
            if Application.get_env(:bot_army_job_applications, :enable_gtd_integration, true) do
              if score >= 0.80 and not (listing["gtd_pushed"] || false) do
                publish_gtd_inbox_item(listing, score, reason, resume_id, tenant_id, user_id)
                # Mark as pushed
                listing_store().update(tenant_id, listing_id, %{"gtd_pushed" => true})
              end
            end

            # Publish event
            publish_recommendation_scored(listing, score, reason, tenant_id, user_id)

          {:error, reason} ->
            Logger.error("Failed to update listing #{listing_id}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to parse LLM score response: #{inspect(reason)}")
    end
  end

  def handle_llm_score_response(_), do: :ok

  @doc """
  Auto-score a newly ingested listing.

  Fired from IngestHandler after successful listing creation.
  Gets default resume and fires async LLM scoring request.
  """
  def score_listing_async(listing, tenant_id) when is_map(listing) do
    case get_default_resume(tenant_id, nil) do
      {:ok, resume} ->
        listing_id = listing["id"]
        resume_id = resume["id"]

        prompt = RecommendationScorer.build_llm_prompt(listing, resume)

        Logger.info("Firing async LLM recommendation request for listing #{listing_id}")

        Publisher.publish_llm_request_with_metadata(
          %{
            "text" => prompt,
            "prompt_id" => "job_recommendation_#{listing_id}"
          },
          "job_recommendation",
          nil,
          %{
            "listing_id" => listing_id,
            "resume_id" => resume_id
          }
        )

      {:error, reason} ->
        Logger.warning("Could not auto-score listing: #{inspect(reason)}")
    end
  end

  def score_listing_async(_), do: :ok

  @doc """
  Re-score all listings using the most recently updated resume.

  Called after resume.update to apply new location preferences or salary floor.
  Uses Task.start to run asynchronously without blocking the caller.
  """
  def rescore_all do
    Task.start(fn ->
      Logger.info("rescore_all: triggered by resume update")

      case resume_store().list() do
        {:ok, [resume | _]} ->
          case listing_store().list([]) do
            {:ok, listings} ->
              Logger.info("rescore_all: re-scoring #{length(listings)} listings with updated resume")
              scored_pairs = RecommendationScorer.shortlist(listings, resume, 20)
              fire_async_llm_requests(scored_pairs, resume)

            {:error, reason} ->
              Logger.error("rescore_all: failed to fetch listings: #{inspect(reason)}")
          end

        {:ok, []} ->
          Logger.warning("rescore_all: no resumes found, skipping")

        {:error, reason} ->
          Logger.error("rescore_all: failed to fetch resume: #{inspect(reason)}")
      end
    end)

    :ok
  end

  # Seniority and role type extraction for recommendations

  @seniority_patterns [
    {~r/\b(intern|internship)\b/i, "Intern"},
    {~r/\b(junior|jr\.?|entry.?level|associate)\b/i, "Junior"},
    {~r/\b(staff)\b/i, "Staff"},
    {~r/\b(principal)\b/i, "Principal"},
    {~r/\b(senior|sr\.?|lead)\b/i, "Senior"},
    {~r/\b(director)\b/i, "Director"},
    {~r/\b(manager|mgr)\b/i, "Manager"}
  ]

  defp extract_seniority(nil), do: nil
  defp extract_seniority(role_title) when is_binary(role_title) do
    case Enum.find(@seniority_patterns, fn {pattern, _} -> Regex.match?(pattern, role_title) end) do
      {_, level} -> level
      nil -> nil
    end
  end
  defp extract_seniority(_), do: nil

  @role_type_patterns [
    {~r/\b(devops|sre|platform|infrastructure|infra|reliability)\b/i, "Infrastructure"},
    {~r/\b(data scientist|data engineer|ml|machine learning|ai|analytics)\b/i, "Data/ML"},
    {~r/\b(security|appsec|devsecops)\b/i, "Security"},
    {~r/\b(product manager|product owner|pm\b)\b/i, "Product"},
    {~r/\b(designer|ux|ui|frontend)\b/i, "Design"},
    {~r/\b(engineer|developer|programmer|sde|swe|software)\b/i, "Engineering"},
    {~r/\b(manager|director|vp|head of)\b/i, "Management"}
  ]

  defp extract_role_type(nil), do: nil
  defp extract_role_type(role_title) when is_binary(role_title) do
    case Enum.find(@role_type_patterns, fn {pattern, _} -> Regex.match?(pattern, role_title) end) do
      {_, type} -> type
      nil -> nil
    end
  end
  defp extract_role_type(_), do: nil

  # Salary and location extraction from JD text

  @salary_patterns [
    ~r/\$?([\d,]+)\s*(?:k|K)\s*-\s*\$?([\d,]+)\s*(?:k|K)/,  # $100k-$150k or 100k-150k
    ~r/\$?([\d,]+)\s*(?:k|K)\s*(?:per|p\/|\/)/,             # $100k per year
    ~r/\$?([\d,]+)(?:,\d{3})\s*-\s*\$?([\d,]+)(?:,\d{3})/  # $100,000 - $150,000
  ]

  defp extract_salary(jd_text) when is_binary(jd_text) and jd_text != "" do
    case Enum.find_value(@salary_patterns, fn pattern ->
      case Regex.scan(pattern, jd_text) do
        [[match | _]] -> match
        [[_, min, max | _]] -> "#{min}k-#{max}k"
        _ -> nil
      end
    end) do
      nil -> nil
      salary -> %{"range" => salary}
    end
  end

  defp extract_salary(_), do: nil

  defp extract_location(jd_text) when is_binary(jd_text) and jd_text != "" do
    cond do
      Regex.match?(~r/remote/i, jd_text) ->
        %{"type" => "remote"}

      Regex.match?(~r/hybrid/i, jd_text) ->
        %{"type" => "hybrid"}

      true ->
        case Regex.scan(~r/\b([A-Z][a-z]+),\s*([A-Z]{2})\b/, jd_text) do
          [[city, state] | _] -> %{"city" => city, "state" => state}
          _ -> nil
        end
    end
  end

  defp extract_location(_), do: nil

  # Required skills extraction from JD text
  # Looks for common infrastructure/platform/mlops keywords

  @required_skills [
    {"terraform", "Terraform"},
    {"kubernetes", "Kubernetes"},
    {"docker", "Docker"},
    {"aws", "AWS"},
    {"gcp", "Google Cloud"},
    {"azure", "Azure"},
    {"golang", "Go"},
    {"rust", "Rust"},
    {"python", "Python"},
    {"distributed systems", "Distributed Systems"},
    {"microservices", "Microservices"},
    {"devops", "DevOps"},
    {"ci/cd", "CI/CD"},
    {"helm", "Helm"},
    {"prometheus", "Prometheus"},
    {"grafana", "Grafana"},
    {"linux", "Linux"},
    {"bash", "Bash"},
    {"sql", "SQL"},
    {"postgresql", "PostgreSQL"},
  ]

  defp extract_required_skills(jd_text) when is_binary(jd_text) and jd_text != "" do
    lower_text = String.downcase(jd_text)

    found_skills =
      @required_skills
      |> Enum.filter(fn {keyword, _label} -> String.contains?(lower_text, keyword) end)
      |> Enum.map(fn {_keyword, label} -> label end)

    case found_skills do
      [] -> nil
      skills -> skills
    end
  end

  defp extract_required_skills(_), do: nil

  # Target profile matching: checks if listing matches resume's target preferences
  defp matches_target_profile?(listing, resume) do
    identity = resume["identity"] || %{}
    target_seniority = parse_preference_string(identity["target_seniority"])
    target_roles = parse_preference_string(identity["target_roles"])
    target_skills = parse_preference_string(identity["target_skills"])
    location_prefs = parse_preference_string(identity["location_preferences"])

    # If no target preferences set, listing does not match (return false, not a special match)
    if Enum.empty?(target_seniority) and Enum.empty?(target_roles) and
         Enum.empty?(target_skills) and Enum.empty?(location_prefs) do
      false
    else
      role_title = listing["role_title"] || ""
      listing_seniority = listing["seniority_level"]
      listing_skills = listing["required_skills"] || []
      listing_location = listing["location"] || %{}

      seniority_match = Enum.empty?(target_seniority) or (listing_seniority in target_seniority)

      role_match =
        Enum.empty?(target_roles) or
          Enum.any?(target_roles, fn target_role ->
            String.contains?(String.downcase(role_title), String.downcase(target_role))
          end)

      skill_match =
        Enum.empty?(target_skills) or
          Enum.any?(target_skills, fn target_skill ->
            Enum.any?(listing_skills, fn skill ->
              String.contains?(String.downcase(skill), String.downcase(target_skill))
            end)
          end)

      location_match = Enum.empty?(location_prefs) or matches_location?(listing_location, location_prefs)

      seniority_match and role_match and skill_match and location_match
    end
  end

  # Parse newline-separated preference string into trimmed list
  defp parse_preference_string(nil), do: []
  defp parse_preference_string(""), do: []

  defp parse_preference_string(str) when is_binary(str) do
    str
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_preference_string(_), do: []

  # Check if listing location matches any location preference
  defp matches_location?(listing_location, location_prefs) when is_map(listing_location) do
    location_type = Map.get(listing_location, "type", "")
    location_city = Map.get(listing_location, "city", "") |> String.downcase()
    location_state = Map.get(listing_location, "state", "") |> String.downcase()

    Enum.any?(location_prefs, fn pref ->
      pref_lower = String.downcase(pref)

      cond do
        pref_lower == "remote" -> location_type == "remote"
        pref_lower == "hybrid" -> location_type == "hybrid"
        String.contains?(pref_lower, ",") ->
          # Handle "City, ST" format
          [pref_city, pref_state] = pref_lower |> String.split(",") |> Enum.map(&String.trim/1)
          location_city == String.downcase(pref_city) and location_state == String.downcase(pref_state)

        true ->
          # Partial match on city name
          String.contains?(location_city, pref_lower) or String.contains?(location_state, pref_lower)
      end
    end)
  end

  defp matches_location?(_, _), do: false

  # Private helpers

  defp validate_recommend_payload(payload) when is_map(payload) do
    # All fields optional
    :ok
  end

  defp validate_recommend_payload(_), do: {:error, "payload must be a map"}

  defp get_default_resume(tenant_id, resume_id) when is_binary(resume_id) do
    resume_store().get(tenant_id, resume_id)
  end

  defp get_default_resume(tenant_id, _) do
    case resume_store().list(tenant_id) do
      {:ok, resumes} when is_list(resumes) and length(resumes) > 0 ->
        # Return first resume (already a map from store)
        {:ok, List.first(resumes)}

      {:ok, _} ->
        {:error, :no_resumes}

      error ->
        error
    end
  end

  defp fire_async_llm_requests(scored_pairs, resume) do
    Logger.info("fire_async_llm_requests: starting, #{length(scored_pairs)} listings to score")

    Enum.each(scored_pairs, fn {listing, _score} ->
      listing_id = listing["id"]
      resume_id = resume["id"]

      try do
        prompt = RecommendationScorer.build_llm_prompt(listing, resume)

        Logger.info("Publishing LLM request for listing #{listing_id} with resume #{resume_id}")

        result = Publisher.publish_llm_request_with_metadata(
          %{
            "text" => prompt,
            "prompt_id" => "job_recommendation_#{listing_id}"
          },
          "job_recommendation",
          nil,
          %{
            "listing_id" => listing_id,
            "resume_id" => resume_id
          }
        )

        Logger.info("Published LLM request result: #{inspect(result)}")
      rescue
        e ->
          Logger.error("Error publishing LLM request for listing #{listing_id}: #{inspect(e)}")
      end
    end)

    Logger.info("fire_async_llm_requests: completed")
  end

  defp reply_error(conn, reply_to, message) do
    response = Jason.encode!(%{"ok" => false, "error" => message})
    if conn, do: Gnat.pub(conn, reply_to, response)
  end

  defp publish_gtd_inbox_item(listing, score, reason, resume_id, tenant_id, user_id) do
    company = listing["company"]
    role = listing["role_title"]
    score_percent = (score * 100) |> Float.round(0) |> trunc()

    message = "Job match: #{company} — #{role} (#{score_percent}% match). #{reason}"

    event = %{
      "event" => "gtd.inbox.add",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "job_applications.recommendation",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "item" => message,
        "source_domain" => "job_recommendation",
        "source_metadata" => %{
          "listing_id" => listing["id"],
          "resume_id" => resume_id,
          "company" => company,
          "role" => role,
          "score" => score
        }
      }
    }

    Publisher.publish(event)
  end

  defp publish_recommendation_scored(listing, score, reason, tenant_id, user_id) do
    event = %{
      "event" => "job.listing.recommendation_scored",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "job_applications.recommendation",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => %{
        "listing_id" => listing["id"],
        "score" => score,
        "reason" => reason
      }
    }

    Publisher.publish(event)
  end

  defp listing_store do
    Application.get_env(:bot_army_job_applications, :listing_store, ListingStore)
  end

  defp resume_store do
    Application.get_env(:bot_army_job_applications, :resume_store, ResumeStore)
  end
end
