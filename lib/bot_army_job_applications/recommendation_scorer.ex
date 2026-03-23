defmodule BotArmyJobApplications.RecommendationScorer do
  @moduledoc """
  Hybrid job recommendation scoring.

  Two-phase approach:
  1. Fast tag-overlap pre-filter (Jaccard similarity + salary alignment)
  2. Async LLM semantic scoring (comprehensive role/responsibility matching)

  tag_overlap_score/2 — Fast synchronous scoring (milliseconds)
  shortlist/3 — Sort by score and take limit
  build_llm_prompt/2 — Compose prompt for LLM semantic analysis
  parse_llm_score_response/1 — Extract JSON score + reason from LLM text
  """

  require Logger

  @doc """
  Compute tag-overlap score for a listing against resume.

  Returns score 0.0-1.0 based on:
  - Jaccard similarity of listing tags vs resume tags
  - Salary alignment (bonus/penalty based on range match)
  """
  def tag_overlap_score(listing, resume) when is_map(listing) and is_map(resume) do
    listing_tags = extract_listing_tags(listing)
    resume_tags = extract_resume_tags(resume)

    # Jaccard similarity: |intersection| / |union|
    jaccard = if Enum.empty?(listing_tags) or Enum.empty?(resume_tags) do
      Logger.debug("tag_overlap_score: listing_tags=#{MapSet.size(listing_tags)}, resume_tags=#{MapSet.size(resume_tags)}")
      0.0
    else
      intersection = listing_tags |> MapSet.intersection(resume_tags) |> MapSet.size()
      union = listing_tags |> MapSet.union(resume_tags) |> MapSet.size()
      Logger.debug("tag_overlap_score: intersection=#{intersection}, union=#{union}")
      intersection / union
    end

    # Salary alignment bonus (reuse Ranking logic pattern)
    salary_bonus = salary_alignment_bonus(listing["salary_range"], resume)

    # Location bonus (compare job location against resume preferences)
    location_bonus = location_bonus(listing["location"], resume)

    # Blend: 70% Jaccard, 15% salary, 15% location
    (jaccard * 0.70 + salary_bonus * 0.15 + location_bonus * 0.15)
    |> max(0.0)
    |> min(1.0)
  end

  def tag_overlap_score(_, _), do: 0.0

  @doc """
  Pre-filter listings by tag overlap, return top N sorted by score descending.

  Optimized for large listing sets: uses a heap-like approach to track only
  the top N items instead of sorting all N items.
  """
  def shortlist(listings, resume, limit) when is_list(listings) and is_map(resume) and is_integer(limit) do
    listings
    |> Enum.reduce([], fn listing, top_n ->
      score = tag_overlap_score(listing, resume)
      insert_into_top_n({listing, score}, top_n, limit)
    end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
  end

  def shortlist(_, _, _), do: []

  # Helper: maintain a list of top N items as we iterate through all items
  # Keeps list sorted ascending, easiest to drop minimum from front
  defp insert_into_top_n(item = {_, score}, top_n, limit) do
    cond do
      length(top_n) < limit ->
        # Not at limit yet, insert in sorted position
        top_n ++ [item]
        |> Enum.sort_by(fn {_, s} -> s end, :asc)

      score > elem(Enum.at(top_n, 0), 1) ->
        # Score beats the minimum in top_n, replace minimum
        tl(top_n) ++ [item]
        |> Enum.sort_by(fn {_, s} -> s end, :asc)

      true ->
        # Score is lower than minimum, skip
        top_n
    end
  end

  @doc """
  Build LLM prompt for semantic scoring.

  Includes:
  - Resume summary (identity + work history with key accomplishments)
  - Top 5 skills with proficiency and years
  - Full job description text from listing
  - Request JSON response: {score: 0-100, reason: string}
  """
  def build_llm_prompt(listing, resume) when is_map(listing) and is_map(resume) do
    resume_summary = build_resume_summary(resume)
    experience_summary = build_experience_summary(resume)
    skills_summary = build_skills_summary(resume)
    listing_summary = build_listing_summary(listing)
    location_preferences = build_location_preferences(resume)
    salary_expectations = build_salary_expectations(resume)
    target_preferences = build_target_preferences(resume)

    """
    #{resume_summary}
    #{location_preferences}
    #{salary_expectations}
    #{target_preferences}

    PROFESSIONAL EXPERIENCE:
    #{experience_summary}

    TOP SKILLS:
    #{skills_summary}

    JOB OPPORTUNITY:
    #{listing_summary}

    Assess this match on a scale of 0-100. Consider:
    - Relevance of skills and experience to explicit job requirements
    - Specific accomplishments that align with role responsibilities
    - Seniority/experience level alignment with candidate's target levels
    - Role type fit (engineering, infrastructure, data/ML, security, product, design, management)
    - Required skills match with candidate's target skills
    - Salary range compatibility (candidate's minimum vs job offering)
    - Location fit (based on job location and candidate preferences)
    - Growth/learning opportunity potential

    Respond with JSON:
    {
      "score": <0-100>,
      "reason": "<one sentence explaining the score>"
    }
    """
  end

  def build_llm_prompt(_, _), do: ""

  @doc """
  Parse LLM response text, extract score (0-100) and reason.

  Returns {:ok, score_float, reason_string} or {:error, reason}
  """
  def parse_llm_score_response(text) when is_binary(text) do
    case extract_json_field(text, "score") do
      {:ok, score_value} ->
        # Try to convert to number if it's a string
        score_float = case score_value do
          n when is_number(n) -> n / 100.0
          s when is_binary(s) ->
            case Float.parse(s) do
              {n, _} -> n / 100.0
              :error -> 0.5
            end
          _ -> 0.5
        end

        # Extract reason if available
        reason = case extract_json_field(text, "reason") do
          {:ok, r} when is_binary(r) -> r
          _ -> "LLM assessment"
        end

        {:ok, score_float, reason}

      {:error, _} ->
        Logger.warning("Failed to extract score from LLM response")
        {:error, "invalid_response"}
    end
  end

  def parse_llm_score_response(_), do: {:error, "invalid_input"}

  # Private helpers

  defp extract_listing_tags(listing) do
    jd_tags = listing["jd_tags"] || %{}
    technologies = jd_tags["technologies"] || []
    frameworks = jd_tags["frameworks"] || []

    # If no structured tags, extract keywords from jd_text
    tags = if Enum.empty?(technologies) and Enum.empty?(frameworks) do
      extract_keywords_from_text(listing["jd_text"] || "")
    else
      technologies ++ frameworks
    end

    tags
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  # Extract common technology keywords from job description text
  defp extract_keywords_from_text(text) when is_binary(text) do
    # Common tech keywords to look for (case-insensitive)
    keywords = ~w(
      python javascript ruby java golang rust elixir
      typescript react vue angular nodejs express django rails
      aws gcp azure docker kubernetes terraform ansible saltstack git
      postgresql mysql mongodb redis cassandra elasticsearch
      rest graphql grpc http soap
      linux ubuntu debian centos redhat
      jenkins gitlab travis circleci github
      agile scrum kanban
    )

    text_lower = String.downcase(text)
    keywords
    |> Enum.filter(&String.contains?(text_lower, &1))
  end

  defp extract_resume_tags(resume) do
    # Skill names + all skill tags
    skill_tags = (resume["skills"] || [])
      |> Enum.flat_map(fn skill ->
        [String.downcase(skill["name"])] ++ (skill["tags"] || [])
      end)
      |> Enum.map(&String.downcase/1)

    # Bullet tags from all roles
    bullet_tags = (resume["roles"] || [])
      |> Enum.flat_map(fn role ->
        role["bullets"] || []
      end)
      |> Enum.flat_map(fn bullet ->
        bullet["tags"] || []
      end)
      |> Enum.map(&String.downcase/1)

    (skill_tags ++ bullet_tags)
    |> MapSet.new()
  end

  defp salary_alignment_bonus(salary_range, resume) when is_map(salary_range) do
    # Check if salary_range meets resume floor expectations
    identity = resume["identity"] || %{}
    salary_floor = identity["salary_floor"]

    # If no floor set, neutral (0.5)
    if !salary_floor or !is_integer(salary_floor) or salary_floor <= 0 do
      0.5
    else
      # Get job's salary max (or min if max unavailable)
      job_max = salary_range["max"]
      job_min = salary_range["min"]
      job_salary = cond do
        is_number(job_max) -> job_max
        is_number(job_min) -> job_min
        true -> nil
      end

      # Compare against floor: scale penalty/bonus
      cond do
        is_nil(job_salary) ->
          # No salary data, neutral
          0.5

        job_salary >= salary_floor ->
          # Job meets or exceeds floor: bonus
          # Scale from 0.5 (at floor) to 1.0 (at 1.5x floor)
          bonus = min(0.5 + (job_salary - salary_floor) / (salary_floor * 0.5), 1.0)
          max(bonus, 0.5)

        true ->
          # Job is below floor: penalty
          # Scale from 0.5 (at floor) to 0.0 (at 0.5x floor)
          penalty = (job_salary / salary_floor) * 0.5
          max(penalty, 0.0)
      end
    end
  end

  defp salary_alignment_bonus(_, _), do: 0.5

  defp parse_location_preferences(resume) when is_map(resume) do
    prefs = get_in(resume, ["identity", "location_preferences"]) || ""
    if is_binary(prefs) and prefs != "" do
      prefs
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&String.downcase/1)
    else
      []
    end
  end

  defp parse_location_preferences(_), do: []

  defp location_bonus(location, resume) when is_map(location) and is_map(resume) do
    location_name = String.downcase(location["name"] || "")
    location_kind = String.downcase(location["kind"] || "")
    pref_list = parse_location_preferences(resume)

    # Remote or hybrid jobs always match (no geographic constraint)
    is_remote_job =
      location_kind in ["remote", "hybrid"] or
      Regex.match?(~r/(remote|work from home)/i, location_name)

    if is_remote_job do
      1.0
    else
      if Enum.empty?(pref_list) do
        # No preferences set, neutral
        0.5
      else
        # Check if user wants remote
        user_wants_remote = Enum.any?(pref_list, &(&1 == "remote"))

        # Check if job city is in preferences (partial match)
        job_city_in_prefs =
          location_name != "" and
          Enum.any?(pref_list, fn pref ->
            String.contains?(location_name, pref) or String.contains?(pref, location_name)
          end)

        cond do
          user_wants_remote and job_city_in_prefs -> 0.8
          user_wants_remote                       -> 0.2
          job_city_in_prefs                       -> 1.0
          true                                    -> 0.3
        end
      end
    end
  end

  defp location_bonus(_, _), do: 0.5

  defp build_resume_summary(resume) do
    identity = resume["identity"] || %{}
    name = identity["name"] || "Candidate"
    summary = identity["summary"] || "Professional with experience"

    """
    CANDIDATE PROFILE:
    Name: #{name}
    Summary: #{summary}
    """
  end

  defp build_location_preferences(resume) do
    identity = resume["identity"] || %{}
    location_prefs = identity["location_preferences"]

    if location_prefs && is_binary(location_prefs) && location_prefs != "" do
      "Location Preferences: #{location_prefs}"
    else
      ""
    end
  end

  defp build_salary_expectations(resume) do
    identity = resume["identity"] || %{}
    salary_floor = identity["salary_floor"]

    if salary_floor && is_integer(salary_floor) && salary_floor > 0 do
      "Salary Floor: $#{salary_floor}k/year minimum"
    else
      ""
    end
  end

  defp build_target_preferences(resume) do
    identity = resume["identity"] || %{}
    target_seniority = parse_target_list(identity["target_seniority"])
    target_roles = parse_target_list(identity["target_roles"])
    target_skills = parse_target_list(identity["target_skills"])

    preferences = []

    preferences = if !Enum.empty?(target_seniority) do
      preferences ++ ["Target Seniority: #{Enum.join(target_seniority, ", ")}"]
    else
      preferences
    end

    preferences = if !Enum.empty?(target_roles) do
      preferences ++ ["Target Role Types: #{Enum.join(target_roles, ", ")}"]
    else
      preferences
    end

    preferences = if !Enum.empty?(target_skills) do
      preferences ++ ["Interested in: #{Enum.join(target_skills, ", ")}"]
    else
      preferences
    end

    if Enum.empty?(preferences) do
      ""
    else
      "CANDIDATE PREFERENCES:\n" <> Enum.join(preferences, "\n")
    end
  end

  defp parse_target_list(nil), do: []
  defp parse_target_list(""), do: []
  defp parse_target_list(str) when is_binary(str) do
    str
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
  defp parse_target_list(_), do: []

  defp build_experience_summary(resume) do
    roles = resume["roles"] || []

    if Enum.empty?(roles) do
      "No formal roles listed"
    else
      roles
      |> Enum.map(fn role ->
        title = role["title"] || "Role"
        company = role["company"] || "Company"
        start_date = role["start_date"] || "TBD"
        end_date = role["end_date"] || "Current"

        # Include top 2 bullets as accomplishment highlights
        bullets = role["bullets"] || []
        bullet_text = bullets
          |> Enum.take(2)
          |> Enum.map(fn bullet ->
            text = if is_map(bullet), do: bullet["text"] || "", else: bullet
            "  • #{text}"
          end)
          |> Enum.join("\n")

        role_summary = "#{title} at #{company} (#{start_date} - #{end_date})"

        if bullet_text != "" do
          """
          #{role_summary}
          #{bullet_text}
          """
        else
          role_summary
        end
      end)
      |> Enum.join("\n")
    end
  end

  defp build_skills_summary(resume) do
    resume["skills"]
    |> Enum.sort_by(&(&1["proficiency"] || 0), :desc)
    |> Enum.take(5)
    |> Enum.map(fn skill ->
      name = skill["name"]
      proficiency = skill["proficiency"] || "Intermediate"
      years = skill["years"] || 0
      "- #{name} (#{proficiency}, #{years}y)"
    end)
    |> Enum.join("\n")
  end

  defp build_listing_summary(listing) do
    company = listing["company"]
    role = listing["role_title"]
    jd_text = listing["jd_text"] || ""
    jd_tags = listing["jd_tags"] || %{}
    technologies = jd_tags["technologies"] || []
    frameworks = jd_tags["frameworks"] || []
    salary_range = listing["salary_range"] || %{}
    location = listing["location"] || %{}

    # Truncate JD text to reasonable length if needed (e.g., first 1500 chars)
    jd_preview = if String.length(jd_text) > 1500 do
      String.slice(jd_text, 0, 1500) <> "\n... [full JD available]"
    else
      jd_text
    end

    salary_line = case {salary_range["min"], salary_range["max"]} do
      {min, max} when is_number(min) and is_number(max) ->
        "Salary Range: $#{min}k - $#{max}k"
      {min, _} when is_number(min) ->
        "Starting Salary: $#{min}k+"
      _ ->
        "Salary: Not specified"
    end

    location_line = case location do
      %{"name" => name} when is_binary(name) and name != "" ->
        "Location: #{name}"
      _ ->
        "Location: Not specified"
    end

    """
    ROLE: #{role}
    COMPANY: #{company}
    #{location_line}
    #{salary_line}

    TECHNOLOGIES & FRAMEWORKS:
    #{if Enum.empty?(technologies ++ frameworks), do: "Not specified", else: Enum.join(technologies ++ frameworks, ", ")}

    JOB DESCRIPTION:
    #{if jd_preview == "", do: "No description available", else: jd_preview}
    """
  end

  # Reuse extract_json_field pattern from ArtifactHandler
  defp extract_json_field(text, field) when is_binary(text) and is_binary(field) do
    # Try to find JSON in markdown code block first
    json_regex = ~r/```(?:json)?\s*\n([\s\S]*?)\n```/
    case Regex.run(json_regex, text, capture: :all_but_first) do
      [json_str] ->
        try_parse_json_field(json_str, field)

      nil ->
        # Try to find raw JSON
        try_parse_json_field(text, field)
    end
  end

  defp extract_json_field(_, _), do: {:error, "invalid_input"}

  defp try_parse_json_field(text, field) do
    case Jason.decode(text) do
      {:ok, obj} when is_map(obj) ->
        case Map.get(obj, field) do
          nil -> {:error, "field_not_found"}
          value -> {:ok, value}
        end

      {:error, _} ->
        # Try regex for simple field extraction
        pattern = ~r/"#{field}"\s*:\s*([^,}]+)/
        case Regex.run(pattern, text, capture: :all_but_first) do
          [value] -> {:ok, String.trim(value)}
          nil -> {:error, "parse_error"}
        end
    end
  end
end
