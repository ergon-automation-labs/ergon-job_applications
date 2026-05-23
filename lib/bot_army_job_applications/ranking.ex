defmodule BotArmyJobApplications.Ranking do
  @moduledoc """
  Job application ranking and scoring algorithm.

  Ranks applications by composite score considering:
  - Coverage score (resume match to JD): 40%
  - State priority (actionable now): 30%
  - Salary range alignment: 20%
  - Role seniority match: 10%

  ## Usage

      applications = ApplicationStore.list()
      ranked = Ranking.rank(applications)
      # => [
      #   {application, 0.92},
      #   {application, 0.87},
      #   {application, 0.73}
      # ]

      top_5 = Ranking.top_n(applications, 5)
      # => [{app, score}, ...]

      score = Ranking.score(application)
      # => 0.87
  """

  @type application :: map()
  @type score :: float()
  @type ranked :: [{application(), score()}]

  # State priority weights (what stages are most actionable)
  @state_priorities %{
    "ready_to_submit" => 1.0,
    "drafting" => 0.95,
    "identified" => 0.90,
    "submitted" => 0.70,
    "phone_screen" => 0.60,
    "technical" => 0.50,
    "offer" => 0.40,
    "accepted" => 0.30,
    "declined" => 0.0,
    "rejected" => 0.0,
    "ghosted" => 0.0
  }

  # Weights for scoring factors
  @weights %{
    coverage_score: 0.40,
    state_priority: 0.30,
    salary_alignment: 0.20,
    role_match: 0.10
  }

  @doc """
  Calculate a single application's rank score (0-1).
  """
  @spec score(application()) :: score()
  def score(application) when is_map(application) do
    coverage = score_coverage(application)
    state = score_state(application)
    salary = score_salary(application)
    role = score_role(application)

    coverage * @weights.coverage_score +
      state * @weights.state_priority +
      salary * @weights.salary_alignment +
      role * @weights.role_match
  end

  @doc """
  Rank all applications by composite score (highest first).
  """
  @spec rank(list(application())) :: ranked()
  def rank(applications) when is_list(applications) do
    applications
    |> Enum.map(fn app ->
      {app, score(app)}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
  end

  @doc """
  Return top N ranked applications.
  """
  @spec top_n(list(application()), non_neg_integer()) :: ranked()
  def top_n(applications, n) when is_list(applications) and is_integer(n) and n >= 0 do
    applications
    |> rank()
    |> Enum.take(n)
  end

  @doc """
  Group applications by ranking tier.

  Returns `{high, medium, low}` tuple with applications grouped by score.
  Tiers: high >= 0.75, medium >= 0.50, low < 0.50
  """
  @spec by_tier(list(application())) :: {ranked(), ranked(), ranked()}
  def by_tier(applications) when is_list(applications) do
    ranked = rank(applications)

    {
      Enum.filter(ranked, fn {_, s} -> s >= 0.75 end),
      Enum.filter(ranked, fn {_, s} -> s >= 0.50 and s < 0.75 end),
      Enum.filter(ranked, fn {_, s} -> s < 0.50 end)
    }
  end

  # ============================================================================
  # Scoring Functions
  # ============================================================================

  # Coverage score: resume match to JD (0-1)
  defp score_coverage(application) do
    case Map.get(application, "coverage_score") do
      nil -> 0.5
      score when is_float(score) -> score
      score when is_integer(score) -> score / 100
      _ -> 0.5
    end
    |> min(1.0)
    |> max(0.0)
  end

  # State priority: which pipeline stage is most actionable now
  defp score_state(application) do
    state = Map.get(application, "state", "identified")
    Map.get(@state_priorities, state, 0.5)
  end

  # Salary alignment: is compensation acceptable?
  defp score_salary(application) do
    case Map.get(application, "salary_range") do
      nil -> 0.5
      range when is_map(range) -> score_salary_range(range)
      _ -> 0.5
    end
  end

  defp score_salary_range(range) do
    min_salary = Map.get(range, "min")
    max_salary = Map.get(range, "max")
    score_salary_bounds(min_salary, max_salary)
  end

  defp score_salary_bounds(nil, nil), do: 0.5

  defp score_salary_bounds(min, nil) when is_number(min),
    do: if(min >= 100_000, do: 1.0, else: 0.7)

  defp score_salary_bounds(nil, max) when is_number(max),
    do: if(max >= 150_000, do: 1.0, else: 0.6)

  defp score_salary_bounds(min, max) when is_number(min) and is_number(max) do
    cond do
      min >= 150_000 and max >= 200_000 -> 1.0
      min >= 120_000 and max >= 150_000 -> 0.9
      min >= 100_000 and max >= 120_000 -> 0.7
      min >= 80_000 and max >= 100_000 -> 0.5
      true -> 0.3
    end
  end

  defp score_salary_bounds(_, _), do: 0.5

  # Role seniority match: does the role fit experience level?
  defp score_role(application) do
    tags = Map.get(application, "jd_tags", %{})

    case tags do
      %{} when map_size(tags) == 0 ->
        0.5

      map when is_map(map) ->
        score_role_from_tags(map)

      _ ->
        0.5
    end
  end

  defp score_role_from_tags(tags) do
    # Score based on tags like seniority, tech specificity, etc.
    seniority_score = score_seniority(tags)
    specificity_score = score_specificity(tags)

    (seniority_score + specificity_score) / 2
  end

  # Higher seniority = higher score (looking for role matches)
  defp score_seniority(tags) do
    case Map.get(tags, "seniority") do
      "senior" -> 0.9
      "mid" -> 0.8
      "junior" -> 0.6
      "entry" -> 0.5
      "lead" -> 0.95
      "staff" -> 0.95
      _ -> 0.5
    end
  end

  # Specific tech stacks = higher score (more targeted role)
  defp score_specificity(tags) do
    tech_count =
      case Map.get(tags, "technologies", []) do
        list when is_list(list) -> length(list)
        _ -> 0
      end

    frameworks =
      case Map.get(tags, "frameworks", []) do
        list when is_list(list) -> length(list)
        _ -> 0
      end

    total_specificity = tech_count + frameworks

    cond do
      total_specificity >= 8 -> 1.0
      total_specificity >= 5 -> 0.9
      total_specificity >= 3 -> 0.7
      total_specificity >= 1 -> 0.5
      true -> 0.3
    end
  end
end
