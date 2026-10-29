defmodule Flurry.Schema.Team do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "teams" do
    field(:organization_id, Ecto.UUID)
    field(:name, :string)
    field(:slug, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
