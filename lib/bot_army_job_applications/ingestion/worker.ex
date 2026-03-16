defmodule BotArmyJobApplications.Ingestion.Worker do
  @moduledoc """
  Periodically fetches job listings from configured Greenhouse and Lever boards,
  publishes each to job.listings.ingest for dedup and storage.
  """

  use GenServer
  require Logger

  @default_interval_ms 6 * 60 * 60 * 1000  # 6 hours

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Trigger a fetch run now (e.g. from NATS job.listings.fetch.request).
  """
  def run_fetch do
    GenServer.cast(__MODULE__, :fetch)
  end

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms) ||
                  Application.get_env(:bot_army_job_applications, :ingestion_interval_ms, @default_interval_ms)
    boards = get_boards()

    if interval_ms > 0 do
      Process.send_after(self(), :tick, interval_ms)
    end

    Logger.info("IngestionWorker started with #{length(boards)} board(s), interval=#{interval_ms}ms")
    {:ok, %{interval_ms: interval_ms, boards: boards}}
  end

  @impl true
  def handle_cast(:fetch, state) do
    _ = run_fetch_all(state.boards)
    {:noreply, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _ = run_fetch_all(state.boards)
    if state.interval_ms > 0 do
      Process.send_after(self(), :tick, state.interval_ms)
    end
    {:noreply, state}
  end

  defp run_fetch_all(boards) do
    Logger.info("Ingestion fetch starting for #{length(boards)} board(s)")

    results =
      Enum.map(boards, fn board ->
        fetch_board(board)
      end)

    created = results |> List.flatten() |> length()
    Logger.info("Ingestion fetch done: #{length(boards)} boards, #{created} listing(s) published for ingest")
    results
  end

  defp fetch_board(%{source: "greenhouse", board_token: token} = board) do
    company = Map.get(board, :company_name, token)
    case BotArmyJobApplications.Ingestion.GreenhouseFetcher.fetch_jobs(token, company_name: company) do
      {:ok, listings} ->
        Enum.each(listings, &BotArmyJobApplications.NATS.Publisher.publish_listing_ingest/1)
        listings

      {:error, reason} ->
        Logger.warning("Greenhouse fetch failed for #{token}: #{inspect(reason)}")
        []
    end
  end

  defp fetch_board(%{source: "lever", site: site} = board) do
    company = Map.get(board, :company_name, site)
    case BotArmyJobApplications.Ingestion.LeverFetcher.fetch_jobs(site, company_name: company) do
      {:ok, listings} ->
        Enum.each(listings, &BotArmyJobApplications.NATS.Publisher.publish_listing_ingest/1)
        listings

      {:error, reason} ->
        Logger.warning("Lever fetch failed for #{site}: #{inspect(reason)}")
        []
    end
  end

  defp fetch_board(other) do
    Logger.warning("Unknown board config: #{inspect(other)}")
    []
  end

  defp get_boards do
    Application.get_env(:bot_army_job_applications, :ingestion_boards, [])
    |> Enum.map(&normalize_board/1)
  end

  defp normalize_board(%{source: _} = b), do: b
  defp normalize_board(%{"source" => "greenhouse", "board_token" => token} = b) do
    %{source: "greenhouse", board_token: token, company_name: b["company_name"] || token}
  end
  defp normalize_board(%{"source" => "lever", "site" => site} = b) do
    %{source: "lever", site: site, company_name: b["company_name"] || site}
  end
  defp normalize_board(b), do: b
end
