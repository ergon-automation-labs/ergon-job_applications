defmodule BotArmyJobApplications.Ingestion.LeverFetcher do
  @moduledoc """
  Fetches job listings from Lever Postings API.

  API: GET https://api.lever.co/v0/postings/{site}?mode=json
  No auth required. Site is the company slug (e.g. "lever", "leverdemo").
  """

  @base_url "https://api.lever.co/v0/postings"

  @doc """
  Fetch all jobs from a Lever site (paginated).

  Returns `{:ok, [%{...}]}` with listing payloads, or `{:error, reason}`.
  """
  def fetch_jobs(site, opts \\ []) when is_binary(site) do
    company_name = Keyword.get(opts, :company_name, title_case(site))
    fetch_page(site, company_name, 0, 100, [])
  end

  defp fetch_page(site, company_name, skip, limit, acc) do
    url = "#{@base_url}/#{URI.encode(site)}?mode=json&skip=#{skip}&limit=#{limit}"

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} ->
        jobs = body || []
        batch = Enum.map(jobs, &to_listing_payload(&1, site, company_name))
        new_acc = acc ++ batch

        if length(jobs) < limit do
          {:ok, new_acc}
        else
          fetch_page(site, company_name, skip + limit, limit, new_acc)
        end

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_listing_payload(posting, site, company_name) do
    jd_text = posting["descriptionPlain"] || posting["descriptionBodyPlain"] || posting["openingPlain"] || ""

    salary_range =
      case posting["salaryRange"] do
        %{"min" => min, "max" => max} when is_number(min) and is_number(max) ->
          %{"min" => round(min), "max" => round(max), "currency" => posting["salaryRange"]["currency"], "interval" => posting["salaryRange"]["interval"]}

        _ ->
          nil
      end

    %{
      "source" => "lever",
      "source_url" => "https://jobs.lever.co/#{site}",
      "company" => company_name,
      "role_title" => posting["text"] || "Unknown",
      "jd_url" => posting["hostedUrl"],
      "jd_text" => jd_text,
      "salary_range" => salary_range,
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
