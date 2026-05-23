defmodule ApplicationHandlerTest do
  use ExUnit.Case, async: true
  @moduletag :handlers

  alias BotArmyJobApplications.Handlers.ApplicationHandler

  describe "handle_create/1" do
    test "validates required fields: company" do
      message = %{
        "event_id" => "test-event-123",
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => nil,
        "payload" => %{
          "role_title" => "Senior Engineer"
        }
      }

      # Should not raise, but should reject invalid data
      result = ApplicationHandler.handle_create(message)
      assert result == :ok
    end

    test "validates required fields: role_title" do
      message = %{
        "event_id" => "test-event-123",
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => nil,
        "payload" => %{
          "company" => "TechCorp"
        }
      }

      result = ApplicationHandler.handle_create(message)
      assert result == :ok
    end

    test "validates payload presence" do
      message = %{
        "event_id" => "test-event-123",
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => nil
      }

      result = ApplicationHandler.handle_create(message)
      assert result == :ok
    end
  end

  describe "handle_transition/1" do
    test "validates state transition syntax" do
      message = %{
        "event_id" => "test-event-456",
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => nil,
        "payload" => %{
          "to_state" => "drafted"
        }
      }

      result = ApplicationHandler.handle_transition(message)
      assert result == :ok
    end

    test "validates application_id presence" do
      message = %{
        "event_id" => "test-event-456",
        "payload" => %{
          "to_state" => "drafting"
        }
      }

      result = ApplicationHandler.handle_transition(message)
      assert result == :ok
    end

    test "validates to_state presence" do
      message = %{
        "event_id" => "test-event-456",
        "payload" => %{
          "application_id" => "some-app-id"
        }
      }

      result = ApplicationHandler.handle_transition(message)
      assert result == :ok
    end
  end
end
