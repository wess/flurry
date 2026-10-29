defmodule Flurry.Schema.LfsObject do
  use Ecto.Schema
  @primary_key false

  schema "lfs_objects" do
    field(:repository_id, Ecto.UUID, primary_key: true)
    field(:oid, :string, primary_key: true)
    field(:size, :integer)
    field(:uploaded_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.LfsLock do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "lfs_locks" do
    field(:repository_id, Ecto.UUID)
    field(:owner_id, Ecto.UUID)
    field(:path, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
