defmodule BotArmyJobApplications.Handlers.EmailSignalHandlerTest do
  use ExUnit.Case, async: false
  import Mox

  setup :verify_on_exit!

  describe "handle_email_signal" do
    setup do
      # Create a test application
      app = %{
        "id" => "app-123",
        "company" => "Anthropic",
        "role_title" => "Senior Engineer",
        "state" => "identified",
        "pending_signal" => nil
      }

      {:ok, app: app}
    end

    test "matches interview_request and creates signal with correct structure", %{app: app} do
      stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [app]}
      end)

      expect(BotArmyJobApplications.ApplicationStoreMock, :update, fn app_id, payload ->
        assert app_id == "app-123"
        assert is_map(payload["pending_signal"])

        signal = payload["pending_signal"]
        assert signal["type"] == "interview_invite"
        assert signal["proposed_transition"] == "phone_screen"
        assert signal["email_id"] == 12345
        assert signal["from_address"] == "recruiter@anthropic.com"
        assert signal["subject_line"] == "Interview with Anthropic Engineering Team"
        assert signal["confidence"] == 0.95
        assert String.match?(signal["detected_at"], ~r/^\d{4}-\d{2}-\d{2}/)

        {:ok, Map.put(app, "pending_signal", signal)}
      end)

      message = %{
        "event" => "job.email.interview_request",
        "event_id" => "evt-123",
        "payload" => %{
          "match_type" => "interview_request",
          "confidence" => 0.95,
          "message_id" => 12345,
          "from" => "recruiter@anthropic.com",
          "subject" => "Interview with Anthropic Engineering Team"
        }
      }

      result = BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert {:ok, {:signal_detected, signal}} = result
      assert is_map(signal)
    end

    test "matches phone_screen and creates interview_invite signal", %{app: app} do
      stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [app]}
      end)

      expect(BotArmyJobApplications.ApplicationStoreMock, :update, fn _app_id, payload ->
        signal = payload["pending_signal"]
        assert signal["type"] == "interview_invite"
        assert signal["proposed_transition"] == "phone_screen"
        {:ok, Map.put(app, "pending_signal", signal)}
      end)

      message = %{
        "event" => "job.email.phone_screen",
        "event_id" => "evt-123",
        "payload" => %{
          "match_type" => "phone_screen",
          "confidence" => 0.92,
          "message_id" => 12346,
          "from" => "recruiter@anthropic.com",
          "subject" => "Phone screen with Anthropic"
        }
      }

      {:ok, {:signal_detected, signal}} =
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert signal["type"] == "interview_invite"
      assert signal["proposed_transition"] == "phone_screen"
    end

    test "matches offer and creates offer signal", %{app: app} do
      stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [app]}
      end)

      expect(BotArmyJobApplications.ApplicationStoreMock, :update, fn _app_id, payload ->
        signal = payload["pending_signal"]
        assert signal["type"] == "offer"
        assert signal["proposed_transition"] == "offer"
        {:ok, Map.put(app, "pending_signal", signal)}
      end)

      message = %{
        "event" => "job.email.offer",
        "event_id" => "evt-123",
        "payload" => %{
          "match_type" => "offer",
          "confidence" => 0.99,
          "message_id" => 12347,
          "from" => "recruiter@anthropic.com",
          "subject" => "Offer for Anthropic"
        }
      }

      {:ok, {:signal_detected, signal}} =
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert signal["type"] == "offer"
      assert signal["proposed_transition"] == "offer"
    end

    test "matches rejection and creates rejection signal", %{app: app} do
      stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [app]}
      end)

      expect(BotArmyJobApplications.ApplicationStoreMock, :update, fn _app_id, payload ->
        signal = payload["pending_signal"]
        assert signal["type"] == "rejection"
        assert signal["proposed_transition"] == "rejected"
        {:ok, Map.put(app, "pending_signal", signal)}
      end)

      message = %{
        "event" => "job.email.rejection",
        "event_id" => "evt-123",
        "payload" => %{
          "match_type" => "rejection",
          "confidence" => 0.88,
          "message_id" => 12348,
          "from" => "recruiter@anthropic.com",
          "subject" => "Rejection from Anthropic"
        }
      }

      {:ok, {:signal_detected, signal}} =
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert signal["type"] == "rejection"
      assert signal["proposed_transition"] == "rejected"
    end

    test "returns no_match when no matching application found", %{app: _app} do
      other_app = %{
        "id" => "app-456",
        "company" => "Google",
        "role_title" => "Engineer",
        "state" => "identified",
        "pending_signal" => nil
      }

      stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [other_app]}
      end)

      message = %{
        "event" => "job.email.interview_request",
        "event_id" => "evt-123",
        "payload" => %{
          "match_type" => "interview_request",
          "confidence" => 0.95,
          "message_id" => 12345,
          "from" => "recruiter@anthropic.com",
          "subject" => "Interview with Anthropic Engineering Team"
        }
      }

      result = BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert result == {:ok, :no_match}
    end

    test "returns error when match_type is missing" do
      message = %{
        "event" => "job.email.interview_request",
        "event_id" => "evt-123",
        "payload" => %{
          "confidence" => 0.95,
          "message_id" => 12345,
          "from" => "recruiter@anthropic.com",
          "subject" => "Interview"
        }
      }

      result = BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert result == {:error, :invalid_payload}
    end

    test "returns error when payload is invalid" do
      message = %{
        "event" => "job.email.interview_request",
        "event_id" => "evt-123",
        "payload" => nil
      }

      result = BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert result == {:error, :invalid_payload}
    end

    test "stores signal with confidence when provided", %{app: app} do
      stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [app]}
      end)

      expect(BotArmyJobApplications.ApplicationStoreMock, :update, fn _app_id, payload ->
        signal = payload["pending_signal"]
        assert signal["confidence"] == 0.87
        {:ok, Map.put(app, "pending_signal", signal)}
      end)

      message = %{
        "event" => "job.email.interview_request",
        "event_id" => "evt-123",
        "payload" => %{
          "match_type" => "interview_request",
          "confidence" => 0.87,
          "message_id" => 12345,
          "from" => "recruiter@anthropic.com",
          "subject" => "Interview with Anthropic"
        }
      }

      {:ok, {:signal_detected, _signal}} =
        BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)
    end

    test "matches by email domain when subject doesn't contain company name", %{app: app} do
      stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [app]}
      end)

      expect(BotArmyJobApplications.ApplicationStoreMock, :update, fn _app_id, payload ->
        assert is_map(payload["pending_signal"])
        {:ok, Map.put(app, "pending_signal", payload["pending_signal"])}
      end)

      message = %{
        "event" => "job.email.interview_request",
        "event_id" => "evt-123",
        "payload" => %{
          "match_type" => "interview_request",
          "confidence" => 0.95,
          "message_id" => 12345,
          "from" => "recruiter@anthropic.com",
          "subject" => "Interview next week"
        }
      }

      result = BotArmyJobApplications.Handlers.EmailSignalHandler.handle_email_signal(message)

      assert {:ok, {:signal_detected, signal}} = result
      assert is_map(signal)
    end
  end
end
