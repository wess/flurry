defmodule Flurry.Schema.EvaluationRun do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "evaluation_runs" do
    field(:repository_id, Ecto.UUID)
    field(:changeset_id, :string)
    field(:creator_id, Ecto.UUID)
    field(:context, :string)
    field(:state, :string)
    field(:summary, :string, default: "")
    field(:score, :float)
    field(:pass_count, :integer, default: 0)
    field(:fail_count, :integer, default: 0)
    field(:duration_ms, :integer)
    field(:metrics, :map, default: %{})
    field(:target_url, :string)
    field(:external_id, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
