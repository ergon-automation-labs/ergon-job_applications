defmodule Mix.Tasks.JobApplications.ApplyFromListing do
  @shortdoc "Creates an application from an existing listing (by listing ID)"
  @moduledoc """
  Loads a listing from the database and creates a job application with the same
  company, role_title, jd_text, jd_url, etc. Use after ingestion to "apply" to a listing.

  Usage:
    mix job_applications.apply_from_listing LISTING_ID

  Requires app and database. Starts the ApplicationServer for the new application.
  To generate artifacts, send job.application.artifact.request with this application_id and a resume_id.
  """
  use Mix.Task

  @requirements ["app.config"]

  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [listing_id] ->
        apply_from_listing(listing_id)

      _ ->
        Mix.raise("Usage: mix job_applications.apply_from_listing LISTING_ID")
    end
  end

  defp apply_from_listing(listing_id) do
    listing_uuid = Ecto.UUID.cast(listing_id)

    case listing_uuid do
      :error ->
        Mix.raise("Invalid listing ID (must be UUID): #{listing_id}")

      {:ok, uuid} ->
        case BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Listing, uuid) do
          nil ->
            Mix.raise("Listing not found: #{listing_id}")

          listing ->
            payload = %{
              "company" => listing.company,
              "role_title" => listing.role_title,
              "jd_text" => listing.jd_text,
              "jd_url" => listing.jd_url,
              "listing_id" => listing_id,
              "salary_range" => listing.salary_range,
              "state" => "identified",
              "history" => [
                %{
                  "from_state" => nil,
                  "to_state" => "identified",
                  "transitioned_at" => NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second) |> NaiveDateTime.to_iso8601(),
                  "metadata" => %{"reason" => "apply_from_listing"}
                }
              ]
            }

            case application_store().create(payload) do
              {:ok, application} ->
                BotArmyJobApplications.ApplicationSupervisor.start_child(application["id"])
                IO.puts("Created application #{application["id"]} from listing #{listing_id}.")
                IO.puts("Trigger artifacts with: job.application.artifact.request payload application_id=#{application["id"]} resume_id=<your_resume_id>")

              {:error, reason} ->
                Mix.raise("Failed to create application: #{inspect(reason)}")
            end
        end
    end
  end

  defp application_store do
    Application.get_env(:bot_army_job_applications, :application_store, BotArmyJobApplications.ApplicationStore)
  end
end
