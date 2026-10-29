defmodule Flurry.Schema.Organization do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "organizations" do
    field(:name, :string)
    field(:slug, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
