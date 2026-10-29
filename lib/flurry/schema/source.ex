defmodule Flurry.Schema.Source do
  use Ecto.Schema
  @primary_key {:repository_id, Ecto.UUID, autogenerate: false}
  schema "sources" do
    field(:url, :string)
    field(:branch, :string)
    field(:status, :string, default: "ready")
    field(:operation, :string)
    field(:job, Ecto.UUID)
    field(:requested_head, :string)
    field(:error, :string)
    field(:message, :string)
    field(:commit, :string)
    field(:root, :string)
    field(:modes, :map, default: %{})
    field(:review_id, Ecto.UUID)
    field(:incoming_commit, :string)
    field(:incoming_root, :string)
    field(:incoming_modes, :map)
    field(:push_commit, :string)
    field(:push_root, :string)
    field(:push_modes, :map)
    field(:synced_at, :utc_datetime_usec)
    field(:source_connection_id, Ecto.UUID)
    timestamps(type: :utc_datetime_usec)
  end
end
