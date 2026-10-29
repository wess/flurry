defmodule Flurry.Schema.Review do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "reviews" do
    field(:series, :boolean, default: false)
    field(:base_id, :string)
    field(:repository_id, Ecto.UUID)
    field(:changeset_id, :string)
    field(:status, :string, default: "open")
    field(:landed_id, :string)
    field(:approved_by, Ecto.UUID)
    timestamps(type: :utc_datetime_usec)
  end
end
