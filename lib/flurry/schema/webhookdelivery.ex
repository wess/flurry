defmodule Flurry.Schema.WebhookDelivery do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "webhook_deliveries" do
    field(:webhook_id, Ecto.UUID)
    field(:repository_id, Ecto.UUID)
    field(:event, :string)
    field(:payload, :map)
    field(:state, :string, default: "pending")
    field(:attempt, :integer, default: 0)
    field(:next_attempt_at, :utc_datetime_usec)
    field(:status, :integer)
    field(:response, :string)
    field(:error, :string)
    field(:signature, :string)
    timestamps(type: :utc_datetime_usec)
  end
end
