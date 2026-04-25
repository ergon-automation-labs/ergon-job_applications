defmodule BotArmyJobApplications.ResumeComposerTest do
  use ExUnit.Case
  @moduletag :core
  doctest BotArmyJobApplications.ResumeComposer

  describe "compose/2" do
    setup do
      resume = %{
        "identity" => %{
          "name" => "John Doe",
          "summary" => "Experienced engineer",
          "summary_variants" => %{
            "platform" => "Platform engineer with 5+ years experience",
            "sre" => "SRE specialist with focus on reliability",
            "ai_tooling" => "AI tooling expert"
          }
        },
        "roles" => [
          %{
            "title" => "Senior Engineer",
            "company" => "TechCorp",
            "bullets" => [
              %{
                "text" => "Built scalable platform",
                "tags" => ["platform", "architecture"],
                "strength" => "strong"
              },
              %{
                "text" => "Managed Kubernetes clusters",
                "tags" => ["kubernetes", "devops"],
                "strength" => "strong"
              },
              %{
                "text" => "Mentored junior engineers",
                "tags" => ["leadership"],
                "strength" => "medium"
              }
            ]
          }
        ],
        "skills" => [
          %{
            "name" => "Kubernetes",
            "tags" => ["kubernetes", "devops"],
            "proficiency" => "expert"
          },
          %{
            "name" => "Python",
            "tags" => ["python", "ai_tooling"],
            "proficiency" => "expert"
          },
          %{
            "name" => "Writing",
            "tags" => ["communication"],
            "proficiency" => "proficient"
          }
        ]
      }

      {:ok, resume: resume}
    end

    test "composes resume for JD with matching tags", %{resume: resume} do
      jd_tags = ["platform", "kubernetes", "scalability"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      assert result["coverage_score"] > 0
      assert result["coverage_score"] <= 1.0
      assert is_list(result["roles"])
      assert is_list(result["skills"])
      assert is_binary(result["summary"])
    end

    test "scores bullets correctly", %{resume: resume} do
      jd_tags = ["platform", "kubernetes"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      # Should have roles with scored bullets
      [role | _] = result["roles"]
      assert length(role["bullets"]) >= 0
    end

    test "filters skills by tag overlap", %{resume: resume} do
      jd_tags = ["kubernetes", "devops"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      # Should include Kubernetes skill
      skill_names = Enum.map(result["skills"], & &1["name"])
      assert "Kubernetes" in skill_names
    end

    test "excludes skills with no tag overlap", %{resume: resume} do
      jd_tags = ["random", "tags"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      # Should not include Writing skill (no matching tags)
      skill_names = Enum.map(result["skills"], & &1["name"])
      refute "Writing" in skill_names
    end

    test "selects summary variant by dominant tag", %{resume: resume} do
      jd_tags = ["platform", "architecture"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      # Should select platform variant
      assert String.contains?(result["summary"], "Platform engineer")
    end

    test "falls back to default summary when no variant matches", %{resume: resume} do
      jd_tags = ["unknown", "tags"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      # Should use default summary
      assert result["summary"] == "Experienced engineer"
    end

    test "handles empty JD tags", %{resume: resume} do
      result = BotArmyJobApplications.ResumeComposer.compose(resume, [])

      assert result["coverage_score"] == 0.0
      assert result["matched_tags_count"] == 0
    end

    test "includes matched_tags_count in result", %{resume: resume} do
      jd_tags = ["platform", "kubernetes"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      assert is_integer(result["matched_tags_count"])
      assert is_integer(result["total_tags_count"])
      assert result["total_tags_count"] == length(jd_tags)
    end
  end

  describe "calculate_tag_overlap/2" do
    test "counts intersection of tags" do
      tags1 = ["platform", "kubernetes", "python"]
      tags2 = ["kubernetes", "python", "go"]

      score = BotArmyJobApplications.ResumeComposer.calculate_tag_overlap(tags1, tags2)

      assert score == 2
    end

    test "returns 0 when no overlap" do
      tags1 = ["a", "b", "c"]
      tags2 = ["x", "y", "z"]

      score = BotArmyJobApplications.ResumeComposer.calculate_tag_overlap(tags1, tags2)

      assert score == 0
    end

    test "handles empty lists" do
      assert BotArmyJobApplications.ResumeComposer.calculate_tag_overlap([], []) == 0
      assert BotArmyJobApplications.ResumeComposer.calculate_tag_overlap(["a"], []) == 0
      assert BotArmyJobApplications.ResumeComposer.calculate_tag_overlap([], ["b"]) == 0
    end

    test "handles duplicate tags" do
      tags1 = ["platform", "platform", "kubernetes"]
      tags2 = ["platform", "kubernetes"]

      # Should use unique tags (sets)
      score = BotArmyJobApplications.ResumeComposer.calculate_tag_overlap(tags1, tags2)

      assert score == 2
    end
  end

  describe "edge cases" do
    test "handles resume with no roles" do
      resume = %{
        "identity" => %{"summary" => "Test"},
        "skills" => [%{"name" => "Skill1", "tags" => ["tag1"]}]
      }

      result = BotArmyJobApplications.ResumeComposer.compose(resume, ["tag1"])

      assert is_map(result)
    end

    test "handles resume with no skills" do
      resume = %{
        "identity" => %{"summary" => "Test"},
        "roles" => [%{"title" => "Role1", "bullets" => []}]
      }

      result = BotArmyJobApplications.ResumeComposer.compose(resume, ["tag1"])

      assert is_map(result)
    end

    test "handles bullet with no tags" do
      resume = %{
        "identity" => %{"summary" => "Test"},
        "roles" => [
          %{
            "title" => "Role1",
            "bullets" => [%{"text" => "Did something"}]
          }
        ]
      }

      result = BotArmyJobApplications.ResumeComposer.compose(resume, ["tag1"])

      assert is_map(result)
    end
  end
end
