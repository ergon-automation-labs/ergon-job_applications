defmodule BotArmyJobApplications.Handlers.IngestHandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias BotArmyJobApplications.Handlers.IngestHandler

  setup :verify_on_exit!

  describe "handle_ingest/1" do
    test "returns error when company is missing" do
      message = %{
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => nil,
        "payload" => %{"role_title" => "Engineer", "jd_url" => "https://x.com/1"}
      }
      assert IngestHandler.handle_ingest(message) == {:error, :missing_required}
    end

    test "returns error when role_title is missing" do
      message = %{
        "tenant_id" => "00000000-0000-0000-0000-000000000001",
        "user_id" => nil,
        "payload" => %{"company" => "Co", "jd_url" => "https://x.com/1"}
      }
      assert IngestHandler.handle_ingest(message) == {:error, :missing_required}
    end

    test "returns error for invalid payload" do
      assert IngestHandler.handle_ingest(nil) == {:error, :invalid_payload}
      assert IngestHandler.handle_ingest("string") == {:error, :invalid_payload}
    end

    test "returns :duplicate when listing already exists (same dedup_hash)" do
      tenant_id = "00000000-0000-0000-0000-000000000001"
      message = %{
        "tenant_id" => tenant_id,
        "user_id" => nil,
        "payload" => %{"company" => "Stripe", "role_title" => "Engineer", "jd_url" => "https://boards.greenhouse.io/stripe/jobs/1"}
      }
      BotArmyJobApplications.ListingStoreMock
      |> expect(:get_by_dedup_hash, fn ^tenant_id, _hash ->
        {:ok, %{"id" => "existing-id"}}
      end)

      assert IngestHandler.handle_ingest(message) == {:ok, :duplicate}
    end

    test "creates listing and returns {:ok, {:created, listing}} when new" do
      tenant_id = "00000000-0000-0000-0000-000000000001"
      user_id = nil
      message = %{
        "tenant_id" => tenant_id,
        "user_id" => user_id,
        "payload" => %{
          "company" => "Stripe",
          "role_title" => "Senior Engineer",
          "jd_url" => "https://boards.greenhouse.io/stripe/jobs/99",
          "jd_text" => "Description",
          "source" => "greenhouse"
        }
      }

      BotArmyJobApplications.ListingStoreMock
      |> expect(:get_by_dedup_hash, fn ^tenant_id, _hash -> {:error, :not_found} end)
      |> expect(:create, fn attrs ->
        assert attrs["company"] == "Stripe"
        assert attrs["role_title"] == "Senior Engineer"
        assert attrs["source"] == "greenhouse"
        assert attrs["status"] == "new"
        assert is_binary(attrs["dedup_hash"])
        assert attrs["tenant_id"] == tenant_id
        assert attrs["user_id"] == user_id
        {:ok, Map.put(attrs, "id", "new-id")}
      end)

      # Mock ResumeStore.list() which is called by score_listing_async
      BotArmyJobApplications.ResumeStoreMock
      |> expect(:list, fn ^tenant_id -> {:error, :no_resumes} end)

      # Publisher is not mocked; it will try to publish. We only assert the handler return value.
      assert {:ok, {:created, listing}} = IngestHandler.handle_ingest(message)
      assert listing["id"] == "new-id"
    end
  end
end
