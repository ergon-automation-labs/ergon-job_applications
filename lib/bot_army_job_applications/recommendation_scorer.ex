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
      0.0
    else
      intersection = listing_tags |> MapSet.intersection(resume_tags) |> MapSet.size()
      union = listing_tags |> MapSet.union(resume_tags) |> MapSet.size()
      intersection / union
    end

    # Salary alignment bonus (reuse Ranking logic pattern)
    salary_bonus = salary_alignment_bonus(listing["salary_range"], resume)

    # Blend: 80% Jaccard, 20% salary alignment
    (jaccard * 0.8 + salary_bonus * 0.2)
    |> max(0.0)
    |> min(1.0)
  end

  def tag_overlap_score(_, _), do: 0.0

  @doc """
  Pre-filter listings by tag overlap, return top N sorted by score descending.
  """
  def shortlist(listings, resume, limit) when is_list(listings) and is_map(resume) and is_integer(limit) do
    listings
    |> Enum.map(fn listing ->
      score = tag_overlap_score(listing, resume)
      {listing, score}
    end)
    |> Enum.sort_by(fn {_, score} -> score end, :desc)
    |> Enum.take(limit)
  end

  def shortlist(_, _, _), do: []

  @doc """
  Build LLM prompt for semantic scoring.

  Includes:
  - Resume summary (from identity)
  - Top 5 skills with proficiency
  - Listing role/company/jd_tags
  - Request JSON response: {score: 0-100, reason: string}
  """
  def build_llm_prompt(listing, resume) when is_map(listing) and is_map(resume) do
    resume_summary = build_resume_summary(resume)
    skills_summary = build_skills_summary(resume)
    listing_summary = build_listing_summary(listing)

    """
    #{resume_summary}

    TOP SKILLS:
    #{skills_summary}

    OPPORTUNITY:
    #{listing_summary}

    Assess this match on a scale of 0-100. Consider:
    - Relevance of skills to role requirements
    - Experience level alignment
    - Salary expectations vs. role level
    - Growth/learning potential

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

    (technologies ++ frameworks)
    |> Enum.map(&String.downcase/1)
    |> MapSet.new()
  end

  defp extract_resume_tags(resume) do
    # Skill names + all skill tags
    skill_tags = resume["skills"]
      |> Enum.flat_map(fn skill ->
        [String.downcase(skill["name"])] ++ (skill["tags"] || [])
      end)
      |> Enum.map(&String.downcase/1)

    # Bullet tags from all roles
    bullet_tags = resume["roles"]
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

  defp salary_alignment_bonus(salary_range, _resume) when is_map(salary_range) do
    # Check if salary_range is reasonable vs resume expectations
    # Simple heuristic: mid-point salary vs experience level
    # For now, neutral bonus (0.5) unless we have resume salary expectations
    0.5
  end

  defp salary_alignment_bonus(_, _), do: 0.5

  defp build_resume_summary(resume) do
    identity = resume["identity"] || %{}
    name = identity["name"] || "Candidate"
    summary = identity["summary"] || "Professional with experience"

    """
    RESUME SUMMARY:
    #{name}
    #{summary}
    """
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
    jd_tags = listing["jd_tags"] || %{}
    technologies = jd_tags["technologies"] || []
    frameworks = jd_tags["frameworks"] || []

    """
    #{company} — #{role}
    Technologies: #{Enum.join(technologies, ", ")}
    Frameworks: #{Enum.join(frameworks, ", ")}
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
