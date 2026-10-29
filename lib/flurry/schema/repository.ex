defmodule Flurry.Schema.Repository do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "repositories" do
    field(:name, :string)
    field(:description, :string, default: "")
    field(:visibility, :string, default: "private")
    field(:owner_id, Ecto.UUID)
    field(:organization_id, Ecto.UUID)
    field(:fork_of_id, Ecto.UUID)
    field(:archived, :boolean, default: false)
    field(:deleted_at, :utc_datetime_usec)
    field(:allow_self_approval, :boolean, default: true)
    field(:required_approvals, :integer, default: 1)
    field(:required_statuses, {:array, :string}, default: [])
    field(:protected_paths, {:array, :string}, default: [])
    field(:push_allowlist, {:array, Ecto.UUID}, default: [])
    field(:require_signed_commits, :boolean, default: false)
    field(:review_trigger, :string, default: "manual")
    field(:review_profiles, {:array, :string}, default: ["correctness", "security"])
    field(:review_status_context, :string)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
