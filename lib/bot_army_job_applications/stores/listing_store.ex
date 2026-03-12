defmodule BotArmyJobApplications.ListingStore do
  @moduledoc """
  Listing storage GenServer.

  Maintains an in-memory cache of job listings loaded from the database.
  Provides CRUD operations that update both cache and persistence layer.
  """

  use GenServer
  require Logger

  @server __MODULE__

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @server)
  end

  def create(payload) when is_map(payload) do
    GenServer.call(@server, {:create, payload})
  end

  def update(listing_id, payload) when is_binary(listing_id) and is_map(payload) do
    GenServer.call(@server, {:update, listing_id, payload})
  end

  def get(listing_id) when is_binary(listing_id) do
    GenServer.call(@server, {:get, listing_id})
  end

  def list(opts \\ []) do
    GenServer.call(@server, {:list, opts})
  end

  def clear do
    GenServer.call(@server, :clear)
  end

  @impl true
  def init(_opts) do
    Logger.info("ListingStore started")

    state = try do
      listings = BotArmyJobApplications.Repo.all(BotArmyJobApplications.Schemas.Listing)
      Enum.reduce(listings, %{}, fn listing, acc ->
        Map.put(acc, listing.id |> to_string(), schema_to_map(listing))
      end)
    rescue
      _ ->
        Logger.warning("Could not load listings from database. Starting with empty state.")
        %{}
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:create, payload}, _from, state) do
    listing_id = Ecto.UUID.generate()

    changeset = BotArmyJobApplications.Schemas.Listing.changeset(
      %BotArmyJobApplications.Schemas.Listing{id: listing_id},
      %{
        "source" => Map.get(payload, "source"),
        "source_url" => Map.get(payload, "source_url"),
        "company" => payload["company"],
        "role_title" => payload["role_title"],
        "jd_text" => Map.get(payload, "jd_text"),
        "jd_url" => Map.get(payload, "jd_url"),
        "jd_tags" => Map.get(payload, "jd_tags"),
        "salary_range" => Map.get(payload, "salary_range"),
        "coverage_score" => Map.get(payload, "coverage_score"),
        "status" => Map.get(payload, "status", "new"),
        "discovered_at" => Map.get(payload, "discovered_at"),
        "scored_at" => Map.get(payload, "scored_at"),
        "dedup_hash" => Map.get(payload, "dedup_hash")
      }
    )

    case BotArmyJobApplications.Repo.insert(changeset) do
      {:ok, db_listing} ->
        listing = schema_to_map(db_listing)
        new_state = Map.put(state, listing_id, listing)
        Logger.info("Created listing in database: #{listing_id}")
        {:reply, {:ok, listing}, new_state}

      {:error, changeset} ->
        Logger.error("Failed to create listing: #{inspect(changeset.errors)}")
        {:reply, {:error, :database_error}, state}
    end
  end

  @impl true
  def handle_call({:update, listing_id, payload}, _from, state) do
    case Map.get(state, listing_id) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _listing ->
        listing_uuid = Ecto.UUID.cast!(listing_id)
        db_listing = BotArmyJobApplications.Repo.get(BotArmyJobApplications.Schemas.Listing, listing_uuid)

        if db_listing do
          changeset = BotArmyJobApplications.Schemas.Listing.changeset(
            db_listing,
            %{
              "source" => Map.get(payload, "source", db_listing.source),
              "source_url" => Map.get(payload, "source_url", db_listing.source_url),
              "company" => Map.get(payload, "company", db_listing.company),
              "role_title" => Map.get(payload, "role_title", db_listing.role_title),
              "jd_text" => Map.get(payload, "jd_text", db_listing.jd_text),
              "jd_url" => Map.get(payload, "jd_url", db_listing.jd_url),
              "jd_tags" => Map.get(payload, "jd_tags", db_listing.jd_tags),
              "salary_range" => Map.get(payload, "salary_range", db_listing.salary_range),
              "coverage_score" => Map.get(payload, "coverage_score", db_listing.coverage_score),
              "status" => Map.get(payload, "status", db_listing.status),
              "discovered_at" => Map.get(payload, "discovered_at", db_listing.discovered_at),
              "scored_at" => Map.get(payload, "scored_at", db_listing.scored_at),
              "dedup_hash" => Map.get(payload, "dedup_hash", db_listing.dedup_hash)
            }
          )

          case BotArmyJobApplications.Repo.update(changeset) do
            {:ok, updated_db_listing} ->
              updated_listing = schema_to_map(updated_db_listing)
              new_state = Map.put(state, listing_id, updated_listing)
              Logger.info("Updated listing in database: #{listing_id}")
              {:reply, {:ok, updated_listing}, new_state}

            {:error, changeset} ->
              Logger.error("Failed to update listing: #{inspect(changeset.errors)}")
              {:reply, {:error, :database_error}, state}
          end
        else
          {:reply, {:error, :not_found}, state}
        end
    end
  end

  @impl true
  def handle_call({:get, listing_id}, _from, state) do
    case Map.get(state, listing_id) do
      nil -> {:reply, {:error, :not_found}, state}
      listing -> {:reply, {:ok, listing}, state}
    end
  end

  @impl true
  def handle_call({:list, opts}, _from, state) do
    listings = state |> Map.values()

    # Apply filters if provided
    filtered = case Keyword.get(opts, :status) do
      nil -> listings
      status -> Enum.filter(listings, &(&1["status"] == status))
    end

    {:reply, {:ok, filtered}, state}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    Logger.debug("Clearing all listings from database and state")
    BotArmyJobApplications.Repo.delete_all(BotArmyJobApplications.Schemas.Listing)
    {:reply, :ok, %{}}
  end

  defp schema_to_map(%BotArmyJobApplications.Schemas.Listing{} = listing) do
    %{
      "id" => listing.id |> to_string(),
      "source" => listing.source,
      "source_url" => listing.source_url,
      "company" => listing.company,
      "role_title" => listing.role_title,
      "jd_text" => listing.jd_text,
      "jd_url" => listing.jd_url,
      "jd_tags" => listing.jd_tags,
      "salary_range" => listing.salary_range,
      "coverage_score" => listing.coverage_score,
      "status" => listing.status,
      "discovered_at" => if(listing.discovered_at, do: listing.discovered_at |> NaiveDateTime.to_iso8601(), else: nil),
      "scored_at" => if(listing.scored_at, do: listing.scored_at |> NaiveDateTime.to_iso8601(), else: nil),
      "dedup_hash" => listing.dedup_hash,
      "created_at" => listing.inserted_at |> NaiveDateTime.to_iso8601(),
      "updated_at" => listing.updated_at |> NaiveDateTime.to_iso8601()
    }
  end
end
