defmodule Flurry.Schema.Changeset do
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "changesets" do
    field(:merge_parent_id, :string)
    field(:repository_id, Ecto.UUID)
    field(:parent_id, :string)
    field(:source_id, :string)
    field(:author_id, Ecto.UUID)
    field(:message, :string)
    field(:changes, :map)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
