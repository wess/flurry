defmodule Flurry.Engine.ReviewFindings do
  import Ecto.Query

  import Flurry.Engine.ReviewFindings.Read,
    only: [
      actor_for: 1,
      event_public: 2,
      events: 1,
      finding!: 3,
      finding_public: 3,
      run!: 3,
      run_public: 2,
      state: 1,
      verified?: 1
    ]

  import Flurry.Engine.ReviewFindings.Validation
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Engine.{Changesets, Repositories, Statuses, Webhooks}
  alias Flurry.Engine.ReviewFindings.Read

  alias Flurry.Schema.{
    ReviewFinding,
    ReviewFindingEvent,
    ReviewRun
  }

  @profiles ["correctness", "security", "regression", "edge_case", "contract"]
  @categories @profiles ++ ["other"]
  @severities ["blocker", "high", "medium", "low", "info"]
  @classifications ["introduced", "preexisting"]
  @run_states ["running", "completed", "failed", "cancelled"]
  @actions ["verified", "resolved", "dismissed", "reopened", "superseded", "not_reproduced"]

  def request(repository, review, actor, attrs \\ %{}) do
    unless Repositories.permitted?(repository, actor, :write),
      do: Error.fail("Write access required", 403)

    create_run(repository, review, actor, attrs, "manual")
  end

  def automatic(repository, review, actor, event) do
    enabled =
      repository.review_trigger == "every_revision" or
        (repository.review_trigger == "review_opened" and event == :review_opened)

    if enabled do
      trigger = if event == :review_opened, do: "review_opened", else: "revision"
      create_run(repository, review, actor, %{}, trigger)
    end
  end

  defdelegate list_runs(repository, review), to: Read

  def update_run(repository, review, actor, id, attrs) do
    unless Repositories.permitted?(repository, actor, :write),
      do: Error.fail("Write access required", 403)

    run = run!(repository, review, id)
    state = attrs["state"]
    unless state in @run_states, do: Error.fail("Choose a valid review-run state")

    if run.state in ["completed", "failed", "cancelled"],
      do: Error.fail("This review run is already finished", 409)

    now = DateTime.utc_now()
    summary = optional_text!(attrs["summary"], "Run summary", 2_000) || run.summary

    run =
      run
      |> Ecto.Changeset.change(
        state: state,
        summary: summary,
        external_id:
          optional_text!(attrs["external_id"], "External run ID", 200) || run.external_id,
        started_at: if(state == "running", do: run.started_at || now, else: run.started_at),
        completed_at: if(state in ["completed", "failed", "cancelled"], do: now)
      )
      |> Repo.update!()

    if state == "completed" and attrs["reconcile"] == true,
      do: reconcile(review, run, actor)

    if state in ["completed", "failed"] and run.status_context,
      do: publish_status(repository, run, actor)

    public = run_public(run, actor_for(run.creator_id))
    Webhooks.emit(repository, "review.run.updated", public)
    Flurry.Audit.record(actor, "review.run." <> state, repository, %{run: run.id})
    public
  end

  def add_finding(repository, review, actor, run_id, attrs) do
    unless Repositories.permitted?(repository, actor, :write),
      do: Error.fail("Write access required", 403)

    run = run!(repository, review, run_id)

    unless run.state in ["requested", "running"],
      do: Error.fail("Findings can only be added to an active review run", 409)

    unless run.revision_id == review.changeset_id,
      do: Error.fail("This review run belongs to an older revision", 409)

    anchor = anchor!(repository, review, attrs)
    fingerprint = fingerprint!(attrs["fingerprint"])

    finding =
      %ReviewFinding{
        id: Ecto.UUID.generate(),
        repository_id: repository.id,
        review_id: review.id,
        run_id: run.id,
        revision_id: run.revision_id,
        reporter_id: actor.id,
        fingerprint: fingerprint,
        category: enum!(attrs["category"], @categories, "finding category"),
        severity: enum!(attrs["severity"], @severities, "finding severity"),
        classification:
          enum!(attrs["classification"] || "introduced", @classifications, "classification"),
        title: Auth.text!(attrs["title"], "Finding title", 200),
        body: Auth.text!(attrs["body"], "Finding description", 10_000),
        evidence: optional_text!(attrs["evidence"], "Finding evidence", 4_000) || "",
        path: anchor[:path],
        side: anchor[:side],
        line: anchor[:line]
      }
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.unique_constraint([:run_id, :fingerprint])
      |> case do
        changeset ->
          case Repo.insert(changeset) do
            {:ok, finding} -> finding
            {:error, _} -> Error.fail("This run already contains that finding", 409)
          end
      end

    supersede_prior(repository, review, finding, actor)
    public = finding_public(finding, actor, events(finding.id))
    Webhooks.emit(repository, "review.finding.created", public)
    Flurry.Audit.record(actor, "review.finding.create", repository, %{finding: finding.id})

    change = Changesets.get(repository, review.changeset_id)

    Flurry.Engine.Notifications.notify(
      change.author_id,
      "review.finding",
      "Automated review finding",
      actor: actor,
      repository: repository,
      body: finding.title,
      url: "/repositories/#{repository.id}/reviews/#{review.id}"
    )

    public
  end

  def act(repository, review, actor, finding_id, action, attrs \\ %{}) do
    unless action in @actions, do: Error.fail("Choose a valid finding action")

    required = if action == "verified", do: :write, else: :review

    if action != "verified" and actor.account_type != "human",
      do: Error.fail("A human maintainer must change finding disposition", 403)

    unless Repositories.permitted?(repository, actor, required),
      do:
        Error.fail(
          if(required == :write, do: "Write access required", else: "Maintainer access required"),
          403
        )

    finding = finding!(repository, review, finding_id)
    history = events(finding.id)

    if action == "verified" and finding.reporter_id == actor.id,
      do: Error.fail("A finding must be verified by a different account", 409)

    current = state(history)

    case {action, current} do
      {_, "superseded"} ->
        Error.fail("Superseded findings cannot change disposition", 409)

      {_, "not_reproduced"} ->
        Error.fail("Findings not reproduced by a completed run cannot change disposition", 409)

      {"verified", _} ->
        if verified?(history), do: Error.fail("This finding is already verified", 409)

      {"reopened", value} when value not in ["resolved", "dismissed"] ->
        Error.fail("Only resolved or dismissed findings can be reopened", 409)

      {value, current} when value == current ->
        Error.fail("This finding already has that disposition", 409)

      _ ->
        :ok
    end

    event = append_event(finding, actor, action, attrs["note"] || "", review.changeset_id)

    public =
      finding_public(
        finding,
        actor_for(finding.reporter_id),
        history ++ [event_public(event, actor)]
      )

    run = Repo.get!(ReviewRun, finding.run_id)
    if run.state == "completed" and run.status_context, do: publish_status(repository, run, actor)

    Webhooks.emit(repository, "review.finding." <> action, public)
    Flurry.Audit.record(actor, "review.finding." <> action, repository, %{finding: finding.id})
    public
  end

  defdelegate list_findings(repository, review), to: Read
  defdelegate detail(repository, review), to: Read

  defp create_run(repository, review, actor, attrs, trigger) do
    profiles = profiles!(attrs["profiles"] || repository.review_profiles || @profiles)
    context = context!(Map.get(attrs, "status_context", repository.review_status_context))

    run =
      Repo.insert!(%ReviewRun{
        id: Ecto.UUID.generate(),
        repository_id: repository.id,
        review_id: review.id,
        revision_id: review.changeset_id,
        creator_id: actor.id,
        trigger: trigger,
        profiles: profiles,
        status_context: context,
        external_id: optional_text!(attrs["external_id"], "External run ID", 200)
      })

    public = run_public(run, actor)
    Webhooks.emit(repository, "review.run.requested", public)
    Flurry.Audit.record(actor, "review.run.request", repository, %{run: run.id, trigger: trigger})
    public
  end

  defp reconcile(review, run, actor) do
    current =
      Repo.all(from(f in ReviewFinding, where: f.run_id == ^run.id, select: f.fingerprint))
      |> MapSet.new()

    prior =
      Repo.all(
        from(f in ReviewFinding,
          where:
            f.review_id == ^review.id and f.run_id != ^run.id and
              f.fingerprint not in ^MapSet.to_list(current),
          order_by: [desc: f.inserted_at]
        )
      )
      |> Enum.filter(&(state(events(&1.id)) == "open"))
      |> Enum.uniq_by(& &1.fingerprint)

    Enum.each(prior, fn finding ->
      append_event(
        finding,
        actor,
        "not_reproduced",
        "Not reproduced by the completed review run.",
        run.revision_id
      )
    end)
  end

  defp supersede_prior(repository, review, finding, actor) do
    Repo.all(
      from(f in ReviewFinding,
        where:
          f.repository_id == ^repository.id and f.review_id == ^review.id and
            f.fingerprint == ^finding.fingerprint and f.id != ^finding.id
      )
    )
    |> Enum.each(fn prior ->
      if state(events(prior.id)) != "superseded" do
        append_event(
          prior,
          actor,
          "superseded",
          "Carried forward by a newer review run.",
          finding.revision_id
        )
      end
    end)
  end

  defp publish_status(repository, run, actor) do
    findings = Repo.all(from(f in ReviewFinding, where: f.run_id == ^run.id))

    blocking =
      Enum.filter(findings, fn finding ->
        history = events(finding.id)

        finding.classification == "introduced" and finding.severity in ["blocker", "high"] and
          verified?(history) and state(history) == "open"
      end)

    {state, description} =
      cond do
        run.state == "failed" -> {"error", "Automated review did not complete"}
        blocking == [] -> {"success", "No open verified blocker or high-severity findings"}
        true -> {"failure", "#{length(blocking)} open verified high-severity finding(s)"}
      end

    Statuses.put(repository, actor, run.revision_id, %{
      "context" => run.status_context,
      "state" => state,
      "description" => description
    })
  end

  defp append_event(finding, actor, action, note, revision) do
    Repo.insert!(%ReviewFindingEvent{
      id: Ecto.UUID.generate(),
      finding_id: finding.id,
      actor_id: actor.id,
      revision_id: revision,
      action: action,
      note: optional_text!(note, "Finding event note", 2_000) || ""
    })
  end
end
