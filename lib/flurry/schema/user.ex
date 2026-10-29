defmodule Flurry.Schema.User do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "users" do
    field(:name, :string)
    field(:username, :string)
    field(:bio, :string, default: "")
    field(:location, :string, default: "")
    field(:website, :string, default: "")
    field(:email, :string)
    field(:email_verified_at, :utc_datetime_usec)
    field(:password, :string)
    field(:account_type, :string, default: "human")
    field(:admin, :boolean, default: false)
    field(:storage_migrated, :boolean, default: false)
    field(:disabled, :boolean, default: false)
    field(:private_profile, :boolean, default: false)
    field(:hide_activity, :boolean, default: false)
    field(:preferences, :map, default: %{})
    field(:totp_secret, :binary)
    field(:totp_pending, :binary)
    field(:totp_expires, :utc_datetime_usec)
    field(:totp_last, :integer)
    field(:recovery_codes, {:array, :string}, default: [])
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
