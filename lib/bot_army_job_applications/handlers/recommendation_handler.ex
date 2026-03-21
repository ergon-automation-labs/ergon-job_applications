defmodule BotArmyJobApplications.Handlers.RecommendationHandler do
  @moduledoc """
  Handles job listing recommendation requests.

  Two-phase workflow:
  1. Synchronous tag-overlap pre-filter (reply immediately with top 20 results)
  2. Async LLM semantic scoring (update listings in background, publish GTD inbox items for high scores)

  Subscribes to:
  - job.listings.recommend — Trigger recommendations (TUI or scheduled)
  - events.llm.completion with source_domain="job_recommendation" — LLM scoring results
  """

  require Logger

  alias BotArmyJobApplications.{
    RecommendationScorer,
    ListingStore,
    ResumeStore,
    NATS.Publisher
  }

  @doc """
  Handle recommend request from TUI or scheduler.

  Payload:
  ```json
  {
    "resume_id": "uuid",  // optional, defaults to first resume
    "limit": 20           // optional, defaults to 20
  }
  ```

  Synchronously returns tag-scored results immediately,
  then fires async LLM requests for each result.
  """
  def handle_recommend(message, reply_to, conn) when is_map(message) and is_binary(reply_to) and is_binary(reply_to) do
    payload = message["payload"] || %{}

    resume_id = Map.get(payload, "resume_id")
    limit = Map.get(payload, "limit", 20)

    case validate_recommend_payload(payload) do
      :ok ->
        case get_default_resume(resume_id) do
          {:ok, resume} ->
            case listing_store().list([]) do
              {:ok, listings} ->
                # Synchronous: tag overlap scoring
                scored_pairs = RecommendationScorer.shortlist(listings, resume, limit)
                recommendations = Enum.map(scored_pairs, fn {listing, score} ->
                  %{
                    "listing" => listing,
                    "score" => (score * 100) |> Float.round(0) |> trunc(),
                    "reason" => "Tag match"
                  }
                end)

                # Reply immediately with tag-scored results
                reply_body = Jason.encode!(%{
                  "ok" => true,
                  "recommendations" => recommendations,
                  "total_scored" => length(recommendations)
                })

                if conn do
                  Gnat.pub(conn, reply_to, reply_body)
                end

                Logger.info("Sent recommendations: #{length(recommendations)} scored (tag overlap), LLM enrichment in background")

                # Asynchronously: fire LLM requests for each shortlist item
                fire_async_llm_requests(scored_pairs, resume)

              {:error, reason} ->
                Logger.error("Failed to fetch listings: #{inspect(reason)}")
                reply_error(conn, reply_to, "Failed to fetch listings")
            end

          {:error, reason} ->
            Logger.error("Failed to fetch resume: #{inspect(reason)}")
            reply_error(conn, reply_to, "Resume not found")
        end

      {:error, reason} ->
        Logger.warning("Invalid recommend request: #{inspect(reason)}")
        reply_error(conn, reply_to, "Invalid request")
    end
  end

  def handle_recommend(_, _, _), do: :ok

  @doc """
  Handle LLM scoring response.

  Extracts listing_id and resume_id from source_metadata,
  parses score + reason, updates listing, pushes to GTD if >= 0.80.
  """
  def handle_llm_score_response(message) when is_map(message) do
    source_metadata = message["source_metadata"] || %{}
    listing_id = source_metadata["listing_id"]
    resume_id = source_metadata["resume_id"]
    payload = message["payload"] || %{}

    case RecommendationScorer.parse_llm_score_response(payload["text"] || "") do
      {:ok, score, reason} ->
        Logger.info("LLM scored listing #{listing_id} (resume: #{resume_id}): #{(score * 100) |> trunc()}%")

        # Update listing with score + reason
        case listing_store().update(listing_id, %{
          "recommendation_score" => score,
          "recommendation_reason" => reason,
          "scored_at" => NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()
        }) do
          {:ok, listing} ->
            Logger.info("Updated listing #{listing_id} with recommendation score: #{(score * 100) |> trunc()}%")

            # If score >= 0.80 and not yet pushed to GTD, push it (if GTD integration enabled)
            if Application.get_env(:bot_army_job_applications, :enable_gtd_integration, true) do
              if score >= 0.80 and not (listing["gtd_pushed"] || false) do
                publish_gtd_inbox_item(listing, score, reason, resume_id)
                # Mark as pushed
                listing_store().update(listing_id, %{"gtd_pushed" => true})
              end
            end

            # Publish event
            publish_recommendation_scored(listing, score, reason)

          {:error, reason} ->
            Logger.error("Failed to update listing #{listing_id}: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("Failed to parse LLM score response: #{inspect(reason)}")
    end
  end

  def handle_llm_score_response(_), do: :ok

  @doc """
  Auto-score a newly ingested listing.

  Fired from IngestHandler after successful listing creation.
  Gets default resume and fires async LLM scoring request.
  """
  def score_listing_async(listing) when is_map(listing) do
    case get_default_resume(nil) do
      {:ok, resume} ->
        listing_id = listing["id"]
        resume_id = resume["id"]

        prompt = RecommendationScorer.build_llm_prompt(listing, resume)

        Logger.info("Firing async LLM recommendation request for listing #{listing_id}")

        Publisher.publish_llm_request_with_metadata(
          %{"text" => prompt},
          "job_recommendation",
          nil,
          %{
            "listing_id" => listing_id,
            "resume_id" => resume_id
          }
        )

      {:error, reason} ->
        Logger.warning("Could not auto-score listing: #{inspect(reason)}")
    end
  end

  def score_listing_async(_), do: :ok

  # Private helpers

  defp validate_recommend_payload(payload) when is_map(payload) do
    # All fields optional
    :ok
  end

  defp validate_recommend_payload(_), do: {:error, "payload must be a map"}

  defp get_default_resume(resume_id) when is_binary(resume_id) do
    resume_store().get(resume_id)
  end

  defp get_default_resume(_) do
    case resume_store().list() do
      {:ok, resumes} when is_list(resumes) and length(resumes) > 0 ->
        # Return first resume (already a map from store)
        {:ok, List.first(resumes)}

      {:ok, _} ->
        {:error, :no_resumes}

      error ->
        error
    end
  end

  defp fire_async_llm_requests(scored_pairs, resume) do
    Enum.each(scored_pairs, fn {listing, _score} ->
      listing_id = listing["id"]
      resume_id = resume["id"]
      prompt = RecommendationScorer.build_llm_prompt(listing, resume)

      Publisher.publish_llm_request_with_metadata(
        %{"text" => prompt},
        "job_recommendation",
        nil,
        %{
          "listing_id" => listing_id,
          "resume_id" => resume_id
        }
      )
    end)
  end

  defp reply_error(conn, reply_to, message) do
    response = Jason.encode!(%{"ok" => false, "error" => message})
    if conn, do: Gnat.pub(conn, reply_to, response)
  end

  defp publish_gtd_inbox_item(listing, score, reason, resume_id) do
    company = listing["company"]
    role = listing["role_title"]
    score_percent = (score * 100) |> Float.round(0) |> trunc()

    message = "Job match: #{company} — #{role} (#{score_percent}% match). #{reason}"

    event = %{
      "event" => "gtd.inbox.add",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "job_applications.recommendation",
      "schema_version" => "1.0",
      "payload" => %{
        "item" => message,
        "source_domain" => "job_recommendation",
        "source_metadata" => %{
          "listing_id" => listing["id"],
          "resume_id" => resume_id,
          "company" => company,
          "role" => role,
          "score" => score
        }
      }
    }

    Publisher.publish(event)
  end

  defp publish_recommendation_scored(listing, score, reason) do
    event = %{
      "event" => "job.listing.recommendation_scored",
      "event_id" => UUID.uuid4() |> to_string(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_job_applications",
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => "job_applications.recommendation",
      "schema_version" => "1.0",
      "payload" => %{
        "listing_id" => listing["id"],
        "score" => score,
        "reason" => reason
      }
    }

    Publisher.publish(event)
  end

  defp listing_store do
    Application.get_env(:bot_army_job_applications, :listing_store, ListingStore)
  end

  defp resume_store do
    Application.get_env(:bot_army_job_applications, :resume_store, ResumeStore)
  end
end
