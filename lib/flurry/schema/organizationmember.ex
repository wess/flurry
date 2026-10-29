defmodule Flurry.Schema.OrganizationMember do
  use Ecto.Schema

  schema "organizationmembers" do
    field(:organization_id, Ecto.UUID)
    field(:user_id, Ecto.UUID)
    field(:role, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
