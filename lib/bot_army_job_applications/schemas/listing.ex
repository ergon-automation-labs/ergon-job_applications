defmodule BotArmyJobApplications.Schemas.Listing do
  @moduledoc """
  Ecto schema for job listings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "listings" do
    field :source, :string
    field :source_url, :string
    field :company, :string
    field :role_title, :string
    field :jd_text, :string
    field :jd_url, :string
    field :jd_tags, :map
    field :salary_range, :map
    field :location, :map
    field :coverage_score, :float
    field :status, :string
    field :discovered_at, :naive_datetime
    field :scored_at, :naive_datetime
    field :dedup_hash, :string
    field :recommendation_score, :float
    field :recommendation_reason, :string
    field :gtd_pushed, :boolean, default: false

    timestamps()
  end

  @doc false
  def changeset(listing, attrs) do
    listing
    |> cast(attrs, [
      :source,
      :source_url,
      :company,
      :role_title,
      :jd_text,
      :jd_url,
      :jd_tags,
      :salary_range,
      :location,
      :coverage_score,
      :status,
      :discovered_at,
      :scored_at,
      :dedup_hash,
      :recommendation_score,
      :recommendation_reason,
      :gtd_pushed
    ])
    |> validate_required([:company, :role_title])
  end
end
