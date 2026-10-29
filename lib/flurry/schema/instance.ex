defmodule Flurry.Schema.Instance do
  use Ecto.Schema
  @primary_key {:id, :integer, autogenerate: false}
  schema "instance" do
    field(:owner_id, Ecto.UUID)
    field(:name, :string, default: "Flurry")
    field(:registration, :boolean, default: true)
    field(:require_signin, :boolean, default: false)
    field(:allow_public, :boolean, default: true)
    field(:default_visibility, :string, default: "private")
    field(:file_bytes, :integer, default: 104_857_600)
    field(:project_storage_bytes, :integer, default: 107_374_182_400)
    field(:account_storage_bytes, :integer, default: 1_099_511_627_776)

    field(:git_hosts, {:array, :string}, default: ["git.example.com"])
  end
end
