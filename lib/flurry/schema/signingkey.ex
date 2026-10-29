defmodule Flurry.Schema.SigningKey do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "signingkeys" do
    field(:user_id, Ecto.UUID)
    field(:title, :string)
    field(:algorithm, :string, default: "ed25519")
    field(:public_key, :binary)
    field(:fingerprint, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
