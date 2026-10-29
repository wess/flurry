defmodule Flurry.Schema.ReviewDecision do
  use Ecto.Schema
  @primary_key false
  schema "review_decisions" do
    field(:review_id, Ecto.UUID, primary_key: true)
    field(:user_id, Ecto.UUID, primary_key: true)
    field(:revision_id, :string)
    field(:decision, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
