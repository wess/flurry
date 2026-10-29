defmodule Flurry.Schema.Passkey do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "passkeys" do
    field(:user_id, Ecto.UUID)
    field(:credential_id, :binary)
    field(:public_key, :binary)
    field(:name, :string)
    field(:sign_count, :integer, default: 0)
    field(:aaguid, :binary)
    field(:transports, {:array, :string}, default: [])
    field(:backed_up, :boolean, default: false)
    field(:last_used_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.PasskeyChallenge do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "passkey_challenges" do
    field(:user_id, Ecto.UUID)
    field(:kind, :string)
    field(:bytes, :binary)
    field(:origin, :string)
    field(:rp_id, :string)
    field(:issued_at, :integer)
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
