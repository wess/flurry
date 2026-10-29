defmodule Flurry.Schema.Webhook do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "webhooks" do
    field(:repository_id, Ecto.UUID)
    field(:creator_id, Ecto.UUID)
    field(:url, :string)
    field(:secret, :binary)
    field(:events, {:array, :string}, default: [])
    field(:enabled, :boolean, default: true)
    timestamps(type: :utc_datetime_usec)
  end
end
