defmodule BotArmyJobApplications.Schemas.ResumeBullet do
  @moduledoc """
  Ecto schema for resume bullets.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "resume_bullets" do
    field :role_id, :string
    field :text, :string
    field :alt_phrasings, :map
    field :tags, :map
    field :metrics, :map
    field :strength, :string
    field :sort_order, :integer, default: 0

    field :tenant_id, :binary_id
    field :user_id, :binary_id
    timestamps()
  end

  @doc false
  def changeset(bullet, attrs) do
    bullet
    |> cast(attrs, [:role_id, :text, :alt_phrasings, :tags, :metrics, :strength, :sort_order, :tenant_id, :user_id])
    |> validate_required([:role_id, :text])
  end
end
