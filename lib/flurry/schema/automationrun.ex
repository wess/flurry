defmodule Flurry.Schema.AutomationRun do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "automation_runs" do
    field(:repository_id, Ecto.UUID)
    field(:changeset_id, :string)
    field(:actor_id, Ecto.UUID)
    field(:name, :string)
    field(:version, :string)
    field(:trigger, :string)
    field(:base_revision, :string)
    field(:external_id, :string)
    field(:idempotency_key, :string)
    field(:metadata, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
