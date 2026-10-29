defmodule Flurry.Schema.SubmissionReceipt do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "submission_receipts" do
    field(:repository_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:key, :string)
    field(:fingerprint, :string)
    field(:changeset_id, :string)
    field(:review_id, Ecto.UUID)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
