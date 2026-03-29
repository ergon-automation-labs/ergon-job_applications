defmodule Mix.Tasks.JobApplications.SyncBoardsToSalt do
  @moduledoc """
  Discovers active job boards and syncs them to bot_army_infra Salt pillar.

  This task:
  1. Discovers active boards using the same logic as discover_boards
  2. Generates YAML format for Salt pillar
  3. Updates bot_army_infra/salt/pillar/job_applications.sls
  4. Creates a git commit with the changes

  Usage:
    mix job_applications.sync_boards_to_salt
    mix job_applications.sync_boards_to_salt --dry-run
    mix job_applications.sync_boards_to_salt --no-commit
  """

  use Mix.Task
  require Logger

  @default_timeout_ms 5000
  @connect_timeout_ms 3000

  @companies %{
    "ai" => [
      {"Anthropic", "anthropic", "greenhouse"},
      {"Hugging Face", "huggingface", "greenhouse"},
      {"Scale AI", "scale", "greenhouse"},
      {"Together AI", "togetherai", "greenhouse"},
      {"Replicate", "replicate", "greenhouse"},
      {"CoreWeave", "coreweave", "greenhouse"},
      {"Lightning AI", "lightning", "greenhouse"},
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
    ]
  }

  @impl true
  def run(args) do
    {opts, _} = OptionParser.parse!(args, switches: [
      categories: :string,
      "dry-run": :boolean,
      "no-commit": :boolean
    ])

    dry_run = Keyword.get(opts, :"dry-run", false)
    commit = !Keyword.get(opts, :"no-commit", false)

    categories =
      case Keyword.get(opts, :categories) do
        nil -> Map.keys(@companies)
        cats -> String.split(cats, ",") |> Enum.map(&String.trim/1)
      end

    Mix.shell().info("🔍 Discovering job boards...\n")

    companies =
      categories
      |> Enum.flat_map(fn cat -> @companies[cat] || [] end)

    results = discover_boards(companies)

    {ok, err} = Enum.split_with(results, fn {_name, _slug, _source, status} ->
      match?({:ok, _}, status)
    end)

    if Enum.any?(ok) do
      Mix.shell().info("✅ Found #{length(ok)} active board(s)\n")
    end

    if Enum.any?(err) do
      Mix.shell().info("⚠️  #{length(err)} boards unavailable (will skip)\n")
    end

    # Extract just the board info (name, slug, source) from results
    boards = Enum.map(ok, fn {name, slug, source, _status} -> {name, slug, source} end)

    # Generate YAML and update pillar
    yaml_content = generate_yaml_pillar(boards)

    if dry_run do
      Mix.shell().info("📋 DRY RUN - Would write to Salt pillar:\n")
      Mix.shell().info(yaml_content)
    else
      salt_file = find_salt_pillar_file()

      if salt_file && File.exists?(salt_file) do
        File.write!(salt_file, yaml_content)
        Mix.shell().info("✅ Updated: #{salt_file}\n")

        if commit do
          commit_changes(salt_file, length(ok))
        else
          Mix.shell().info("ℹ️  Use --commit flag to auto-commit changes\n")
        end
      else
        Mix.shell().info("⚠️  Salt pillar not found. Expected at:")
        Mix.shell().info("   ../bot_army_infra/salt/pillar/job_applications.sls")
        Mix.shell().info("\n📋 Here's the YAML to add manually:\n")
        Mix.shell().info(yaml_content)
      end
    end

    :ok
  end

  defp discover_boards(companies) do
    Enum.map(companies, fn {name, slug, source} ->
      Mix.shell().info("  Checking #{name}...")
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

    # Ensure inets is started (only once per task)
    case :inets.start() do
      {:ok, _} -> :ok
      {:error, {:already_started, :inets}} -> :ok
      {:error, e} -> throw(e)
    end

    # Use connect_timeout + timeout for more reliable handling
    http_options = [
      timeout: @default_timeout_ms,
      connect_timeout: @connect_timeout_ms
    ]

    # Add sync and body_format options
    options = [
      {:sync, true},
      {:body_format, :binary}
    ]

    case :httpc.request(:get, {url_str, []}, http_options, options) do
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

  defp generate_yaml_pillar(boards) do
    board_list = Enum.map_join(boards, "\n", fn {name, slug, source} ->
      case source do
        "greenhouse" ->
          "    - source: greenhouse\n      board_token: #{slug}\n      company_name: #{name}"
        "lever" ->
          "    - source: lever\n      site: #{slug}\n      company_name: #{name}"
      end
    end)

    """
    # Auto-generated by: mix job_applications.sync_boards_to_salt
    # Last updated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    bot_army:
      job_applications:
        ingestion_interval_ms: 21600000  # 6 hours
        ingestion_boards:
    #{board_list}
    """
  end

  defp find_salt_pillar_file do
    # Try multiple possible locations
    paths = [
      "../bot_army_infra/salt/pillar/job_applications.sls",
      "../../bot_army_infra/salt/pillar/job_applications.sls",
      "/Users/abby/code/bot_army_infra/salt/pillar/job_applications.sls",
    ]

    Enum.find(paths, &File.exists?/1)
  end

  defp commit_changes(file, board_count) do

    case System.cmd("git", ["status", "--porcelain"], cd: Path.dirname(file)) do
      {output, 0} ->
        if String.contains?(output, "job_applications.sls") do
          case System.cmd("git", ["add", "salt/pillar/job_applications.sls"], cd: Path.dirname(file)) do
            {_, 0} ->
              msg = """
              Update ingestion_boards: #{board_count} active job boards

              Auto-discovered and synced via mix job_applications.sync_boards_to_salt
              Includes boards from Greenhouse and Lever APIs
              """

              case System.cmd("git", ["commit", "-m", msg], cd: Path.dirname(file)) do
                {_, 0} ->
                  Mix.shell().info("✅ Committed changes to bot_army_infra\n")
                  Mix.shell().info("💡 Next: cd ../bot_army_infra && git push origin main\n")

                {err, _} ->
                  Mix.shell().error("⚠️  Commit failed: #{err}\n")
              end

            {err, _} ->
              Mix.shell().error("⚠️  Git add failed: #{err}\n")
          end
        else
          Mix.shell().info("ℹ️  No changes to commit\n")
        end

      {err, _} ->
        Mix.shell().error("⚠️  Git status failed: #{err}\n")
    end
  end
end
