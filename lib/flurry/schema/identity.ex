defmodule Flurry.Schema.EmailToken do
  use Ecto.Schema
  @primary_key {:digest, :string, autogenerate: false}

  schema "email_tokens" do
    field(:user_id, Ecto.UUID)
    field(:purpose, :string)
    field(:expires_at, :utc_datetime_usec)
    field(:consumed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Flurry.Schema.MailDelivery do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "mail_deliveries" do
    field(:user_id, Ecto.UUID)
    field(:recipient, :string)
    field(:subject, :string)
    field(:body, :string)
    field(:kind, :string)
    field(:status, :string)
    field(:attempts, :integer)
    field(:error, :string)
    field(:delivered_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.Notification do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "notifications" do
    field(:user_id, Ecto.UUID)
    field(:actor_id, Ecto.UUID)
    field(:repository_id, Ecto.UUID)
    field(:kind, :string)
    field(:title, :string)
    field(:body, :string)
    field(:url, :string)
    field(:data, :map)
    field(:read_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
