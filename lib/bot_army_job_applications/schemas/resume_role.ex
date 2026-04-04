defmodule BotArmyJobApplications.Schemas.ResumeRole do
  @moduledoc """
  Ecto schema for resume roles.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "resume_roles" do
    field :resume_id, :string
    field :title, :string
    field :company, :string
    field :start_date, :date
    field :end_date, :date
    field :framing_profiles, :map
    field :sort_order, :integer, default: 0

    field :tenant_id, :binary_id
    field :user_id, :binary_id
    timestamps()
  end

  @doc false
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:resume_id, :title, :company, :start_date, :end_date, :framing_profiles, :sort_order, :tenant_id, :user_id])
    |> validate_required([:resume_id, :title, :company])
  end
end
