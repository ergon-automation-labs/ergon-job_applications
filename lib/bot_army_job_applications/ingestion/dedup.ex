defmodule BotArmyJobApplications.Ingestion.Dedup do
  @moduledoc """
  Deduplication for job listings by company + role_title + normalized URL.

  Same job posted on multiple boards (e.g. Greenhouse and LinkedIn) can be
  normalized to a single canonical key so we only store one listing.
  """

  @doc """
  Compute a stable hash for deduplication.

  Normalizes: company and role_title (lowercase, strip), URL (lowercase, strip
  trailing slash, strip fragment and optional query for comparison).
  """
  def dedup_hash(company, role_title, url) when is_binary(company) and is_binary(role_title) do
    norm_company = normalize_string(company)
    norm_role = normalize_string(role_title)
    norm_url = normalize_url(url || "")
    payload = "#{norm_company}|#{norm_role}|#{norm_url}"
    :crypto.hash(:sha256, payload) |> Base.encode16(case: :lower)
  end

  def dedup_hash(company, role_title, _url), do: dedup_hash(company, role_title, "")

  defp normalize_string(s) when is_binary(s) do
    s
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_string(_), do: ""

  defp normalize_url(""), do: ""
  defp normalize_url(url) when is_binary(url) do
    url
    |> String.downcase()
    |> String.trim()
    |> String.replace(~r/#.*$/, "")  # strip fragment
    |> String.replace(~r/\?.*$/, "") # strip query for dedup (same job page)
    |> String.replace_suffix("/", "")
  end
  defp normalize_url(_), do: ""
end
