defmodule BotArmyJobApplications.Ingestion.GreenhouseFetcher do
  @moduledoc """
  Fetches job listings from Greenhouse Job Board API.

  API: GET https://boards-api.greenhouse.io/v1/boards/{board_token}/jobs?content=true
  No auth required for reading. Board token is the company slug (e.g. "stripe", "vaulttec").
  """

  @base_url "https://boards-api.greenhouse.io/v1/boards"

  @doc """
  Fetch all jobs from a Greenhouse board.

  Returns `{:ok, [%{...}]}` with raw job maps, or `{:error, reason}`.
  """
  def fetch_jobs(board_token, opts \\ []) when is_binary(board_token) do
    company_name = Keyword.get(opts, :company_name, title_case(board_token))
    url = "#{@base_url}/#{URI.encode(board_token)}/jobs?content=true"

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        jobs = body["jobs"] || []
        normalized = Enum.map(jobs, &to_listing_payload(&1, board_token, company_name))
        {:ok, normalized}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_listing_payload(job, board_token, company_name) do
    location_name = get_in(job, ["location", "name"])
    role_suffix = if location_name && location_name != "", do: " (#{location_name})", else: ""
    role_title = (job["title"] || "Unknown") <> role_suffix

    %{
      "source" => "greenhouse",
      "source_url" => "https://boards.greenhouse.io/#{board_token}",
      "company" => company_name,
      "role_title" => role_title,
      "jd_url" => job["absolute_url"],
      "jd_text" => job["content"] || "",
      "salary_range" => nil,
      "discovered_at" => NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()
    }
  end

  defp title_case(s) when is_binary(s) do
    s
    |> String.replace("-", " ")
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end
end
