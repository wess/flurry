defmodule Flurry.Schema.ReviewRequest do
  use Ecto.Schema
  @primary_key false
  schema "review_requests" do
    field(:review_id, Ecto.UUID, primary_key: true)
    field(:user_id, Ecto.UUID, primary_key: true)
    field(:requested_by, Ecto.UUID)
    field(:revision_id, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
