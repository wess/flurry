defmodule Flurry.Schema.ReviewFindingEvent do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "review_finding_events" do
    field(:finding_id, Ecto.UUID)
    field(:actor_id, Ecto.UUID)
    field(:revision_id, :string)
    field(:action, :string)
    field(:note, :string, default: "")
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
