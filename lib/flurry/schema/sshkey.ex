defmodule Flurry.Schema.SshKey do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "sshkeys" do
    field(:user_id, Ecto.UUID)
    field(:title, :string)
    field(:public_key, :string)
    field(:fingerprint, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
