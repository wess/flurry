defmodule Flurry.Engine.Collaboration do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Engine.Repositories

  alias Flurry.Schema.{
    Issue,
    IssueComment,
    Label,
    Milestone,
    Release,
    ReleaseAsset,
    User,
    WikiPage
  }

  alias Flurry.Store.Objects

  def labels(repository),
    do:
      Repo.all(from(l in Label, where: l.repository_id == ^repository.id, order_by: l.name))
      |> Enum.map(&label_public/1)

  def create_label(repository, attrs) do
    name = Auth.text!(attrs["name"], "Label name", 50)
    color = String.downcase(Auth.text!(attrs["color"], "Label color", 6))

    unless Regex.match?(~r/\A[0-9a-f]{6}\z/, color),
      do: Error.fail("Label color must be six hexadecimal characters")

    %Label{}
    |> Ecto.Changeset.change(
      id: Ecto.UUID.generate(),
      repository_id: repository.id,
      name: name,
      color: color,
      description: text(attrs["description"], 200)
    )
    |> Ecto.Changeset.unique_constraint(:name)
    |> insert!("A label with this name already exists")
    |> label_public()
  end

  def milestones(repository),
    do:
      Repo.all(
        from(m in Milestone,
          where: m.repository_id == ^repository.id,
          order_by: [asc: m.state, asc: m.due_at, asc: m.title]
        )
      )
      |> Enum.map(&milestone_public/1)

  def create_milestone(repository, user, attrs) do
    %Milestone{}
    |> Ecto.Changeset.change(
      id: Ecto.UUID.generate(),
      repository_id: repository.id,
      creator_id: user.id,
      title: Auth.text!(attrs["title"], "Milestone title", 120),
      description: text(attrs["description"], 10_000),
      due_at: datetime(attrs["due_at"])
    )
    |> Repo.insert!()
    |> milestone_public()
  end

  def issues(repository, params \\ %{}) do
    state = params["state"] || "open"

    unless state in ["open", "closed", "all"],
      do: Error.fail("Choose open, closed, or all issues")

    query =
      from(i in Issue,
        where: i.repository_id == ^repository.id,
        order_by: [desc: i.updated_at, desc: i.number]
      )

    Repo.all(if state == "all", do: query, else: from(i in query, where: i.state == ^state))
    |> Enum.map(&issue_public(repository, &1))
  end

  def issue(repository, number) do
    parsed = integer!(number, "Issue number")

    item =
      Repo.get_by(Issue, repository_id: repository.id, number: parsed) ||
        Error.fail("Issue not found", 404)

    issue_public(repository, item) |> Map.put(:comments, comments(item))
  end

  def create_issue(repository, user, attrs) do
    Repositories.writable!(repository)

    {:ok, item} =
      Repo.transaction(fn ->
        Repositories.lock(repository)

        number =
          (Repo.one(
             from(i in Issue, where: i.repository_id == ^repository.id, select: max(i.number))
           ) || 0) + 1

        item =
          %Issue{}
          |> Ecto.Changeset.change(
            id: Ecto.UUID.generate(),
            repository_id: repository.id,
            number: number,
            author_id: user.id,
            title: Auth.text!(attrs["title"], "Issue title", 200),
            body: text(attrs["body"], 100_000),
            assignee_id: assignee(repository, attrs["assignee"]),
            milestone_id: milestone(repository, attrs["milestone_id"])
          )
          |> Repo.insert!()

        set_labels(repository, item, attrs["label_ids"] || [])
        item
      end)

    if item.assignee_id do
      Flurry.Engine.Notifications.notify(item.assignee_id, "issue.assigned", "Issue assigned",
        actor: user,
        repository: repository,
        body: item.title,
        url: "/repositories/#{repository.id}/issues/#{item.number}"
      )
    end

    issue_public(repository, item)
  end

  def update_issue(repository, number, attrs) do
    item = issue_record(repository, number)

    if item.locked and Map.has_key?(attrs, "body"),
      do: Error.fail("This discussion is locked", 409)

    state = Map.get(attrs, "state", item.state)
    unless state in ["open", "closed"], do: Error.fail("Choose open or closed")
    locked = Map.get(attrs, "locked", item.locked)
    unless is_boolean(locked), do: Error.fail("Locked must be true or false")

    item =
      item
      |> Ecto.Changeset.change(
        title:
          if(Map.has_key?(attrs, "title"),
            do: Auth.text!(attrs["title"], "Issue title", 200),
            else: item.title
          ),
        body: if(Map.has_key?(attrs, "body"), do: text(attrs["body"], 100_000), else: item.body),
        state: state,
        locked: locked,
        assignee_id:
          if(Map.has_key?(attrs, "assignee"),
            do: assignee(repository, attrs["assignee"]),
            else: item.assignee_id
          ),
        milestone_id:
          if(Map.has_key?(attrs, "milestone_id"),
            do: milestone(repository, attrs["milestone_id"]),
            else: item.milestone_id
          )
      )
      |> Repo.update!()

    if Map.has_key?(attrs, "label_ids"), do: set_labels(repository, item, attrs["label_ids"])
    issue_public(repository, item)
  end

  def comment(repository, number, user, attrs) do
    item = issue_record(repository, number)
    if item.locked, do: Error.fail("This discussion is locked", 409)

    comment =
      %IssueComment{}
      |> Ecto.Changeset.change(
        id: Ecto.UUID.generate(),
        issue_id: item.id,
        author_id: user.id,
        body: Auth.text!(attrs["body"], "Comment", 100_000)
      )
      |> Repo.insert!()
      |> comment_public()

    recipients = [item.author_id, item.assignee_id] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Enum.each(recipients, fn recipient ->
      Flurry.Engine.Notifications.notify(recipient, "issue.comment", "New issue comment",
        actor: user,
        repository: repository,
        body: String.slice(comment.body, 0, 500),
        url: "/repositories/#{repository.id}/issues/#{item.number}"
      )
    end)

    comment
  end

  def releases(repository, include_drafts \\ false) do
    query =
      from(r in Release,
        where: r.repository_id == ^repository.id,
        order_by: [desc: r.inserted_at]
      )

    Repo.all(if include_drafts, do: query, else: from(r in query, where: not r.draft))
    |> Enum.map(&release_public/1)
  end

  def create_release(repository, user, attrs) do
    tag = Auth.text!(attrs["tag"], "Release tag", 200)

    unless Repo.exists?(
             from(t in "tags",
               where: t.repository_id == ^Ecto.UUID.dump!(repository.id) and t.name == ^tag
             )
           ),
           do: Error.fail("Release tag not found", 404)

    %Release{}
    |> Ecto.Changeset.change(
      id: Ecto.UUID.generate(),
      repository_id: repository.id,
      creator_id: user.id,
      tag: tag,
      title: Auth.text!(attrs["title"], "Release title", 200),
      notes: text(attrs["notes"], 100_000),
      draft: boolean(attrs["draft"], false),
      prerelease: boolean(attrs["prerelease"], false)
    )
    |> Ecto.Changeset.unique_constraint(:tag)
    |> insert!("A release for this tag already exists")
    |> release_public()
  end

  def add_asset(repository, release_id, attrs) do
    release = release!(repository, release_id)

    data =
      case Base.decode64(attrs["content"] || "") do
        {:ok, value} -> value
        :error -> Error.fail("Asset content must be base64")
      end

    if byte_size(data) > 25_000_000, do: Error.fail("Release assets may be at most 25 MB", 413)
    name = Auth.text!(attrs["name"], "Asset name", 200)

    if String.contains?(name, ["/", "\\"]),
      do: Error.fail("Asset name cannot contain path separators")

    object = Objects.put(:blob, data)

    %ReleaseAsset{}
    |> Ecto.Changeset.change(
      id: Ecto.UUID.generate(),
      release_id: release.id,
      name: name,
      content_type: text(attrs["content_type"] || "application/octet-stream", 200),
      object: object,
      bytes: byte_size(data)
    )
    |> Ecto.Changeset.unique_constraint(:name)
    |> insert!("An asset with this name already exists")
    |> asset_public()
  end

  def asset(repository, asset_id) do
    asset =
      Repo.one(
        from(a in ReleaseAsset,
          join: r in Release,
          on: r.id == a.release_id,
          where: r.repository_id == ^repository.id and a.id == ^asset_id,
          select: a
        )
      ) || Error.fail("Release asset not found", 404)

    {asset_public(asset), Objects.get(:blob, asset.object)}
  end

  def wiki(repository),
    do:
      Repo.all(from(w in WikiPage, where: w.repository_id == ^repository.id, order_by: w.slug))
      |> Enum.map(&wiki_public/1)

  def wiki_page(repository, slug),
    do:
      (Repo.get_by(WikiPage, repository_id: repository.id, slug: slug) ||
         Error.fail("Wiki page not found", 404))
      |> wiki_public()

  def put_wiki(repository, user, slug, attrs) do
    valid_slug!(slug)
    current = Repo.get_by(WikiPage, repository_id: repository.id, slug: slug)
    expected = attrs["version"]

    if current && expected != current.version,
      do: Error.fail("Wiki page changed; reload before saving", 409)

    values = [
      editor_id: user.id,
      title: Auth.text!(attrs["title"], "Page title", 200),
      body: text(attrs["body"], 250_000),
      version: if(current, do: current.version + 1, else: 1)
    ]

    result =
      if current,
        do: current |> Ecto.Changeset.change(values) |> Repo.update!(),
        else:
          %WikiPage{}
          |> Ecto.Changeset.change(
            [id: Ecto.UUID.generate(), repository_id: repository.id, slug: slug] ++ values
          )
          |> Repo.insert!()

    wiki_public(result)
  end

  def topics(repository),
    do:
      Repo.all(
        from(t in "repository_topics",
          where: t.repository_id == ^Ecto.UUID.dump!(repository.id),
          order_by: t.topic,
          select: t.topic
        )
      )

  def put_topics(repository, values) when is_list(values) do
    topics =
      values |> Enum.map(&(&1 |> Auth.text!("Topic", 35) |> String.downcase())) |> Enum.uniq()

    unless length(topics) <= 20 and
             Enum.all?(topics, &Regex.match?(~r/\A[a-z0-9][a-z0-9-]*\z/, &1)),
           do: Error.fail("Use up to 20 lowercase topic names")

    Repo.transaction(fn ->
      Repo.delete_all(
        from(t in "repository_topics", where: t.repository_id == ^Ecto.UUID.dump!(repository.id))
      )

      Repo.insert_all(
        "repository_topics",
        Enum.map(topics, &%{repository_id: Ecto.UUID.dump!(repository.id), topic: &1})
      )
    end)

    topics
  end

  def put_topics(_, _), do: Error.fail("Topics must be a list")

  def subscribe(repository, user, kind, enabled)
      when kind in ["star", "watch"] and is_boolean(enabled) do
    key = [
      repository_id: Ecto.UUID.dump!(repository.id),
      user_id: Ecto.UUID.dump!(user.id),
      kind: kind
    ]

    if enabled,
      do:
        Repo.insert_all(
          "repository_subscriptions",
          [Map.new(key) |> Map.put(:inserted_at, DateTime.utc_now())],
          on_conflict: :nothing
        ),
      else:
        Repo.delete_all(
          from(s in "repository_subscriptions",
            where:
              s.repository_id == ^key[:repository_id] and s.user_id == ^key[:user_id] and
                s.kind == ^kind
          )
        )

    %{
      kind: kind,
      enabled: enabled,
      count:
        Repo.aggregate(
          from(s in "repository_subscriptions",
            where: s.repository_id == ^key[:repository_id] and s.kind == ^kind
          ),
          :count
        )
    }
  end

  defp issue_record(repository, number),
    do:
      Repo.get_by(Issue, repository_id: repository.id, number: integer!(number, "Issue number")) ||
        Error.fail("Issue not found", 404)

  defp issue_public(repository, item),
    do:
      Map.merge(
        Map.take(item, [
          :id,
          :number,
          :title,
          :body,
          :state,
          :locked,
          :assignee_id,
          :milestone_id,
          :inserted_at,
          :updated_at
        ]),
        %{
          labels: issue_labels(item),
          author: user_public(item.author_id),
          repository_id: repository.id
        }
      )

  defp issue_labels(item),
    do:
      Repo.all(
        from(l in Label,
          join: x in "issue_labels",
          on: x.label_id == l.id,
          where: x.issue_id == ^Ecto.UUID.dump!(item.id),
          order_by: l.name
        )
      )

  defp comments(item),
    do:
      Repo.all(from(c in IssueComment, where: c.issue_id == ^item.id, order_by: c.inserted_at))
      |> Enum.map(&comment_public/1)

  defp comment_public(comment),
    do:
      Map.merge(Map.take(comment, [:id, :body, :inserted_at, :updated_at]), %{
        author: user_public(comment.author_id)
      })

  defp user_public(id), do: Repo.get!(User, id) |> Map.take([:id, :username, :name])

  defp set_labels(repository, item, ids) when is_list(ids) do
    labels = Repo.all(from(l in Label, where: l.repository_id == ^repository.id and l.id in ^ids))

    if length(labels) != length(Enum.uniq(ids)),
      do: Error.fail("One or more labels do not belong to this repository")

    Repo.delete_all(from(x in "issue_labels", where: x.issue_id == ^Ecto.UUID.dump!(item.id)))

    Repo.insert_all(
      "issue_labels",
      Enum.map(labels, &%{issue_id: Ecto.UUID.dump!(item.id), label_id: Ecto.UUID.dump!(&1.id)})
    )
  end

  defp set_labels(_, _, _), do: Error.fail("Label identifiers must be a list")
  defp assignee(_, nil), do: nil

  defp assignee(repository, username) do
    user =
      Repo.get_by(User, username: Auth.text!(username, "Assignee", 40)) ||
        Error.fail("Assignee not found", 404)

    unless Repositories.permitted?(repository, user, :read),
      do: Error.fail("Assignee does not have repository access")

    user.id
  end

  defp milestone(_, nil), do: nil

  defp milestone(repository, id),
    do:
      (Repo.get_by(Milestone, id: id, repository_id: repository.id) ||
         Error.fail("Milestone not found", 404)).id

  defp release!(repository, id),
    do:
      Repo.get_by(Release, id: id, repository_id: repository.id) ||
        Error.fail("Release not found", 404)

  defp release_public(release),
    do:
      Map.put(
        Map.take(release, [
          :id,
          :tag,
          :title,
          :notes,
          :draft,
          :prerelease,
          :inserted_at,
          :updated_at
        ]),
        :assets,
        Repo.all(from(a in ReleaseAsset, where: a.release_id == ^release.id, order_by: a.name))
        |> Enum.map(&Map.take(&1, [:id, :name, :content_type, :bytes, :inserted_at]))
      )

  defp label_public(label),
    do: Map.take(label, [:id, :name, :color, :description])

  defp milestone_public(milestone),
    do: Map.take(milestone, [:id, :title, :description, :state, :due_at, :inserted_at])

  defp wiki_public(page),
    do: Map.take(page, [:id, :slug, :title, :body, :version, :inserted_at, :updated_at])

  defp asset_public(asset),
    do: Map.take(asset, [:id, :name, :content_type, :object, :bytes, :inserted_at])

  defp valid_slug!(slug) when is_binary(slug) do
    unless Regex.match?(~r/\A[a-z0-9][a-z0-9-]{0,99}\z/, slug),
      do: Error.fail("Wiki slugs use lowercase letters, numbers, and hyphens")
  end

  defp valid_slug!(_), do: Error.fail("Invalid wiki slug")
  defp text(nil, _), do: ""

  defp text(value, max) when is_binary(value) do
    if String.valid?(value) and byte_size(value) <= max,
      do: value,
      else: Error.fail("Text is too long or invalid")
  end

  defp text(_, _), do: Error.fail("Text must be a string")
  defp boolean(nil, default), do: default
  defp boolean(value, _) when is_boolean(value), do: value
  defp boolean(_, _), do: Error.fail("Expected true or false")
  defp datetime(nil), do: nil

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, date, _} -> date
      _ -> Error.fail("Date must use ISO 8601")
    end
  end

  defp datetime(_), do: Error.fail("Date must use ISO 8601")
  defp integer!(value, _label) when is_integer(value), do: value

  defp integer!(value, label) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> Error.fail("#{label} is invalid")
    end
  end

  defp insert!(changeset, message) do
    case Repo.insert(changeset) do
      {:ok, record} -> record
      {:error, _} -> Error.fail(message, 409)
    end
  end
end
