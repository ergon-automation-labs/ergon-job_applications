defmodule BotArmyJobApplications.Ingestion.DedupTest do
  use ExUnit.Case, async: true
  @moduletag :ingestion

  alias BotArmyJobApplications.Ingestion.Dedup

  describe "dedup_hash/3" do
    test "same inputs produce same hash" do
      h1 =
        Dedup.dedup_hash(
          "Stripe",
          "Senior Engineer",
          "https://boards.greenhouse.io/stripe/jobs/123"
        )

      h2 =
        Dedup.dedup_hash(
          "Stripe",
          "Senior Engineer",
          "https://boards.greenhouse.io/stripe/jobs/123"
        )

      assert h1 == h2
      assert is_binary(h1)
      assert String.length(h1) == 64
    end

    test "different company produces different hash" do
      h1 = Dedup.dedup_hash("Stripe", "Senior Engineer", "https://example.com/job/1")
      h2 = Dedup.dedup_hash("Lever", "Senior Engineer", "https://example.com/job/1")
      assert h1 != h2
    end

    test "different role produces different hash" do
      h1 = Dedup.dedup_hash("Stripe", "Senior Engineer", "https://example.com/job/1")
      h2 = Dedup.dedup_hash("Stripe", "Staff Engineer", "https://example.com/job/1")
      assert h1 != h2
    end

    test "normalizes company and role (case, whitespace)" do
      h1 = Dedup.dedup_hash("  STRIPE  ", "  Senior   Engineer  ", "https://x.com/1")
      h2 = Dedup.dedup_hash("stripe", "senior engineer", "https://x.com/1")
      assert h1 == h2
    end

    test "normalizes URL (trailing slash, fragment, query)" do
      h1 = Dedup.dedup_hash("Co", "Role", "https://boards.greenhouse.io/co/jobs/1")
      h2 = Dedup.dedup_hash("Co", "Role", "https://boards.greenhouse.io/co/jobs/1/")
      h3 = Dedup.dedup_hash("Co", "Role", "https://boards.greenhouse.io/co/jobs/1?foo=bar")
      h4 = Dedup.dedup_hash("Co", "Role", "https://boards.greenhouse.io/co/jobs/1#section")
      assert h1 == h2
      assert h1 == h3
      assert h1 == h4
    end

    test "nil or empty URL is handled" do
      h1 = Dedup.dedup_hash("Co", "Role", nil)
      h2 = Dedup.dedup_hash("Co", "Role", "")
      assert h1 == h2
    end
  end
end
