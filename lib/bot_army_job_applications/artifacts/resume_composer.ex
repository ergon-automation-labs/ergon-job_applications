defmodule BotArmyJobApplications.ResumeComposer do
  @moduledoc """
  Pure Elixir resume composition engine.

  Analyzes a resume against job description tags and produces:
  - Scored and filtered resume bullets
  - Selected summary variant
  - Filtered skills
  - Coverage score (matched_tags / total_jd_tags)

  No LLM calls, fully deterministic and testable.
  """

  @doc """
  Compose a resume for a given job description.

  Takes a resume (with roles, bullets, and skills) and JD tags.
  Returns composed resume with scoring and filtering applied.

  ## Returns
  ```elixir
  %{
    roles: [%{title, company, bullets: [scored_bullets]}],
    summary: selected_summary_variant,
    skills: filtered_skills,
    coverage_score: float (0.0-1.0)
  }
  ```
  """
  def compose(resume, jd_tags) when is_map(resume) and is_list(jd_tags) do
    # 1. Find dominant tag in JD
    dominant_tag = find_dominant_tag(jd_tags)

    # 2. Score and filter bullets, selecting alt phrasings
    roles = compose_roles(resume["roles"] || [], jd_tags, dominant_tag)

    # 3. Select summary variant
    summary = select_summary_variant(resume, dominant_tag)

    # 4. Filter and score skills
    skills = filter_and_score_skills(resume["skills"] || [], jd_tags)

    # 5. Calculate coverage score
    matched_tags = count_matched_tags(roles, skills, jd_tags)
    coverage_score = if Enum.empty?(jd_tags), do: 0.0, else: matched_tags / length(jd_tags)

    %{
      "roles" => roles,
      "summary" => summary,
      "skills" => skills,
      "coverage_score" => coverage_score,
      "matched_tags_count" => matched_tags,
      "total_tags_count" => length(jd_tags)
    }
  end

  @doc """
  Calculate tag overlap score between two tag lists.

  Uses dot product / Jaccard similarity.
  """
  def calculate_tag_overlap(tags1, tags2) when is_list(tags1) and is_list(tags2) do
    intersection = MapSet.intersection(MapSet.new(tags1), MapSet.new(tags2))
    MapSet.size(intersection)
  end

  # Private helpers

  defp find_dominant_tag(jd_tags) do
    if Enum.empty?(jd_tags), do: nil, else: List.first(jd_tags)
  end

  defp compose_roles(roles, jd_tags, _dominant_tag) do
    Enum.map(roles, fn role ->
      bullets = role["bullets"] || []

      composed_bullets =
        Enum.map(bullets, fn bullet ->
          score = calculate_tag_overlap(bullet["tags"] || [], jd_tags)
          selected_phrasing = select_best_phrasing(bullet, jd_tags)

          %{
            "original_text" => bullet["text"],
            "selected_text" => selected_phrasing,
            "tag_score" => score,
            "tags" => bullet["tags"] || [],
            "strength" => bullet["strength"] || "medium"
          }
        end)
        |> Enum.sort_by(&Map.get(&1, "tag_score"), :desc)

      Map.put(role, "bullets", composed_bullets)
    end)
  end

  defp select_best_phrasing(bullet, jd_tags) do
    alt_phrasings = bullet["alt_phrasings"] || []

    if Enum.empty?(alt_phrasings) do
      bullet["text"]
    else
      alt_phrasings
      |> Enum.map(fn phrasing ->
        # Count word overlap with JD text/tags
        overlap_score = count_word_overlap(phrasing, jd_tags)
        {phrasing, overlap_score}
      end)
      |> Enum.max_by(fn {_, score} -> score end)
      |> elem(0)
    end
  end

  defp count_word_overlap(phrasing, jd_tags) when is_binary(phrasing) do
    phrasing_words = phrasing |> String.downcase() |> String.split()
    tag_words = jd_tags |> Enum.flat_map(&String.split/1)

    phrasing_words
    |> Enum.count(fn word -> Enum.any?(tag_words, &String.contains?(&1, word)) end)
  end

  defp select_summary_variant(resume, dominant_tag) do
    identity = resume["identity"] || %{}
    summary_variants = identity["summary_variants"] || %{}

    if dominant_tag && Map.has_key?(summary_variants, dominant_tag) do
      summary_variants[dominant_tag]
    else
      identity["summary"] || ""
    end
  end

  defp filter_and_score_skills(skills, jd_tags) do
    for skill <- skills,
        skill_tags = skill["tags"] || [],
        tag_overlap = calculate_tag_overlap(skill_tags, jd_tags),
        tag_overlap > 0 do
      Map.merge(skill, %{
        "relevance_score" => tag_overlap,
        "proficiency" => skill["proficiency"] || "proficient"
      })
    end
    |> Enum.sort_by(& &1["relevance_score"], :desc)
  end

  defp count_matched_tags(roles, skills, jd_tags) do
    role_tags =
      roles
      |> Enum.flat_map(fn role -> role["bullets"] || [] end)
      |> Enum.flat_map(fn bullet -> bullet["tags"] || [] end)

    skill_tags =
      skills
      |> Enum.flat_map(fn skill -> skill["tags"] || [] end)

    all_matched_tags = (role_tags ++ skill_tags) |> Enum.uniq()

    all_matched_tags
    |> Enum.count(fn tag -> Enum.any?(jd_tags, &(&1 == tag)) end)
  end
end
