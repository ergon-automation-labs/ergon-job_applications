defmodule BotArmyJobApplications.Handlers.IngestHandler do
  @moduledoc """
  Handles raw job listing ingestion: deduplicates and stores new listings,
  publishes job.listings.new for each new listing.
  """

  require Logger

  @doc """
  Process a single raw listing (from scrapers or manual entry).

  Payload must include: company, role_title, jd_url (or source_url), and optionally
  jd_text, source, source_url, salary_range, discovered_at.

  - If dedup_hash already exists → skip (idempotent).
  - If new → insert, then publish events.job.listings.new.
  """
  def handle_ingest(message) when is_map(message) do
    %{tenant_id: tenant_id, user_id: user_id} = BotArmyCore.Tenant.extract_context(message)
    payload = message["payload"] || %{}
    store = listing_store()
    company = payload["company"] || payload["company_name"]
    role_title = payload["role_title"] || payload["title"]
    jd_url = payload["jd_url"] || payload["source_url"] || payload["url"]

    if blank?(company) or blank?(role_title) do
      Logger.warning("Ingest skipped: missing company or role_title")
      {:error, :missing_required}
    else
      dedup_hash = BotArmyJobApplications.Ingestion.Dedup.dedup_hash(company, role_title, jd_url)

      case store.get_by_dedup_hash(tenant_id, dedup_hash) do
        {:ok, _existing} ->
          Logger.debug("Ingest skipped: duplicate listing #{dedup_hash}")
          {:ok, :duplicate}

        {:error, :not_found} ->
          attrs = build_listing_attrs(payload, dedup_hash, tenant_id, user_id)

          case store.create(attrs) do
            {:ok, listing} ->
              publish_listing_new(listing, tenant_id, user_id)
              # Fire async LLM recommendation scoring
              BotArmyJobApplications.Handlers.RecommendationHandler.score_listing_async(listing, tenant_id)
              {:ok, {:created, listing}}

            {:error, reason} ->
              Logger.error("Ingest failed to create listing: #{inspect(reason)}")
              {:error, reason}
          end
      end
    end
  end

  def handle_ingest(_), do: {:error, :invalid_payload}

  defp build_listing_attrs(payload, dedup_hash, tenant_id, user_id) do
    now_iso = NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()

    %{
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "source" => payload["source"] || "manual",
      "source_url" => payload["source_url"],
      "company" => payload["company"] || payload["company_name"],
      "role_title" => payload["role_title"] || payload["title"],
      "jd_text" => payload["jd_text"],
      "jd_url" => payload["jd_url"] || payload["source_url"] || payload["url"],
      "jd_tags" => payload["jd_tags"],
      "salary_range" => payload["salary_range"],
      "coverage_score" => payload["coverage_score"],
      "status" => payload["status"] || "new",
      "discovered_at" => payload["discovered_at"] || now_iso,
      "scored_at" => payload["scored_at"],
      "dedup_hash" => dedup_hash
    }
  end

  defp publish_listing_new(listing, tenant_id, user_id) do
    event = %{
      "event" => "job.listings.new",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "job_applications.ingest",
      "schema_version" => "1.0",
      "tenant_id" => tenant_id,
      "user_id" => user_id,
      "payload" => listing
    }

    BotArmyJobApplications.NATS.Publisher.publish(event)
  end

  defp listing_store do
    Application.get_env(:bot_army_job_applications, :listing_store, BotArmyJobApplications.ListingStore)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(s) when is_binary(s), do: String.trim(s) == ""
  defp blank?(_), do: false
end
