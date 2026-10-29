defmodule Flurry.Schema.TeamRepository do
  use Ecto.Schema

  schema "teamrepositories" do
    field(:team_id, Ecto.UUID)
    field(:repository_id, Ecto.UUID)
    field(:role, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
