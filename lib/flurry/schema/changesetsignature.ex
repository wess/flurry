defmodule Flurry.Schema.ChangesetSignature do
  use Ecto.Schema
  @primary_key {:changeset_id, :string, autogenerate: false}

  schema "changeset_signatures" do
    field(:key_id, Ecto.UUID)
    field(:payload_digest, :string)
    field(:signature, :binary)
    field(:inserted_at, :utc_datetime_usec)
  end
end
