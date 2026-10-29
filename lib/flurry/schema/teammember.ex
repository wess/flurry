defmodule Flurry.Schema.TeamMember do
  use Ecto.Schema

  schema "teammembers" do
    field(:team_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:role, :string, default: "member")
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
