defmodule Flurry.Schema.ReviewRun do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "review_runs" do
    field(:repository_id, Ecto.UUID)
    field(:review_id, Ecto.UUID)
    field(:revision_id, :string)
    field(:creator_id, Ecto.UUID)
    field(:trigger, :string)
    field(:profiles, {:array, :string}, default: [])
    field(:state, :string, default: "requested")
    field(:summary, :string, default: "")
    field(:status_context, :string)
    field(:external_id, :string)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end
