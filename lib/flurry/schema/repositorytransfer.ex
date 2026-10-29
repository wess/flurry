defmodule Flurry.Schema.RepositoryTransfer do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "repository_transfers" do
    field(:repository_id, Ecto.UUID)
    field(:sender_id, Ecto.UUID)
    field(:target_user_id, Ecto.UUID)
    field(:target_organization_id, Ecto.UUID)
    field(:status, :string)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
