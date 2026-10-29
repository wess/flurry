defmodule Flurry.Schema.Codeowner do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "codeowners" do
    field(:repository_id, Ecto.UUID)
    field(:pattern, :string)
    field(:user_id, Ecto.UUID)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
