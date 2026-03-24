defmodule BotArmyJobApplications.Schemas.Application do
  @moduledoc """
  Ecto schema for job applications.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "applications" do
    field :listing_id, :string
    field :company, :string
    field :role_title, :string
    field :jd_url, :string
    field :jd_text, :string
    field :jd_tags, :map
    field :coverage_score, :float
    field :salary_range, :map
    field :strategy, :string
    field :state, :string
    field :history, {:array, :map}
    field :pending_signal, :map
    field :next_action, :string
    field :artifacts, :map

    timestamps()
  end

  @doc false
  def changeset(application, attrs) do
    application
    |> cast(attrs, [
      :listing_id,
      :company,
      :role_title,
      :jd_url,
      :jd_text,
      :jd_tags,
      :coverage_score,
      :salary_range,
      :strategy,
      :state,
      :history,
      :pending_signal,
      :next_action,
      :artifacts
    ])
    |> validate_required([:company, :role_title, :state])
  end
end
