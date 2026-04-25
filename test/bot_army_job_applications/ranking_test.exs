defmodule BotArmyJobApplications.RankingTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyJobApplications.Ranking

  describe "score/1" do
    test "perfect application scores close to 1.0" do
      app = %{
        "coverage_score" => 0.95,
        "state" => "ready_to_submit",
        "salary_range" => %{"min" => 150_000, "max" => 200_000},
        "jd_tags" => %{
          "seniority" => "senior",
          "technologies" => ["Elixir", "Go", "Rust", "Python"],
          "frameworks" => ["Phoenix", "GenServer"]
        }
      }

      score = Ranking.score(app)
      assert score >= 0.85
      assert score <= 1.0
    end

    test "poor application scores low" do
      app = %{
        "coverage_score" => 0.2,
        "state" => "rejected",
        "salary_range" => %{"min" => 50_000, "max" => 60_000},
        "jd_tags" => %{}
      }

      score = Ranking.score(app)
      assert score < 0.4
    end

    test "handles missing coverage_score (defaults to 0.5)" do
      app = %{
        "state" => "identified",
        "salary_range" => %{"min" => 100_000, "max" => 120_000},
        "jd_tags" => %{}
      }

      score = Ranking.score(app)
      assert is_float(score)
      assert score > 0.0 and score <= 1.0
    end

    test "handles nil values gracefully" do
      app = %{}
      score = Ranking.score(app)
      assert is_float(score)
      assert score > 0.0 and score <= 1.0
    end

    test "clamps coverage_score to 0-1 range" do
      app_high = %{
        "coverage_score" => 1.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => nil
      }

      app_low = %{
        "coverage_score" => -0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => nil
      }

      score_high = Ranking.score(app_high)
      score_low = Ranking.score(app_low)

      # Both should have coverage clamped
      # Should treat as 1.0 coverage
      assert score_high > 0.5
      # With coverage clamped to 0: 0.0*0.4 + 0.9*0.3 + 0.5*0.2 + 0.5*0.1 = 0.42
      assert score_low > 0.4 and score_low < 0.5
    end

    test "state priority affects score significantly" do
      base_app = %{
        "coverage_score" => 0.8,
        "salary_range" => %{"min" => 120_000, "max" => 150_000},
        "jd_tags" => %{"seniority" => "mid"}
      }

      app_ready = Map.put(base_app, "state", "ready_to_submit")
      app_submitted = Map.put(base_app, "state", "submitted")
      app_rejected = Map.put(base_app, "state", "rejected")

      score_ready = Ranking.score(app_ready)
      score_submitted = Ranking.score(app_submitted)
      score_rejected = Ranking.score(app_rejected)

      assert score_ready > score_submitted
      assert score_submitted > score_rejected
    end
  end

  describe "rank/1" do
    test "sorts applications by score descending" do
      apps = [
        %{
          "id" => "1",
          "coverage_score" => 0.5,
          "state" => "identified",
          "salary_range" => nil,
          "jd_tags" => nil
        },
        %{
          "id" => "2",
          "coverage_score" => 0.9,
          "state" => "ready_to_submit",
          "salary_range" => %{"min" => 150_000, "max" => 200_000},
          "jd_tags" => %{"seniority" => "senior"}
        },
        %{
          "id" => "3",
          "coverage_score" => 0.7,
          "state" => "submitted",
          "salary_range" => %{"min" => 100_000, "max" => 120_000},
          "jd_tags" => nil
        }
      ]

      ranked = Ranking.rank(apps)

      assert length(ranked) == 3
      # First should be app 2 (highest score)
      {first_app, _} = hd(ranked)
      assert first_app["id"] == "2"
      # Scores should be descending
      scores = Enum.map(ranked, &elem(&1, 1))
      assert scores == Enum.sort(scores, :desc)
    end

    test "handles empty list" do
      ranked = Ranking.rank([])
      assert ranked == []
    end

    test "returns tuples of {application, score}" do
      apps = [
        %{
          "coverage_score" => 0.7,
          "state" => "identified",
          "salary_range" => nil,
          "jd_tags" => nil
        }
      ]

      ranked = Ranking.rank(apps)

      assert length(ranked) == 1
      {app, score} = hd(ranked)
      assert is_map(app)
      assert is_float(score)
      assert score >= 0.0 and score <= 1.0
    end
  end

  describe "top_n/2" do
    test "returns top N applications" do
      apps =
        Enum.map(1..10, fn i ->
          %{
            "id" => to_string(i),
            "coverage_score" => i / 10,
            "state" => "identified",
            "salary_range" => nil,
            "jd_tags" => nil
          }
        end)

      top_3 = Ranking.top_n(apps, 3)

      assert length(top_3) == 3
      # Top 3 should be highest scores
      {app1, _} = hd(top_3)
      # Highest coverage_score (1.0)
      assert app1["id"] == "10"
    end

    test "handles N larger than list size" do
      apps = [
        %{
          "coverage_score" => 0.8,
          "state" => "identified",
          "salary_range" => nil,
          "jd_tags" => nil
        },
        %{
          "coverage_score" => 0.5,
          "state" => "identified",
          "salary_range" => nil,
          "jd_tags" => nil
        }
      ]

      top_10 = Ranking.top_n(apps, 10)

      assert length(top_10) == 2
    end

    test "handles N = 0" do
      apps = [
        %{
          "coverage_score" => 0.8,
          "state" => "identified",
          "salary_range" => nil,
          "jd_tags" => nil
        }
      ]

      top_0 = Ranking.top_n(apps, 0)

      assert length(top_0) == 0
    end
  end

  describe "by_tier/1" do
    test "groups applications into high/medium/low tiers" do
      apps = [
        %{
          "coverage_score" => 0.95,
          "state" => "ready_to_submit",
          "salary_range" => %{"min" => 150_000, "max" => 200_000},
          "jd_tags" => %{"seniority" => "senior"}
        },
        %{
          "coverage_score" => 0.60,
          "state" => "submitted",
          "salary_range" => %{"min" => 100_000, "max" => 120_000},
          "jd_tags" => %{}
        },
        %{
          "coverage_score" => 0.2,
          "state" => "rejected",
          "salary_range" => %{"min" => 50_000, "max" => 60_000},
          "jd_tags" => %{}
        }
      ]

      {high, _medium, low} = Ranking.by_tier(apps)

      # At least one in high tier
      assert length(high) > 0
      # At least one in low tier
      assert length(low) > 0
      # All high tier scores >= 0.75
      Enum.each(high, fn {_, score} ->
        assert score >= 0.75
      end)

      # All low tier scores < 0.50
      Enum.each(low, fn {_, score} ->
        assert score < 0.50
      end)
    end

    test "returns three-tuple regardless of tier population" do
      apps = [
        %{
          "coverage_score" => 0.5,
          "state" => "identified",
          "salary_range" => nil,
          "jd_tags" => nil
        }
      ]

      {high, medium, low} = Ranking.by_tier(apps)

      assert is_list(high)
      assert is_list(medium)
      assert is_list(low)
    end
  end

  describe "coverage scoring" do
    test "accepts float coverage scores" do
      app = %{
        "coverage_score" => 0.75,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => nil
      }

      score = Ranking.score(app)
      # Coverage score is 40% of total weight with 0.75 value
      # 0.75 * 0.40 = 0.30
      assert score >= 0.3
    end

    test "accepts integer coverage scores (0-100)" do
      app = %{
        # 80%
        "coverage_score" => 80,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => nil
      }

      score = Ranking.score(app)
      # 80 -> 0.8, should contribute 0.32 (0.8 * 0.40)
      assert score >= 0.30
    end
  end

  describe "salary scoring" do
    test "high salary range (150k+, 200k+) scores 1.0" do
      app = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => %{"min" => 150_000, "max" => 200_000},
        "jd_tags" => nil
      }

      score = Ranking.score(app)
      # Salary is 20% weight at 1.0
      # 0.5*0.40 + 1.0*0.20 + 0.5*0.30 + 0.5*0.10
      assert score >= 0.27
    end

    test "low salary range (50k, 60k) scores lower than high salary" do
      app_low_salary = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => %{"min" => 50_000, "max" => 60_000},
        "jd_tags" => nil
      }

      app_high_salary = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => %{"min" => 150_000, "max" => 200_000},
        "jd_tags" => nil
      }

      score_low = Ranking.score(app_low_salary)
      score_high = Ranking.score(app_high_salary)

      # High salary should score better than low salary
      assert score_high > score_low
    end

    test "missing min salary scores based on max" do
      app_only_max = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => %{"max" => 200_000},
        "jd_tags" => nil
      }

      score = Ranking.score(app_only_max)
      assert is_float(score)
      assert score > 0.0
    end

    test "nil salary_range defaults to neutral 0.5" do
      app = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => nil
      }

      score = Ranking.score(app)
      # Salary neutral at 0.5: 0.5*0.40 + 0.9*0.30 + 0.5*0.20 + 0.5*0.10 = 0.62
      # (state "identified" = 0.9, not 0.5)
      assert Float.round(score, 2) == 0.62
    end
  end

  describe "role seniority scoring" do
    test "senior level scores higher than junior" do
      app_senior = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => %{"seniority" => "senior"}
      }

      app_junior = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => %{"seniority" => "junior"}
      }

      score_senior = Ranking.score(app_senior)
      score_junior = Ranking.score(app_junior)

      assert score_senior > score_junior
    end

    test "lead/staff level scores highest" do
      app_lead = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => %{"seniority" => "lead"}
      }

      app_entry = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => %{"seniority" => "entry"}
      }

      score_lead = Ranking.score(app_lead)
      score_entry = Ranking.score(app_entry)

      assert score_lead > score_entry
    end
  end

  describe "specificity scoring" do
    test "more technologies increase score" do
      app_generic = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => %{"technologies" => []}
      }

      app_specific = %{
        "coverage_score" => 0.5,
        "state" => "identified",
        "salary_range" => nil,
        "jd_tags" => %{
          "technologies" => ["Elixir", "Go", "Rust", "Python", "Clojure"],
          "frameworks" => ["Phoenix", "GenServer", "Ecto"]
        }
      }

      score_generic = Ranking.score(app_generic)
      score_specific = Ranking.score(app_specific)

      assert score_specific > score_generic
    end
  end

  describe "state priority" do
    test "ready_to_submit state has highest priority" do
      base = %{
        "coverage_score" => 0.5,
        "salary_range" => nil,
        "jd_tags" => nil
      }

      states = [
        "ready_to_submit",
        "drafting",
        "identified",
        "submitted",
        "phone_screen",
        "technical",
        "offer",
        "accepted",
        "declined",
        "rejected"
      ]

      scores =
        Enum.map(states, fn state ->
          app = Map.put(base, "state", state)
          {state, Ranking.score(app)}
        end)

      # ready_to_submit should be highest
      {best_state, best_score} = Enum.max_by(scores, &elem(&1, 1))
      assert best_state == "ready_to_submit"

      # rejected/declined should be lowest
      {worst_state, worst_score} = Enum.min_by(scores, &elem(&1, 1))
      assert worst_state in ["rejected", "declined", "ghosted"]
      assert best_score > worst_score
    end
  end
end
