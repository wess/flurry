defmodule Flurry.Schema.ReviewFinding do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "review_findings" do
    field(:repository_id, Ecto.UUID)
    field(:review_id, Ecto.UUID)
    field(:run_id, Ecto.UUID)
    field(:revision_id, :string)
    field(:reporter_id, Ecto.UUID)
    field(:fingerprint, :string)
    field(:category, :string)
    field(:severity, :string)
    field(:classification, :string, default: "introduced")
    field(:title, :string)
    field(:body, :string)
    field(:evidence, :string, default: "")
    field(:path, :string)
    field(:side, :string)
    field(:line, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
