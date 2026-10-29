defmodule Flurry.Schema.SourceConnection do
  use Ecto.Schema

  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "source_connections" do
    field(:user_id, Ecto.UUID)
    field(:provider, :string)
    field(:host, :string)
    field(:account, :string)
    field(:access_token, :binary)
    field(:refresh_token, :binary)
    field(:expires_at, :utc_datetime_usec)
    field(:scopes, {:array, :string}, default: [])
    timestamps(type: :utc_datetime_usec)
  end
end
