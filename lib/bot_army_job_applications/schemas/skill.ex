defmodule BotArmyJobApplications.Schemas.Skill do
  @moduledoc """
  Ecto schema for skills.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "skills" do
    field :resume_id, :string
    field :name, :string
    field :tags, :map
    field :proficiency, :string
    field :years, :integer

    field :tenant_id, :binary_id
    field :user_id, :binary_id
    timestamps()
  end

  @doc false
  def changeset(skill, attrs) do
    skill
    |> cast(attrs, [:resume_id, :name, :tags, :proficiency, :years, :tenant_id, :user_id])
    |> validate_required([:resume_id, :name])
  end
end
