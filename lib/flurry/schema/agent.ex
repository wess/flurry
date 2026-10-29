defmodule Flurry.Schema.Agent do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "agents" do
    field(:user_id, Ecto.UUID)
    field(:owner_id, Ecto.UUID)
    field(:digest, :string)
    field(:token_prefix, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:revoked_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
