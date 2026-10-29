defmodule Flurry.Schema.CommitStatus do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "commit_statuses" do
    field(:repository_id, Ecto.UUID)
    field(:changeset_id, :string)
    field(:creator_id, Ecto.UUID)
    field(:context, :string)
    field(:state, :string)
    field(:description, :string, default: "")
    field(:target_url, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
