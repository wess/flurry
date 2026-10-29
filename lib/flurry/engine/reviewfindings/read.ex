defmodule Flurry.Engine.ReviewFindings.Read do
  import Ecto.Query
  alias Flurry.{Error, Repo}
  alias Flurry.Schema.{Review, ReviewFinding, ReviewFindingEvent, ReviewRun, User}

  def list_runs(repository, review) do
    Repo.all(
      from(r in ReviewRun,
        join: u in User,
        on: u.id == r.creator_id,
        where: r.repository_id == ^repository.id and r.review_id == ^review.id,
        order_by: [desc: r.inserted_at],
        limit: 100,
        select: {r, u}
      )
    )
    |> Enum.map(fn {run, creator} -> run_public(run, creator) end)
  end

  def list_findings(repository, review) do
    findings =
      Repo.all(
        from(f in ReviewFinding,
          join: u in User,
          on: u.id == f.reporter_id,
          where: f.repository_id == ^repository.id and f.review_id == ^review.id,
          order_by: [desc: f.inserted_at],
          limit: 500,
          select: {f, u}
        )
      )

    event_map =
      case Enum.map(findings, fn {finding, _} -> finding.id end) do
        [] ->
          %{}

        ids ->
          Repo.all(
            from(e in ReviewFindingEvent,
              join: u in User,
              on: u.id == e.actor_id,
              where: e.finding_id in ^ids,
              order_by: [asc: e.inserted_at, asc: e.id],
              select: {e, u}
            )
          )
          |> Enum.group_by(fn {event, _} -> event.finding_id end, fn {event, user} ->
            event_public(event, user)
          end)
      end

    Enum.map(findings, fn {finding, reporter} ->
      finding_public(finding, reporter, Map.get(event_map, finding.id, []))
    end)
  end

  def detail(repository, review) do
    %{runs: list_runs(repository, review), findings: list_findings(repository, review)}
  end

  def run!(repository, review, id) do
    uuid!(id, "Review run")

    Repo.one(
      from(r in ReviewRun,
        where: r.id == ^id and r.repository_id == ^repository.id and r.review_id == ^review.id
      )
    ) || Error.fail("Review run not found", 404)
  end

  def finding!(repository, review, id) do
    uuid!(id, "Finding")

    Repo.one(
      from(f in ReviewFinding,
        where: f.id == ^id and f.repository_id == ^repository.id and f.review_id == ^review.id
      )
    ) || Error.fail("Finding not found", 404)
  end

  def events(finding_id) do
    Repo.all(
      from(e in ReviewFindingEvent,
        join: u in User,
        on: u.id == e.actor_id,
        where: e.finding_id == ^finding_id,
        order_by: [asc: e.inserted_at, asc: e.id],
        select: {e, u}
      )
    )
    |> Enum.map(fn {event, actor} -> event_public(event, actor) end)
  end

  def run_public(run, creator) do
    %{
      id: run.id,
      review_id: run.review_id,
      revision: run.revision_id,
      creator: identity(creator),
      trigger: run.trigger,
      profiles: run.profiles,
      state: run.state,
      summary: run.summary,
      status_context: run.status_context,
      external_id: run.external_id,
      started_at: run.started_at,
      completed_at: run.completed_at,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  def finding_public(finding, reporter, history) do
    %{
      id: finding.id,
      run_id: finding.run_id,
      revision: finding.revision_id,
      current: finding.revision_id == Repo.get!(Review, finding.review_id).changeset_id,
      reporter: identity(reporter),
      fingerprint: finding.fingerprint,
      category: finding.category,
      severity: finding.severity,
      classification: finding.classification,
      title: finding.title,
      body: finding.body,
      evidence: finding.evidence,
      path: finding.path,
      side: finding.side,
      line: finding.line,
      verified: verified?(history),
      state: state(history),
      events: history,
      inserted_at: finding.inserted_at
    }
  end

  def event_public(event, actor) do
    %{
      id: event.id,
      action: event.action,
      note: event.note,
      revision: event.revision_id,
      actor: identity(actor),
      inserted_at: event.inserted_at
    }
  end

  def actor_for(id), do: Repo.get!(User, id)
  def verified?(events), do: Enum.any?(events, &(&1.action == "verified"))

  def state(events) do
    events
    |> Enum.reverse()
    |> Enum.find(
      &(&1.action in ["resolved", "dismissed", "reopened", "superseded", "not_reproduced"])
    )
    |> case do
      nil -> "open"
      %{action: "reopened"} -> "open"
      %{action: action} -> action
    end
  end

  defp identity(user),
    do: %{id: user.id, name: user.name, username: user.username, account_type: user.account_type}

  defp uuid!(id, label) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("#{label} not found", 404)
  end
end
