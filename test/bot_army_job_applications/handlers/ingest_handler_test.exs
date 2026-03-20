defmodule BotArmyJobApplications.Handlers.IngestHandlerTest do
  use ExUnit.Case, async: false

  import Mox

  alias BotArmyJobApplications.Handlers.IngestHandler

  setup :verify_on_exit!

  describe "handle_ingest/1" do
    test "returns error when company is missing" do
      assert IngestHandler.handle_ingest(%{"role_title" => "Engineer", "jd_url" => "https://x.com/1"}) == {:error, :missing_required}
    end

    test "returns error when role_title is missing" do
      assert IngestHandler.handle_ingest(%{"company" => "Co", "jd_url" => "https://x.com/1"}) == {:error, :missing_required}
    end

    test "returns error for invalid payload" do
      assert IngestHandler.handle_ingest(nil) == {:error, :invalid_payload}
      assert IngestHandler.handle_ingest("string") == {:error, :invalid_payload}
    end

    test "returns :duplicate when listing already exists (same dedup_hash)" do
      payload = %{"company" => "Stripe", "role_title" => "Engineer", "jd_url" => "https://boards.greenhouse.io/stripe/jobs/1"}
      BotArmyJobApplications.ListingStoreMock
      |> expect(:get_by_dedup_hash, fn _hash ->
        {:ok, %{"id" => "existing-id"}}
      end)

      assert IngestHandler.handle_ingest(payload) == {:ok, :duplicate}
    end

    test "creates listing and returns {:ok, {:created, listing}} when new" do
      payload = %{
        "company" => "Stripe",
        "role_title" => "Senior Engineer",
        "jd_url" => "https://boards.greenhouse.io/stripe/jobs/99",
        "jd_text" => "Description",
        "source" => "greenhouse"
      }

      BotArmyJobApplications.ListingStoreMock
      |> expect(:get_by_dedup_hash, fn _hash -> {:error, :not_found} end)
      |> expect(:create, fn attrs ->
        assert attrs["company"] == "Stripe"
        assert attrs["role_title"] == "Senior Engineer"
        assert attrs["source"] == "greenhouse"
        assert attrs["status"] == "new"
        assert is_binary(attrs["dedup_hash"])
        {:ok, Map.put(attrs, "id", "new-id")}
      end)

      # Mock ResumeStore.list() which is called by score_listing_async
      BotArmyJobApplications.ResumeStoreMock
      |> expect(:list, fn -> {:error, :no_resumes} end)

      # Publisher is not mocked; it will try to publish. We only assert the handler return value.
      assert {:ok, {:created, listing}} = IngestHandler.handle_ingest(payload)
      assert listing["id"] == "new-id"
    end
  end
end
