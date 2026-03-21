defmodule BotArmyJobApplications.Handlers.ResumeTuiHandlerTest do
  use ExUnit.Case, async: false
  import Mox

  setup :verify_on_exit!

  alias BotArmyJobApplications.Handlers.ResumeTuiHandler

  describe "handle_create/1" do
    test "returns ok with resume_id on success" do
      resume_id = "test-resume-id-123"

      expect(BotArmyJobApplications.ResumeStoreMock, :create_from_parsed, fn payload, %{} ->
        assert payload["identity"]["name"] == "Jane Doe"
        assert payload["roles"] == []
        assert payload["skills"] == []
        {:ok, %{"id" => resume_id, "identity" => %{"name" => "Jane Doe"}}}
      end)

      payload = %{
        "identity" => %{"name" => "Jane Doe", "summary" => "Test"},
        "roles" => [],
        "skills" => []
      }

      result = ResumeTuiHandler.handle_create(payload)

      assert result == %{"ok" => true, "resume_id" => resume_id}
    end

    test "returns error map when store returns error" do
      expect(BotArmyJobApplications.ResumeStoreMock, :create_from_parsed, fn _payload, %{} ->
        {:error, :invalid_data}
      end)

      payload = %{
        "identity" => %{"name" => "Jane Doe"},
        "roles" => [],
        "skills" => []
      }

      result = ResumeTuiHandler.handle_create(payload)

      assert result == %{"ok" => false, "error" => "invalid_data"}
    end

    test "returns invalid_payload for non-map input" do
      result = ResumeTuiHandler.handle_create("not a map")
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end

    test "returns invalid_payload for nil input" do
      result = ResumeTuiHandler.handle_create(nil)
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end

    test "returns invalid_payload for list input" do
      result = ResumeTuiHandler.handle_create([])
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end
  end

  describe "handle_update/1" do
    test "returns ok on success" do
      resume_id = "existing-resume-id"

      expect(BotArmyJobApplications.ResumeStoreMock, :replace_full, fn ^resume_id, payload ->
        assert payload["identity"]["name"] == "Jane Smith"
        {:ok, %{"id" => resume_id, "identity" => %{"name" => "Jane Smith"}}}
      end)

      payload = %{
        "resume_id" => resume_id,
        "identity" => %{"name" => "Jane Smith", "summary" => "Updated"},
        "roles" => [],
        "skills" => []
      }

      result = ResumeTuiHandler.handle_update(payload)

      assert result == %{"ok" => true}
    end

    test "returns missing resume_id when resume_id key is absent" do
      payload = %{
        "identity" => %{"name" => "Jane"},
        "roles" => [],
        "skills" => []
      }

      result = ResumeTuiHandler.handle_update(payload)

      assert result == %{"ok" => false, "error" => "missing resume_id"}
    end

    test "returns missing resume_id when resume_id is empty string" do
      payload = %{
        "resume_id" => "",
        "identity" => %{"name" => "Jane"},
        "roles" => [],
        "skills" => []
      }

      result = ResumeTuiHandler.handle_update(payload)

      assert result == %{"ok" => false, "error" => "missing resume_id"}
    end

    test "returns error map when store returns error" do
      resume_id = "nonexistent-id"

      expect(BotArmyJobApplications.ResumeStoreMock, :replace_full, fn ^resume_id, _payload ->
        {:error, :not_found}
      end)

      payload = %{
        "resume_id" => resume_id,
        "identity" => %{"name" => "Jane"},
        "roles" => [],
        "skills" => []
      }

      result = ResumeTuiHandler.handle_update(payload)

      assert result == %{"ok" => false, "error" => "not_found"}
    end

    test "returns error with string reason from store" do
      resume_id = "some-id"

      expect(BotArmyJobApplications.ResumeStoreMock, :replace_full, fn ^resume_id, _payload ->
        {:error, "database connection failed"}
      end)

      payload = %{
        "resume_id" => resume_id,
        "identity" => %{"name" => "Jane"},
        "roles" => [],
        "skills" => []
      }

      result = ResumeTuiHandler.handle_update(payload)

      assert result == %{"ok" => false, "error" => "database connection failed"}
    end

    test "returns invalid_payload for non-map input" do
      result = ResumeTuiHandler.handle_update("not a map")
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end

    test "returns invalid_payload for nil input" do
      result = ResumeTuiHandler.handle_update(nil)
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end

    test "returns invalid_payload for list input" do
      result = ResumeTuiHandler.handle_update([])
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end
  end

  describe "handle_delete/1" do
    test "returns ok on success" do
      resume_id = "resume-to-delete"

      expect(BotArmyJobApplications.ResumeStoreMock, :delete, fn ^resume_id ->
        :ok
      end)

      payload = %{"resume_id" => resume_id}

      result = ResumeTuiHandler.handle_delete(payload)

      assert result == %{"ok" => true}
    end

    test "returns missing resume_id when resume_id key is absent" do
      payload = %{}

      result = ResumeTuiHandler.handle_delete(payload)

      assert result == %{"ok" => false, "error" => "missing resume_id"}
    end

    test "returns missing resume_id when resume_id is empty string" do
      payload = %{"resume_id" => ""}

      result = ResumeTuiHandler.handle_delete(payload)

      assert result == %{"ok" => false, "error" => "missing resume_id"}
    end

    test "returns error map when store returns error" do
      resume_id = "nonexistent-id"

      expect(BotArmyJobApplications.ResumeStoreMock, :delete, fn ^resume_id ->
        {:error, :not_found}
      end)

      payload = %{"resume_id" => resume_id}

      result = ResumeTuiHandler.handle_delete(payload)

      assert result == %{"ok" => false, "error" => "not_found"}
    end

    test "returns error with string reason from store" do
      resume_id = "some-id"

      expect(BotArmyJobApplications.ResumeStoreMock, :delete, fn ^resume_id ->
        {:error, "cascade delete failed"}
      end)

      payload = %{"resume_id" => resume_id}

      result = ResumeTuiHandler.handle_delete(payload)

      assert result == %{"ok" => false, "error" => "cascade delete failed"}
    end

    test "returns invalid_payload for non-map input" do
      result = ResumeTuiHandler.handle_delete("not a map")
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end

    test "returns invalid_payload for nil input" do
      result = ResumeTuiHandler.handle_delete(nil)
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end

    test "returns invalid_payload for list input" do
      result = ResumeTuiHandler.handle_delete([])
      assert result == %{"ok" => false, "error" => "invalid_payload"}
    end
  end
end
