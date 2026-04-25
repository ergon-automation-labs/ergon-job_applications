defmodule BotArmyJobApplications.RecommendationScorerTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyJobApplications.RecommendationScorer

  describe "build_llm_prompt/2" do
    test "includes full job description text (not just tags)" do
      listing = %{
        "company" => "Acme Corp",
        "role_title" => "Senior Elixir Engineer",
        "jd_text" =>
          "We are looking for a backend engineer with 5+ years of experience in building distributed systems...",
        "jd_tags" => %{
          "technologies" => ["Elixir", "PostgreSQL"],
          "frameworks" => ["Phoenix"]
        },
        "salary_range" => %{"min" => 150, "max" => 200}
      }

      resume = %{
        "id" => "resume-1",
        "identity" => %{
          "name" => "Alice",
          "summary" => "Experienced distributed systems engineer"
        },
        "skills" => [
          %{"name" => "Elixir", "proficiency" => "expert", "years" => 5},
          %{"name" => "PostgreSQL", "proficiency" => "advanced", "years" => 6}
        ],
        "roles" => [
          %{
            "title" => "Backend Engineer",
            "company" => "TechCorp",
            "start_date" => "2020-01",
            "end_date" => "2024-12",
            "bullets" => [
              %{"text" => "Designed microservices architecture serving 1M+ requests/day"},
              %{"text" => "Optimized database queries reducing latency by 40%"}
            ]
          }
        ]
      }

      prompt = RecommendationScorer.build_llm_prompt(listing, resume)

      # Verify essential content is in prompt
      assert String.contains?(prompt, "Alice")
      assert String.contains?(prompt, "Experienced distributed systems engineer")
      assert String.contains?(prompt, "Backend Engineer")
      assert String.contains?(prompt, "TechCorp")
      assert String.contains?(prompt, "Designed microservices")
      assert String.contains?(prompt, "We are looking for a backend engineer")
      assert String.contains?(prompt, "Senior Elixir Engineer")
      assert String.contains?(prompt, "Acme Corp")
      assert String.contains?(prompt, "$150k - $200k")
      assert String.contains?(prompt, "Elixir")
      assert String.contains?(prompt, "Phoenix")
    end

    test "includes work history with top 2 bullets per role" do
      listing = %{
        "company" => "TechCorp",
        "role_title" => "Engineer",
        "jd_text" => "Role description",
        "jd_tags" => %{},
        "salary_range" => %{}
      }

      resume = %{
        "identity" => %{"name" => "Bob", "summary" => "Engineer"},
        "skills" => [],
        "roles" => [
          %{
            "title" => "Staff Engineer",
            "company" => "Company A",
            "start_date" => "2022-01",
            "end_date" => "Current",
            "bullets" => [
              "Achievement 1",
              "Achievement 2",
              "Achievement 3",
              "Achievement 4"
            ]
          }
        ]
      }

      prompt = RecommendationScorer.build_llm_prompt(listing, resume)

      # Should include role and company
      assert String.contains?(prompt, "Staff Engineer")
      assert String.contains?(prompt, "Company A")
      # Should include first 2 bullets
      assert String.contains?(prompt, "Achievement 1")
      assert String.contains?(prompt, "Achievement 2")
      # Should NOT include last 2 bullets (only top 2)
      refute String.contains?(prompt, "Achievement 3")
    end

    test "handles missing jd_text gracefully" do
      listing = %{
        "company" => "Corp",
        "role_title" => "Engineer",
        "jd_tags" => %{"technologies" => ["Python"]},
        "salary_range" => %{}
      }

      resume = %{
        "identity" => %{"name" => "Charlie", "summary" => "Engineer"},
        "skills" => [],
        "roles" => []
      }

      prompt = RecommendationScorer.build_llm_prompt(listing, resume)

      assert String.contains?(prompt, "No description available")
    end

    test "handles salary_range with min and max" do
      listing = %{
        "company" => "Corp",
        "role_title" => "Engineer",
        "jd_text" => "JD",
        "jd_tags" => %{},
        "salary_range" => %{"min" => 100, "max" => 150}
      }

      resume = %{
        "identity" => %{"name" => "Dave", "summary" => "Engineer"},
        "skills" => [],
        "roles" => []
      }

      prompt = RecommendationScorer.build_llm_prompt(listing, resume)
      assert String.contains?(prompt, "$100k - $150k")
    end

    test "truncates long jd_text to 1500 chars" do
      long_jd = String.duplicate("word ", 1000)

      listing = %{
        "company" => "Corp",
        "role_title" => "Engineer",
        "jd_text" => long_jd,
        "jd_tags" => %{},
        "salary_range" => %{}
      }

      resume = %{
        "identity" => %{"name" => "Eve", "summary" => "Engineer"},
        "skills" => [],
        "roles" => []
      }

      prompt = RecommendationScorer.build_llm_prompt(listing, resume)
      assert String.contains?(prompt, "[full JD available]")
      # Verify it's truncated
      assert byte_size(prompt) < byte_size(long_jd)
    end
  end

  describe "tag_overlap_score/2" do
    test "returns 0.0 for nil inputs" do
      assert RecommendationScorer.tag_overlap_score(nil, %{}) == 0.0
      assert RecommendationScorer.tag_overlap_score(%{}, nil) == 0.0
    end

    test "returns > 0.0 when no tags overlap (due to salary and location bonus fallback)" do
      listing = %{"jd_tags" => %{"technologies" => ["Rust", "Go"]}}
      resume = %{"skills" => [%{"name" => "Elixir"}], "roles" => []}

      score = RecommendationScorer.tag_overlap_score(listing, resume)

      # Score is 0.0*0.50 (jaccard) + 0.5*0.15 (seniority) + 0.5*0.15 (role) + 0.5*0.10 (salary) + 0.5*0.10 (location) = 0.25
      assert score == 0.25
    end

    test "returns > 0.0 when tags overlap" do
      listing = %{"jd_tags" => %{"technologies" => ["Elixir", "PostgreSQL"]}}
      resume = %{"skills" => [%{"name" => "Elixir"}], "roles" => []}

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      assert score > 0.0
      assert score <= 1.0
    end
  end

  describe "location_bonus via tag_overlap_score/2" do
    test "remote jobs score 1.0 location bonus regardless of preferences" do
      resume = %{
        "identity" => %{"name" => "Candidate"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"kind" => "remote"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      # 0.0*0.50 + 0.5*0.15 + 0.5*0.15 + 0.5*0.10 + 1.0*0.10 = 0.30
      assert_in_delta score, 0.30, 0.001
    end

    test "hybrid jobs score 1.0 location bonus" do
      resume = %{
        "identity" => %{"name" => "Candidate"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"kind" => "hybrid"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      assert_in_delta score, 0.30, 0.001
    end

    test "job city matching user preference scores 1.0 location bonus" do
      resume = %{
        "identity" => %{"name" => "Candidate", "location_preferences" => "Austin, TX\nNew York"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"name" => "Austin, TX", "kind" => "onsite"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      # 0.0*0.50 + 0.5*0.15 + 0.5*0.15 + 0.5*0.10 + 1.0*0.10 = 0.30
      assert_in_delta score, 0.30, 0.001
    end

    test "job city NOT in preferences scores 0.3 location bonus" do
      resume = %{
        "identity" => %{"name" => "Candidate", "location_preferences" => "Austin, TX\nNew York"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"name" => "Denver, CO", "kind" => "onsite"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      # 0.0*0.50 + 0.5*0.15 + 0.5*0.15 + 0.5*0.10 + 0.3*0.10 = 0.23
      assert_in_delta score, 0.23, 0.001
    end

    test "remote preference + city in preferences scores 0.8" do
      resume = %{
        "identity" => %{"name" => "Candidate", "location_preferences" => "Remote\nAustin, TX"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"name" => "Austin, TX", "kind" => "onsite"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      # 0.0*0.50 + 0.5*0.15 + 0.5*0.15 + 0.5*0.10 + 0.8*0.10 = 0.28
      assert_in_delta score, 0.28, 0.001
    end

    test "remote preference + city NOT in preferences scores 0.2" do
      resume = %{
        "identity" => %{"name" => "Candidate", "location_preferences" => "Remote\nAustin, TX"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"name" => "Denver, CO", "kind" => "onsite"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      # 0.0*0.50 + 0.5*0.15 + 0.5*0.15 + 0.5*0.10 + 0.2*0.10 = 0.22
      assert_in_delta score, 0.22, 0.001
    end

    test "no location preferences set scores 0.5 location bonus" do
      resume = %{
        "identity" => %{"name" => "Candidate"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"name" => "Any City", "kind" => "onsite"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      # 0.0*0.50 + 0.5*0.15 + 0.5*0.15 + 0.5*0.10 + 0.5*0.10 = 0.25
      assert score == 0.25
    end

    test "location matching is case insensitive" do
      resume = %{
        "identity" => %{"name" => "Candidate", "location_preferences" => "AUSTIN, TX\nNEW YORK"},
        "skills" => [],
        "roles" => []
      }

      listing = %{
        "jd_tags" => %{},
        "jd_text" => "",
        "salary_range" => %{},
        "location" => %{"name" => "austin, tx"}
      }

      score = RecommendationScorer.tag_overlap_score(listing, resume)
      assert_in_delta score, 0.30, 0.001
    end
  end

  describe "parse_llm_score_response/1" do
    test "extracts score from JSON in markdown code block" do
      response = """
      ```json
      {
        "score": 85,
        "reason": "Good match"
      }
      ```
      """

      assert {:ok, score, reason} = RecommendationScorer.parse_llm_score_response(response)
      assert score == 0.85
      assert reason == "Good match"
    end

    test "extracts score from raw JSON" do
      response = ~s({"score": 75, "reason": "Moderate match"})

      assert {:ok, score, reason} = RecommendationScorer.parse_llm_score_response(response)
      assert score == 0.75
      assert reason == "Moderate match"
    end

    test "handles score as string" do
      response = ~s({"score": "92", "reason": "Strong match"})

      assert {:ok, score, reason} = RecommendationScorer.parse_llm_score_response(response)
      assert score == 0.92
      assert reason == "Strong match"
    end

    test "returns error for invalid input" do
      assert {:error, _} = RecommendationScorer.parse_llm_score_response("invalid json")
    end
  end
end
