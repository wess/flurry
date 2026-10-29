defmodule Flurry.Schema.Comment do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "comments" do
    field(:review_id, Ecto.UUID)
    field(:author_id, Ecto.UUID)
    field(:body, :string)
    field(:revision_id, :string)
    field(:path, :string)
    field(:side, :string)
    field(:line, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
