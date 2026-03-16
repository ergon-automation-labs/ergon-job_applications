defmodule BotArmyJobApplications.Handlers.DigestHandlerTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  setup do
    # Mock the application store by default
    stub(BotArmyJobApplications.ApplicationStoreMock, :list, fn -> {:ok, []} end)
    :ok
  end

  describe "build_digest/1" do
    test "returns empty digest for empty application list" do
      digest = BotArmyJobApplications.Handlers.DigestHandler.build_digest([])

      assert digest["total_active"] == 0
      assert digest["total_terminal"] == 0
      assert digest["by_state"] == %{}
      assert digest["pending_signals"] == []
      assert digest["recent_activity"] == []
      assert digest["stalled"] == []
      assert digest["generated_at"]
    end

    test "counts active vs terminal states correctly" do
      now = DateTime.utc_now()
      apps = [
        %{"id" => "1", "state" => "identified", "company" => "Acme", "role_title" => "Engineer", "updated_at" => DateTime.to_iso8601(now)},
        %{"id" => "2", "state" => "submitted", "company" => "Anvil", "role_title" => "Manager", "updated_at" => DateTime.to_iso8601(now)},
        %{"id" => "3", "state" => "accepted", "company" => "BigCorp", "role_title" => "Lead", "updated_at" => DateTime.to_iso8601(now)},
        %{"id" => "4", "state" => "rejected", "company" => "LittleCorp", "role_title" => "Dev", "updated_at" => DateTime.to_iso8601(now)}
      ]

      digest = BotArmyJobApplications.Handlers.DigestHandler.build_digest(apps)

      assert digest["total_active"] == 2
      assert digest["total_terminal"] == 2
      assert digest["by_state"]["identified"] == 1
      assert digest["by_state"]["submitted"] == 1
    end

    test "identifies pending signals correctly" do
      signal = %{
        "type" => "offer",
        "proposed_transition" => "offer",
        "email_id" => "email123",
        "from_address" => "recruiter@acme.com",
        "subject_line" => "Offer from Acme",
        "confidence" => 0.95,
        "detected_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      now = DateTime.utc_now()
      apps = [
        %{
          "id" => "1",
          "state" => "phone_screen",
          "company" => "Acme",
          "role_title" => "Engineer",
          "pending_signal" => signal,
          "updated_at" => DateTime.to_iso8601(now)
        },
        %{
          "id" => "2",
          "state" => "identified",
          "company" => "Anvil",
          "role_title" => "Manager",
          "pending_signal" => nil,
          "updated_at" => DateTime.to_iso8601(now)
        }
      ]

      digest = BotArmyJobApplications.Handlers.DigestHandler.build_digest(apps)

      assert length(digest["pending_signals"]) == 1
      assert digest["pending_signals"] |> Enum.at(0) |> Map.get("company") == "Acme"
      assert digest["pending_signals"] |> Enum.at(0) |> Map.get("signal_type") == "offer"
    end

    test "identifies stalled applications (7+ days old)" do
      now = DateTime.utc_now()
      stale_time = DateTime.add(now, -(10 * 86400), :second)  # 10 days ago

      apps = [
        %{
          "id" => "1",
          "state" => "identified",
          "company" => "Stale Corp",
          "role_title" => "Engineer",
          "updated_at" => DateTime.to_iso8601(stale_time)
        },
        %{
          "id" => "2",
          "state" => "submitted",
          "company" => "Fresh Corp",
          "role_title" => "Manager",
          "updated_at" => DateTime.to_iso8601(now)
        }
      ]

      digest = BotArmyJobApplications.Handlers.DigestHandler.build_digest(apps)

      assert length(digest["stalled"]) == 1
      assert digest["stalled"] |> Enum.at(0) |> Map.get("company") == "Stale Corp"
      assert digest["stalled"] |> Enum.at(0) |> Map.get("days_since_update") >= 10
    end

    test "excludes old activity (only shows last 24h transitions)" do
      now = DateTime.utc_now()
      # Use 12 hours ago (definitely within 24h window)
      recent_time = DateTime.add(now, -(12 * 3600), :second)
      # Use 3 days ago (definitely outside 24h window)
      old_time = DateTime.add(now, -(3 * 86400), :second)

      apps = [
        %{
          "id" => "1",
          "state" => "submitted",
          "company" => "Recent Corp",
          "role_title" => "Engineer",
          "history" => [
            %{
              "from_state" => "identified",
              "to_state" => "submitted",
              "transitioned_at" => DateTime.to_iso8601(recent_time)
            }
          ],
          "updated_at" => DateTime.to_iso8601(recent_time)
        },
        %{
          "id" => "2",
          "state" => "phone_screen",
          "company" => "Old Corp",
          "role_title" => "Manager",
          "history" => [
            %{
              "from_state" => "submitted",
              "to_state" => "phone_screen",
              "transitioned_at" => DateTime.to_iso8601(old_time)
            }
          ],
          "updated_at" => DateTime.to_iso8601(old_time)
        }
      ]

      digest = BotArmyJobApplications.Handlers.DigestHandler.build_digest(apps)

      # Only recent activity should be included
      assert length(digest["recent_activity"]) == 1
      assert digest["recent_activity"] |> Enum.at(0) |> Map.get("company") == "Recent Corp"
    end

    test "handle_request calls store and publishes digest" do
      expect(BotArmyJobApplications.ApplicationStoreMock, :list, fn ->
        {:ok, [
          %{
            "id" => "1",
            "state" => "identified",
            "company" => "Test Corp",
            "role_title" => "Engineer",
            "updated_at" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]}
      end)

      message = %{
        "event" => "job.digest.request",
        "event_id" => "test-event-1",
        "payload" => %{}
      }

      Application.put_env(:bot_army_job_applications, :application_store, BotArmyJobApplications.ApplicationStoreMock)

      # Call handle_request
      result = BotArmyJobApplications.Handlers.DigestHandler.handle_request(message)

      # Should succeed (no exception)
      assert result == :ok or is_map(result)
    end
  end
end
