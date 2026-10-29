defmodule Flurry.Schema.Snippet do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "snippets" do
    field(:author_id, Ecto.UUID)
    field(:slug, :string)
    field(:title, :string)
    field(:description, :string, default: "")
    field(:visibility, :string, default: "unlisted")
    field(:version, :integer, default: 1)
    field(:forked_from_id, Ecto.UUID)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule Flurry.Schema.SnippetRevision do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "snippet_revisions" do
    field(:snippet_id, Ecto.UUID)
    field(:author_id, Ecto.UUID)
    field(:version, :integer)
    field(:message, :string, default: "")
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Flurry.Schema.SnippetFile do
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}

  schema "snippet_files" do
    field(:revision_id, Ecto.UUID)
    field(:name, :string)
    field(:content, :string)
    field(:bytes, :integer)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

defmodule Flurry.Schema.SnippetStar do
  use Ecto.Schema
  @primary_key false

  schema "snippet_stars" do
    field(:snippet_id, Ecto.UUID, primary_key: true)
    field(:user_id, Ecto.UUID, primary_key: true)
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
