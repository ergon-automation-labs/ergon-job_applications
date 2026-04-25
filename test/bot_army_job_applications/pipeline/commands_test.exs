defmodule BotArmyJobApplications.CommandsTest do
  use ExUnit.Case
  @moduletag :pipeline
  doctest BotArmyJobApplications.Commands

  describe "valid_transition?/2" do
    test "allows identified -> drafting" do
      assert BotArmyJobApplications.Commands.valid_transition?("identified", "drafting")
    end

    test "allows drafting -> ready_to_submit" do
      assert BotArmyJobApplications.Commands.valid_transition?("drafting", "ready_to_submit")
    end

    test "allows ready_to_submit -> submitted" do
      assert BotArmyJobApplications.Commands.valid_transition?("ready_to_submit", "submitted")
    end

    test "allows submitted -> phone_screen" do
      assert BotArmyJobApplications.Commands.valid_transition?("submitted", "phone_screen")
    end

    test "allows submitted -> rejected" do
      assert BotArmyJobApplications.Commands.valid_transition?("submitted", "rejected")
    end

    test "allows submitted -> ghosted" do
      assert BotArmyJobApplications.Commands.valid_transition?("submitted", "ghosted")
    end

    test "allows phone_screen -> technical" do
      assert BotArmyJobApplications.Commands.valid_transition?("phone_screen", "technical")
    end

    test "allows technical -> offer" do
      assert BotArmyJobApplications.Commands.valid_transition?("technical", "offer")
    end

    test "allows offer -> accepted" do
      assert BotArmyJobApplications.Commands.valid_transition?("offer", "accepted")
    end

    test "allows offer -> declined" do
      assert BotArmyJobApplications.Commands.valid_transition?("offer", "declined")
    end

    test "rejects invalid transitions" do
      refute BotArmyJobApplications.Commands.valid_transition?("identified", "submitted")
      refute BotArmyJobApplications.Commands.valid_transition?("drafting", "submitted")
      refute BotArmyJobApplications.Commands.valid_transition?("accepted", "declined")
    end

    test "rejects unknown states" do
      refute BotArmyJobApplications.Commands.valid_transition?("unknown", "identified")
      refute BotArmyJobApplications.Commands.valid_transition?("identified", "unknown")
    end
  end

  describe "terminal?/1" do
    test "terminal states are accepted, declined, rejected, ghosted" do
      assert BotArmyJobApplications.Commands.terminal?("accepted")
      assert BotArmyJobApplications.Commands.terminal?("declined")
      assert BotArmyJobApplications.Commands.terminal?("rejected")
      assert BotArmyJobApplications.Commands.terminal?("ghosted")
    end

    test "non-terminal states are not terminal" do
      refute BotArmyJobApplications.Commands.terminal?("identified")
      refute BotArmyJobApplications.Commands.terminal?("drafting")
      refute BotArmyJobApplications.Commands.terminal?("ready_to_submit")
      refute BotArmyJobApplications.Commands.terminal?("submitted")
      refute BotArmyJobApplications.Commands.terminal?("phone_screen")
      refute BotArmyJobApplications.Commands.terminal?("technical")
      refute BotArmyJobApplications.Commands.terminal?("offer")
    end
  end

  describe "next_states/1" do
    test "identified has next state drafting" do
      assert BotArmyJobApplications.Commands.next_states("identified") == ["drafting"]
    end

    test "submitted has multiple next states" do
      next = BotArmyJobApplications.Commands.next_states("submitted")
      assert "phone_screen" in next
      assert "rejected" in next
      assert "ghosted" in next
    end

    test "terminal states have no next states" do
      assert BotArmyJobApplications.Commands.next_states("accepted") == []
      assert BotArmyJobApplications.Commands.next_states("declined") == []
      assert BotArmyJobApplications.Commands.next_states("rejected") == []
      assert BotArmyJobApplications.Commands.next_states("ghosted") == []
    end
  end

  describe "create_state_event/3" do
    test "creates valid state event" do
      {:ok, event} =
        BotArmyJobApplications.Commands.create_state_event("identified", "drafting", %{})

      assert event["from_state"] == "identified"
      assert event["to_state"] == "drafting"
      assert is_binary(event["transitioned_at"])
      assert event["metadata"] == %{}
    end

    test "creates state event with metadata" do
      metadata = %{"reason" => "user_input", "triggered_by" => "web"}

      {:ok, event} =
        BotArmyJobApplications.Commands.create_state_event(
          "drafting",
          "ready_to_submit",
          metadata
        )

      assert event["metadata"] == metadata
    end

    test "rejects invalid transition" do
      {:error, :invalid_transition} =
        BotArmyJobApplications.Commands.create_state_event("identified", "submitted", %{})
    end

    test "timestamp is ISO8601 formatted" do
      {:ok, event} =
        BotArmyJobApplications.Commands.create_state_event("identified", "drafting", %{})

      assert String.match?(event["transitioned_at"], ~r/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
    end
  end
end
