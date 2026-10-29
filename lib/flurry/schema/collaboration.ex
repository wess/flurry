defmodule Flurry.Schema.Label do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "labels" do
    field(:repository_id, Ecto.UUID)
    field(:name, :string)
    field(:color, :string)
    field(:description, :string)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.Milestone do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "milestones" do
    field(:repository_id, Ecto.UUID)
    field(:creator_id, Ecto.UUID)
    field(:title, :string)
    field(:description, :string)
    field(:state, :string)
    field(:due_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.Issue do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "issues" do
    field(:repository_id, Ecto.UUID)
    field(:number, :integer)
    field(:author_id, Ecto.UUID)
    field(:assignee_id, Ecto.UUID)
    field(:milestone_id, Ecto.UUID)
    field(:title, :string)
    field(:body, :string)
    field(:state, :string)
    field(:locked, :boolean)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.IssueComment do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "issue_comments" do
    field(:issue_id, Ecto.UUID)
    field(:author_id, Ecto.UUID)
    field(:body, :string)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.Release do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "releases" do
    field(:repository_id, Ecto.UUID)
    field(:creator_id, Ecto.UUID)
    field(:tag, :string)
    field(:title, :string)
    field(:notes, :string)
    field(:draft, :boolean)
    field(:prerelease, :boolean)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.ReleaseAsset do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "release_assets" do
    field(:release_id, Ecto.UUID)
    field(:name, :string)
    field(:content_type, :string)
    field(:object, :string)
    field(:bytes, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Flurry.Schema.WikiPage do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "wiki_pages" do
    field(:repository_id, Ecto.UUID)
    field(:editor_id, Ecto.UUID)
    field(:slug, :string)
    field(:title, :string)
    field(:body, :string)
    field(:version, :integer)
    timestamps(type: :utc_datetime_usec)
  end
end
