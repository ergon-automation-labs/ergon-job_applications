defmodule Mix.Tasks.JobApplications.DiscoverBoards do
  @moduledoc """
  Discovers job boards on Greenhouse and Lever for a list of companies.

  Hits public APIs to verify boards exist, then generates a ready-to-use
  `ingestion_boards` config for deployment.

  Usage:
    mix job_applications.discover_boards
    mix job_applications.discover_boards --categories ai,devtools,infra
    mix job_applications.discover_boards --output config.exs
  """

  use Mix.Task
  require Logger

  @default_timeout_ms 5000

  # Curated companies by category
  @companies %{
    "ai" => [
      {"Anthropic", "anthropic", "greenhouse"},
      {"Hugging Face", "huggingface", "greenhouse"},
      {"Scale AI", "scale", "greenhouse"},
      {"Together AI", "togetherai", "greenhouse"},
      {"Replicate", "replicate", "greenhouse"},
      {"CoreWeave", "coreweave", "greenhouse"},
      {"Lightning AI", "lightning", "greenhouse"},
      {"Mistral AI", "mistral", "greenhouse"},
      {"Weights & Biases", "weightsandbiases", "greenhouse"},
    ],
    "devtools" => [
      {"Cursor", "cursor", "greenhouse"},
      {"Replit", "replit", "greenhouse"},
      {"JetBrains", "jetbrains", "lever"},
      {"Vercel", "vercel", "greenhouse"},
      {"Netlify", "netlify", "greenhouse"},
      {"Astro", "astro", "greenhouse"},
      {"Prisma", "prisma", "greenhouse"},
      {"Svelte", "svelte", "greenhouse"},
      {"Figma", "figma", "greenhouse"},
      {"Linear", "linear", "greenhouse"},
      {"Stripe", "stripe", "lever"},
      {"Twilio", "twilio", "greenhouse"},
      {"Auth0", "auth0", "greenhouse"},
      {"Segment", "segment", "greenhouse"},
    ],
    "infra" => [
      {"Cloudflare", "cloudflare", "greenhouse"},
      {"HashiCorp", "hashicorp", "lever"},
      {"Fly.io", "fly", "greenhouse"},
      {"Mux", "mux", "greenhouse"},
      {"Supabase", "supabase", "greenhouse"},
      {"PlanetScale", "planetscale", "greenhouse"},
      {"Railway", "railway", "greenhouse"},
      {"Wiz", "wiz", "greenhouse"},
      {"DigitalOcean", "digitalocean", "greenhouse"},
      {"Kong", "kong", "greenhouse"},
      {"Datadog", "datadog", "greenhouse"},
      {"Lacework", "lacework", "greenhouse"},
    ]
  }

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: [categories: :string, output: :string])

    categories =
      case Keyword.get(opts, :categories) do
        nil -> Map.keys(@companies)
        cats -> String.split(cats, ",") |> Enum.map(&String.trim/1)
      end

    output_file = Keyword.get(opts, :output)

    Mix.shell().info("🔍 Discovering job boards for: #{Enum.join(categories, ", ")}\n")

    companies =
      categories
      |> Enum.flat_map(fn cat -> @companies[cat] || [] end)

    results = discover_boards(companies)

    display_results(results)

    valid_boards = generate_config(results)

    if output_file do
      write_config(output_file, valid_boards)
    end

    :ok
  end

  defp discover_boards(companies) do
    Enum.map(companies, fn {name, slug, source} ->
      status = check_board(source, slug)
      {name, slug, source, status}
    end)
  end

  defp check_board("greenhouse", token) do
    url = "https://boards-api.greenhouse.io/v1/boards/#{URI.encode(token)}/jobs?content=false"
    http_get_json(url)
  end

  defp check_board("lever", site) do
    url = "https://api.lever.co/v0/postings/#{URI.encode(site)}?mode=json&limit=1"
    http_get_json(url)
  end

  defp http_get_json(url) do
    with {:ok, {_, _, body}} <- http_get(url),
         {:ok, data} <- Jason.decode(body) do
      cond do
        is_list(data) -> {:ok, "has_jobs"}
        is_map(data) && is_list(data["jobs"]) -> {:ok, length(data["jobs"])}
        true -> {:error, "no_jobs"}
      end
    else
      {:error, :not_found} -> {:error, "not_found"}
      {:error, :timeout} -> {:error, "timeout"}
      {:error, reason} -> {:error, inspect(reason)}
    end
  rescue
    e ->
      {:error, "exception: #{inspect(e)}"}
  end

  defp http_get(url) do
    url_str = String.to_charlist(url)
    # Start inets if not already started
    case :inets.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, :inets}} -> :ok
      {:error, e} -> throw(e)
    end

    case :httpc.request(:get, {url_str, []}, [timeout: @default_timeout_ms], []) do
      {:ok, {status_line, _headers, body}} ->
        {_, status_code, _} = status_line
        if status_code == 200 do
          {:ok, {status_line, [], body}}
        else
          {:error, status_code}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e ->
      {:error, inspect(e)}
  end

  defp display_results(results) do
    {ok, err} = Enum.split_with(results, fn {_name, _slug, _source, status} ->
      match?({:ok, _}, status)
    end)

    if Enum.any?(ok) do
      Mix.shell().info("✅ Found #{length(ok)} active board(s):\n")
      Enum.each(ok, fn {name, slug, source, {:ok, job_count}} ->
        count_str = if is_integer(job_count), do: "#{job_count} jobs", else: to_string(job_count)
        Mix.shell().info("  • #{name} (#{source}:#{slug}) — #{count_str}")
      end)
      Mix.shell().info("")
    end

    if Enum.any?(err) do
      Mix.shell().info("❌ Failed or unavailable (#{length(err)}):\n")
      Enum.each(err, fn {name, slug, source, {:error, reason}} ->
        Mix.shell().info("  • #{name} (#{source}:#{slug}) — #{reason}")
      end)
      Mix.shell().info("")
    end
  end

  defp generate_config(results) do
    results
    |> Enum.filter(fn {_name, _slug, _source, status} -> match?({:ok, _}, status) end)
    |> Enum.map(fn {name, slug, source, _status} ->
      case source do
        "greenhouse" ->
          %{
            "source" => "greenhouse",
            "board_token" => slug,
            "company_name" => name
          }
        "lever" ->
          %{
            "source" => "lever",
            "site" => slug,
            "company_name" => name
          }
      end
    end)
  end

  defp write_config(filename, boards) do
    content = """
    # Generated board configuration
    # Copy into your deployment config or Salt pillar

    ingestion_boards: [
    #{Enum.map_join(boards, ",\n", &format_board/1)}
    ]
    """

    File.write!(filename, content)
    Mix.shell().info("📝 Config written to #{filename}")
    Mix.shell().info("\n#{content}")
  end

  defp format_board(%{"source" => "greenhouse"} = board) do
    """
      %{
        "source" => "greenhouse",
        "board_token" => "#{board["board_token"]}",
        "company_name" => "#{board["company_name"]}"
      }
    """
  end

  defp format_board(%{"source" => "lever"} = board) do
    """
      %{
        "source" => "lever",
        "site" => "#{board["site"]}",
        "company_name" => "#{board["company_name"]}"
      }
    """
  end
end
