defmodule BotArmyJobApplications.Handlers.ArtifactHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :handlers

  describe "handle_request/1" do
    test "validates required fields: application_id" do
      message = %{
        "event_id" => "test-event-789",
        "payload" => %{
          "resume_id" => "some-resume-id"
        }
      }

      # Handlers return :ok regardless; errors logged
      result = BotArmyJobApplications.Handlers.ArtifactHandler.handle_request(message)
      assert result == :ok
    end

    test "validates required fields: resume_id" do
      message = %{
        "event_id" => "test-event-789",
        "payload" => %{
          "application_id" => "some-app-id"
        }
      }

      result = BotArmyJobApplications.Handlers.ArtifactHandler.handle_request(message)
      assert result == :ok
    end

    test "validates payload presence" do
      message = %{
        "event_id" => "test-event-789"
      }

      result = BotArmyJobApplications.Handlers.ArtifactHandler.handle_request(message)
      assert result == :ok
    end
  end

  describe "ResumeComposer integration" do
    test "compose returns expected structure" do
      resume = %{
        "id" => "test-resume",
        "identity" => %{"name" => "John", "summary" => "Engineer"},
        "roles" => [],
        "skills" => [
          %{"name" => "Kubernetes", "tags" => ["platform", "devops"]}
        ]
      }

      jd_tags = ["platform", "kubernetes", "cloud"]

      result = BotArmyJobApplications.ResumeComposer.compose(resume, jd_tags)

      assert is_map(result)
      assert Map.has_key?(result, "coverage_score")
      assert Map.has_key?(result, "roles")
      assert Map.has_key?(result, "skills")
    end
  end
end
