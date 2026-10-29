defmodule Flurry.Schema.DeployKey do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "deploykeys" do
    field(:repository_id, Ecto.UUID)
    field(:creator_id, Ecto.UUID)
    field(:title, :string)
    field(:public_key, :string)
    field(:fingerprint, :string)
    field(:write, :boolean, default: false)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
