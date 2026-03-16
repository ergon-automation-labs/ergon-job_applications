defmodule BotArmyJobApplications.Schemas.Resume do
  @moduledoc """
  Ecto schema for resumes.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @foreign_key_type Ecto.UUID

  schema "resumes" do
    field :identity, :map
    field :metadata, :map
    field :source_file_path, :string
    field :original_filename, :string

    timestamps()
  end

  @doc false
  def changeset(resume, attrs) do
    resume
    |> cast(attrs, [:identity, :metadata, :source_file_path, :original_filename])
    |> validate_required([:identity])
  end
end
