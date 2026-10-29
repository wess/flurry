defmodule Flurry.Engine.Reviews do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Schema.{Review, Comment, ReviewDecision, ReviewRequest, User}
  alias Flurry.Engine.{Automation, Changesets, Repositories, ReviewFindings, Symbols}
  alias Flurry.Store.Tree

  def list(repository) do
    Repo.all(
      from(r in Review,
        where: r.repository_id == ^repository.id,
        order_by: [desc: r.inserted_at],
        limit: 100
      )
    )
    |> Enum.map(&public/1)
  end

  def get(repository, id, lock \\ false) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Review not found", 404)
    query = from(r in Review, where: r.id == ^id and r.repository_id == ^repository.id)
    query = if lock, do: from(r in query, lock: "FOR UPDATE"), else: query
    Repo.one(query) || Error.fail("Review not found", 404)
  end

  def detail(repository, review) do
    changeset = Changesets.get(repository, review.changeset_id)

    comments =
      Repo.all(
        from(c in Comment,
          join: u in User,
          on: c.author_id == u.id,
          where: c.review_id == ^review.id,
          order_by: c.inserted_at,
          select: %{
            id: c.id,
            body: c.body,
            author: u.name,
            revision: c.revision_id,
            path: c.path,
            side: c.side,
            line: c.line,
            inserted_at: c.inserted_at
          }
        )
      )

    decisions =
      Repo.all(
        from(d in ReviewDecision,
          join: u in User,
          on: d.user_id == u.id,
          where: d.review_id == ^review.id,
          order_by: [asc: u.username],
          select: %{
            user: %{id: u.id, name: u.name, username: u.username},
            decision: d.decision,
            revision: d.revision_id,
            current: d.revision_id == ^review.changeset_id,
            updated_at: d.updated_at
          }
        )
      )

    requested =
      Repo.all(
        from(r in ReviewRequest,
          join: u in User,
          on: r.user_id == u.id,
          where: r.review_id == ^review.id,
          order_by: [asc: u.name, asc: u.username],
          select: %{
            user: %{id: u.id, name: u.name, username: u.username},
            revision: r.revision_id,
            current: r.revision_id == ^review.changeset_id,
            inserted_at: r.inserted_at
          }
        )
      )

    Map.merge(public(review), %{
      diff:
        Changesets.diff(
          repository,
          changeset,
          if(review.series, do: review.base_id, else: :parent)
        )
        |> Symbols.annotate(),
      comments: comments,
      decisions: decisions,
      requested_reviewers: requested,
      automation: Automation.provenance(repository, changeset.id),
      evaluations: Automation.evaluations(repository, changeset.id),
      review_intelligence: ReviewFindings.detail(repository, review)
    })
  end

  def approve(repository, id, actor \\ nil) do
    decide(repository, id, actor, "approve")
  end

  def reject(repository, id, actor \\ nil) do
    decide(repository, id, actor, "reject")
  end

  defp decide(repository, id, actor, decision) do
    actor = actor || Repo.get!(User, repository.owner_id)

    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        repository = Repositories.writable!(repository)

        unless Repositories.permitted?(repository, actor, :review),
          do: Error.fail("Maintainer access required", 403)

        review = get(repository, id, true)
        if review.status == "landed", do: Error.fail("This review has already landed", 409)
        change = Changesets.get(repository, review.changeset_id)

        if decision == "approve" and not repository.allow_self_approval and
             self_author?(repository, review, change, actor.id),
           do: Error.fail("Another maintainer must approve this change", 403)

        now = DateTime.utc_now()

        Repo.insert_all(
          ReviewDecision,
          [
            %{
              review_id: review.id,
              user_id: actor.id,
              revision_id: review.changeset_id,
              decision: decision,
              inserted_at: now,
              updated_at: now
            }
          ],
          on_conflict: [
            set: [revision_id: review.changeset_id, decision: decision, updated_at: now]
          ],
          conflict_target: [:review_id, :user_id]
        )

        review = refresh_status(repository, review)

        Flurry.Audit.record(actor, "review." <> decision, repository, %{review: review.id})

        Flurry.Engine.Webhooks.emit(repository, "review.decision", %{
          review_id: review.id,
          revision: review.changeset_id,
          decision: decision,
          user_id: actor.id
        })

        review
      end)

    result
  end

  def comment(repository, user, id, attrs) do
    Repositories.writable!(repository)
    review = get(repository, id)
    body = Auth.text!(attrs["body"], "Comment", 10_000)
    anchor = anchor!(repository, review, attrs)

    comment =
      Repo.insert!(
        struct!(Comment, %{
          id: Ecto.UUID.generate(),
          review_id: review.id,
          author_id: user.id,
          body: body,
          revision_id: anchor[:revision_id],
          path: anchor[:path],
          side: anchor[:side],
          line: anchor[:line]
        })
      )

    change = Changesets.get(repository, review.changeset_id)

    Flurry.Engine.Notifications.notify(change.author_id, "review.comment", "New review comment",
      actor: user,
      repository: repository,
      body: String.slice(comment.body, 0, 500),
      url: "/repositories/#{repository.id}/reviews/#{review.id}"
    )

    detail(repository, review)
  end

  def request_reviewers(repository, id, actor, user_ids) do
    unless is_list(user_ids) and length(user_ids) in 1..20,
      do: Error.fail("Request between 1 and 20 reviewers")

    ids = Enum.uniq(user_ids)
    unless length(ids) == length(user_ids), do: Error.fail("Duplicate requested reviewers")

    {:ok, {review, reviewers}} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)

        unless Repositories.permitted?(repository, actor, :write),
          do: Error.fail("Write access required", 403)

        review = get(repository, id, true)
        if review.status == "landed", do: Error.fail("This review has already landed", 409)

        reviewers =
          Enum.map(ids, fn user_id ->
            unless match?({:ok, _}, Ecto.UUID.cast(user_id)),
              do: Error.fail("Invalid reviewer")

            user = Repo.get(User, user_id) || Error.fail("Reviewer not found", 404)

            if user.disabled or not Repositories.permitted?(repository, user, :review),
              do: Error.fail("Requested reviewers must be active maintainers", 409)

            user
          end)

        now = DateTime.utc_now()

        rows =
          Enum.map(reviewers, fn reviewer ->
            %{
              review_id: review.id,
              user_id: reviewer.id,
              requested_by: actor.id,
              revision_id: review.changeset_id,
              inserted_at: now
            }
          end)

        Repo.insert_all(ReviewRequest, rows,
          on_conflict: [
            set: [requested_by: actor.id, revision_id: review.changeset_id, inserted_at: now]
          ],
          conflict_target: [:review_id, :user_id]
        )

        Flurry.Audit.record(actor, "review.request", repository, %{
          review: review.id,
          reviewers: ids
        })

        {review, reviewers}
      end)

    Enum.each(reviewers, fn reviewer ->
      Flurry.Engine.Notifications.notify(
        reviewer.id,
        "review.requested",
        "Review requested",
        actor: actor,
        repository: repository,
        url: "/repositories/#{repository.id}/reviews/#{review.id}"
      )
    end)

    detail(repository, review)
  end

  def revise(repository, id, actor, changeset_id) do
    change = Changesets.get(repository, changeset_id)

    {:ok, review} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        Repositories.writable!(repository)

        unless Repositories.permitted?(repository, actor, :write),
          do: Error.fail("Write access required", 403)

        review = get(repository, id, true)
        if review.status == "landed", do: Error.fail("This review has already landed", 409)

        review =
          review
          |> Ecto.Changeset.change(
            changeset_id: change.id,
            status: "open",
            approved_by: nil
          )
          |> Ecto.Changeset.unique_constraint(:changeset_id)
          |> Repo.update!()

        Flurry.Audit.record(actor, "review.revise", repository, %{
          review: review.id,
          changeset: change.id
        })

        review
      end)

    ReviewFindings.automatic(repository, review, actor, :revision)
    review
  end

  def land(repository, id, actor \\ nil) do
    actor = actor || Repo.get!(User, repository.owner_id)

    {:ok, result} =
      Repo.transaction(fn ->
        Repositories.lock(repository)
        repository = Repositories.writable!(repository)

        unless Repositories.permitted?(repository, actor, :review),
          do: Error.fail("Maintainer access required", 403)

        review = get(repository, id, true) |> then(&refresh_status(repository, &1))

        if review.status == "landed" do
          %{review: public(review), head: review.landed_id}
        else
          if review.status == "changes_requested",
            do: Error.fail("Resolve requested changes before landing", 409)

          unless review.status == "approved",
            do:
              Error.fail(
                "Approve this change with #{repository.required_approvals} current approvals before landing",
                409
              )

          change = Changesets.get(repository, review.changeset_id)
          Flurry.Engine.Policies.enforce_review!(repository, review, change)

          approvers =
            Repo.all(
              from(d in ReviewDecision,
                join: u in User,
                on: d.user_id == u.id,
                where:
                  d.review_id == ^review.id and d.revision_id == ^review.changeset_id and
                    d.decision == "approve",
                select: u
              )
            )

          unless length(approvers) >= repository.required_approvals and
                   Enum.all?(approvers, fn approver ->
                     not approver.disabled and
                       Repositories.permitted?(repository, approver, :review)
                   end),
                 do:
                   Error.fail(
                     "Approval is no longer valid; ask an active maintainer to approve again",
                     409
                   )

          if not repository.allow_self_approval and
               Enum.any?(approvers, &self_author?(repository, review, change, &1.id)),
             do: Error.fail("Another maintainer must approve this change", 409)

          ref =
            Repo.one!(
              from(r in "refs",
                where: r.repository_id == ^Ecto.UUID.dump!(repository.id) and r.name == "main",
                lock: "FOR UPDATE",
                select: %{id: r.id, head: r.head}
              )
            )

          base_id = if review.series, do: review.base_id, else: change.parent_id

          unless Changesets.ancestor?(repository, base_id, ref.head),
            do: Error.fail("The change is based on an unlanded revision", 409)

          base = Changesets.root(repository, base_id)

          changes =
            if review.series,
              do: Changesets.delta(base, Changesets.root(repository, change.id)),
              else: change.changes

          current = Changesets.root(repository, ref.head)

          conflicts =
            changes
            |> Map.keys()
            |> Enum.filter(fn path -> Tree.entry(base, path) != Tree.entry(current, path) end)

          if conflicts != [],
            do:
              Error.fail("Files changed on main since this change was submitted", 409, %{
                paths: conflicts
              })

          landed =
            if base_id == ref.head do
              change
            else
              root = Tree.apply(current, changes)

              Changesets.insert(
                repository,
                change.author_id,
                ref.head,
                change.id,
                change.message,
                changes,
                root,
                if(review.series, do: change.id, else: change.merge_parent_id)
              )
            end

          Repo.update_all(from(r in "refs", where: r.id == ^ref.id), set: [head: landed.id])

          review =
            review
            |> Ecto.Changeset.change(status: "landed", landed_id: landed.id)
            |> Repo.update!()

          Flurry.Engine.Sources.complete_review(review)
          Flurry.Audit.record(actor, "review.land", repository, %{changeset: landed.id})

          Flurry.Engine.Webhooks.emit(repository, "review.landed", %{
            review_id: review.id,
            revision: landed.id
          })

          %{review: public(review), head: landed.id}
        end
      end)

    result
  end

  defp self_author?(repository, %{series: true} = review, change, id) do
    base = Flurry.Engine.Graph.ancestors(repository, review.base_id)

    ids =
      Flurry.Engine.Graph.ancestors(repository, change.id)
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(base, &1))
      |> Enum.reject(&is_nil/1)

    Repo.exists?(from(c in Flurry.Schema.Changeset, where: c.id in ^ids and c.author_id == ^id))
  end

  defp self_author?(_, _, change, id), do: change.author_id == id

  def public(review) do
    changeset = Repo.get!(Flurry.Schema.Changeset, review.changeset_id)
    repository = Repo.get!(Flurry.Schema.Repository, review.repository_id)

    decisions =
      Repo.all(
        from(d in ReviewDecision,
          where: d.review_id == ^review.id and d.revision_id == ^review.changeset_id,
          select: d.decision
        )
      )

    %{
      id: review.id,
      status: review.status,
      changeset: Changesets.public(changeset),
      landed_id: review.landed_id,
      approvals: Enum.count(decisions, &(&1 == "approve")),
      rejections: Enum.count(decisions, &(&1 == "reject")),
      required_approvals: repository.required_approvals,
      inserted_at: review.inserted_at,
      updated_at: review.updated_at
    }
  end

  defp refresh_status(_repository, %{status: "landed"} = review), do: review

  defp refresh_status(repository, review) do
    decisions =
      Repo.all(
        from(d in ReviewDecision,
          where: d.review_id == ^review.id and d.revision_id == ^review.changeset_id,
          order_by: [desc: d.updated_at],
          select: {d.decision, d.user_id}
        )
      )

    approvals = for {"approve", user_id} <- decisions, do: user_id

    status =
      cond do
        Enum.any?(decisions, &match?({"reject", _}, &1)) -> "changes_requested"
        length(approvals) >= repository.required_approvals -> "approved"
        true -> "open"
      end

    approved_by = List.first(approvals)

    if review.status == status and review.approved_by == approved_by do
      review
    else
      review
      |> Ecto.Changeset.change(status: status, approved_by: approved_by)
      |> Repo.update!()
    end
  end

  defp anchor!(repository, review, attrs) do
    values = Enum.map(["revision", "path", "side", "line"], &Map.get(attrs, &1))

    if Enum.all?(values, &is_nil/1) do
      %{}
    else
      unless Enum.all?(values, &(not is_nil(&1))),
        do: Error.fail("Inline comments require revision, path, side, and line")

      [revision, path, side, line] = values
      unless revision == review.changeset_id, do: Error.fail("Comment revision is stale", 409)
      path = Tree.path!(path)
      unless side in ["before", "after"], do: Error.fail("Choose the before or after side")
      unless is_integer(line) and line > 0, do: Error.fail("Comment line must be positive")

      change = Changesets.get(repository, review.changeset_id)

      file =
        Changesets.diff(
          repository,
          change,
          if(review.series, do: review.base_id, else: :parent)
        )
        |> Enum.find(&(&1.path == path)) || Error.fail("Comment path is not in this change", 409)

      content = Map.fetch!(file, String.to_existing_atom(side))

      unless (content && content.encoding == "utf8") and not content.truncated and
               line <= length(String.split(content.content, "\n")),
             do: Error.fail("Comment line is outside this text diff", 409)

      %{revision_id: revision, path: path, side: side, line: line}
    end
  end
end
