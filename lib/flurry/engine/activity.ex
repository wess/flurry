defmodule Flurry.Engine.Activity do
  import Ecto.Query
  alias Flurry.Repo
  alias Flurry.Engine.Automation

  alias Flurry.Schema.{
    AutomationRun,
    Changeset,
    CommitStatus,
    EvaluationRun,
    Review,
    ReviewDecision,
    ReviewFinding,
    ReviewFindingEvent,
    User
  }

  def list(repository, limit \\ 100) do
    limit = limit |> max(1) |> min(100)

    (changes(repository) ++
       evaluations(repository) ++
       findings(repository) ++
       statuses(repository) ++ reviews(repository) ++ decisions(repository))
    |> Enum.sort_by(&timestamp/1, :desc)
    |> Enum.take(limit)
  end

  defp changes(repository) do
    Repo.all(
      from(c in Changeset,
        join: u in User,
        on: c.author_id == u.id,
        left_join: r in Review,
        on: r.changeset_id == c.id,
        left_join: a in AutomationRun,
        on: a.changeset_id == c.id,
        where: c.repository_id == ^repository.id,
        order_by: [desc: c.inserted_at],
        limit: 100,
        select: {c, u.name, r.id, a.name, a.version}
      )
    )
    |> Enum.map(fn {change, author, review_id, automation, version} ->
      source =
        if automation,
          do: Enum.join(Enum.reject([automation, version], &is_nil/1), " "),
          else: nil

      event(
        "change:#{change.id}",
        "change.submitted",
        change.message,
        if(source,
          do: "#{author} submitted with #{source}",
          else:
            "#{author} submitted #{map_size(change.changes)} changed file#{if map_size(change.changes) == 1, do: "", else: "s"}"
        ),
        change.inserted_at,
        %{id: change.author_id, name: author},
        change.id,
        review_id,
        nil
      )
    end)
  end

  defp evaluations(repository) do
    Repo.all(
      from(e in EvaluationRun,
        join: u in User,
        on: e.creator_id == u.id,
        left_join: r in Review,
        on: r.changeset_id == e.changeset_id,
        where: e.repository_id == ^repository.id,
        order_by: [desc: e.inserted_at],
        limit: 100,
        select: {e, u.name, r.id}
      )
    )
    |> Enum.map(fn {evaluation, creator, review_id} ->
      public = Automation.evaluation_public(evaluation, creator)
      detail = if evaluation.summary == "", do: counts(evaluation), else: evaluation.summary

      event(
        "evaluation:#{evaluation.id}",
        "evaluation.created",
        evaluation.context,
        detail,
        evaluation.inserted_at,
        public.creator,
        evaluation.changeset_id,
        review_id,
        evaluation.state
      )
    end)
  end

  defp statuses(repository) do
    Repo.all(
      from(s in CommitStatus,
        join: u in User,
        on: s.creator_id == u.id,
        left_join: r in Review,
        on: r.changeset_id == s.changeset_id,
        where: s.repository_id == ^repository.id,
        order_by: [desc: s.updated_at],
        limit: 100,
        select: {s, u.name, r.id}
      )
    )
    |> Enum.map(fn {status, creator, review_id} ->
      event(
        "status:#{status.id}",
        "status.updated",
        status.context,
        status.description,
        status.updated_at,
        %{id: status.creator_id, name: creator},
        status.changeset_id,
        review_id,
        status.state
      )
    end)
  end

  defp findings(repository) do
    created =
      Repo.all(
        from(f in ReviewFinding,
          join: u in User,
          on: u.id == f.reporter_id,
          where: f.repository_id == ^repository.id,
          order_by: [desc: f.inserted_at],
          limit: 100,
          select: {f, u.name}
        )
      )
      |> Enum.map(fn {finding, reporter} ->
        event(
          "finding:#{finding.id}:created",
          "review.finding.created",
          finding.title,
          "#{finding.severity} #{finding.category} finding",
          finding.inserted_at,
          %{id: finding.reporter_id, name: reporter},
          finding.revision_id,
          finding.review_id,
          finding.severity
        )
      end)

    events =
      Repo.all(
        from(e in ReviewFindingEvent,
          join: f in ReviewFinding,
          on: f.id == e.finding_id,
          join: u in User,
          on: u.id == e.actor_id,
          where: f.repository_id == ^repository.id,
          order_by: [desc: e.inserted_at],
          limit: 100,
          select: {e, f, u.name}
        )
      )
      |> Enum.map(fn {finding_event, finding, actor} ->
        event(
          "finding-event:#{finding_event.id}",
          "review.finding.#{finding_event.action}",
          finding.title,
          if(finding_event.note == "",
            do: String.capitalize(finding_event.action),
            else: finding_event.note
          ),
          finding_event.inserted_at,
          %{id: finding_event.actor_id, name: actor},
          finding_event.revision_id,
          finding.review_id,
          finding_event.action
        )
      end)

    created ++ events
  end

  defp reviews(repository) do
    Repo.all(
      from(r in Review,
        join: c in Changeset,
        on: r.changeset_id == c.id,
        join: u in User,
        on: c.author_id == u.id,
        where: r.repository_id == ^repository.id,
        order_by: [desc: r.inserted_at],
        limit: 100,
        select: {r, c.message, u.name, c.author_id}
      )
    )
    |> Enum.flat_map(fn {review, message, author, author_id} ->
      opened =
        event(
          "review:#{review.id}:opened",
          "review.opened",
          message,
          "Review opened",
          review.inserted_at,
          %{id: author_id, name: author},
          review.changeset_id,
          review.id,
          "open"
        )

      if review.landed_id do
        [
          event(
            "review:#{review.id}:landed",
            "review.landed",
            message,
            "Landed on main",
            review.updated_at,
            nil,
            review.landed_id,
            review.id,
            "landed"
          ),
          opened
        ]
      else
        [opened]
      end
    end)
  end

  defp decisions(repository) do
    Repo.all(
      from(d in ReviewDecision,
        join: r in Review,
        on: d.review_id == r.id,
        join: c in Changeset,
        on: r.changeset_id == c.id,
        join: u in User,
        on: d.user_id == u.id,
        where: r.repository_id == ^repository.id,
        order_by: [desc: d.updated_at],
        limit: 100,
        select: {d, c.message, u.name}
      )
    )
    |> Enum.map(fn {decision, message, actor} ->
      approved = decision.decision == "approve"

      event(
        "decision:#{decision.review_id}:#{decision.user_id}",
        if(approved, do: "review.approved", else: "review.changes_requested"),
        message,
        if(approved, do: "Approved by #{actor}", else: "Changes requested by #{actor}"),
        decision.updated_at,
        %{id: decision.user_id, name: actor},
        decision.revision_id,
        decision.review_id,
        if(approved, do: "success", else: "failure")
      )
    end)
  end

  defp event(id, type, title, detail, inserted_at, actor, changeset_id, review_id, state) do
    %{
      id: id,
      type: type,
      title: title,
      detail: detail,
      inserted_at: inserted_at,
      actor: actor,
      changeset_id: changeset_id,
      review_id: review_id,
      state: state
    }
  end

  defp counts(evaluation) do
    "#{evaluation.pass_count} passed, #{evaluation.fail_count} failed"
  end

  defp timestamp(%{inserted_at: value}), do: DateTime.to_unix(value, :microsecond)
end
