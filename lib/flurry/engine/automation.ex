defmodule Flurry.Engine.Automation do
  import Ecto.Query
  alias Flurry.{Auth, Error, Repo}
  alias Flurry.Engine.{Changesets, Repositories, Webhooks}
  alias Flurry.Schema.{AutomationRun, EvaluationRun, User}

  @evaluation_states ["success", "failure", "error"]
  @sensitive ~r/(password|secret|token|credential|prompt)/i

  def submission(nil), do: nil

  def submission(attrs) when is_map(attrs) do
    %{
      name: text!(attrs["name"], "Automation name", 120),
      version: optional_text!(attrs["version"], "Automation version", 120),
      trigger: optional_text!(attrs["trigger"], "Automation trigger", 40) || "api",
      external_id: optional_text!(attrs["external_id"], "External run ID", 200),
      metadata: metadata!(attrs["metadata"] || %{})
    }
  end

  def submission(_), do: Error.fail("Automation provenance must be an object")

  def record_submission(_repository, _actor, _changeset, nil, _key), do: nil

  def record_submission(repository, actor, changeset, attrs, key) do
    run = %AutomationRun{
      id: Ecto.UUID.generate(),
      repository_id: repository.id,
      changeset_id: changeset.id,
      actor_id: actor.id,
      name: attrs.name,
      version: attrs.version,
      trigger: attrs.trigger,
      base_revision: changeset.parent_id,
      external_id: attrs.external_id,
      idempotency_key: key,
      metadata: attrs.metadata
    }

    Repo.insert!(run)
  end

  def provenance(repository, changeset_id) do
    Repo.one(
      from(r in AutomationRun,
        join: u in User,
        on: r.actor_id == u.id,
        where: r.repository_id == ^repository.id and r.changeset_id == ^changeset_id,
        select: {r, u.name}
      )
    )
    |> case do
      nil -> nil
      {run, actor_name} -> provenance_public(run, actor_name)
    end
  end

  def evaluations(repository, changeset_id) do
    Changesets.get(repository, changeset_id)

    Repo.all(
      from(e in EvaluationRun,
        join: u in User,
        on: e.creator_id == u.id,
        where: e.repository_id == ^repository.id and e.changeset_id == ^changeset_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: 100,
        select: {e, u.name}
      )
    )
    |> Enum.map(fn {evaluation, creator_name} -> evaluation_public(evaluation, creator_name) end)
  end

  def evaluate(repository, actor, changeset_id, attrs) when is_map(attrs) do
    unless Repositories.permitted?(repository, actor, :write),
      do: Error.fail("Write access required", 403)

    Changesets.get(repository, changeset_id)
    state = attrs["state"]
    unless state in @evaluation_states, do: Error.fail("Choose a valid evaluation state")

    evaluation =
      Repo.insert!(%EvaluationRun{
        id: Ecto.UUID.generate(),
        repository_id: repository.id,
        changeset_id: changeset_id,
        creator_id: actor.id,
        context: context!(attrs["context"]),
        state: state,
        summary: optional_text!(attrs["summary"], "Evaluation summary", 500) || "",
        score: score!(attrs["score"]),
        pass_count: count!(Map.get(attrs, "pass", 0), "Pass count"),
        fail_count: count!(Map.get(attrs, "fail", 0), "Fail count"),
        duration_ms: duration!(attrs["duration_ms"]),
        metrics: metadata!(attrs["metrics"] || %{}),
        target_url: target_url!(attrs["target_url"]),
        external_id: optional_text!(attrs["external_id"], "External run ID", 200)
      })

    public = evaluation_public(evaluation, actor.name)
    Webhooks.emit(repository, "evaluation.created", public)
    Flurry.Audit.record(actor, "evaluation.create", repository, %{evaluation: evaluation.id})
    public
  end

  def evaluate(_repository, _actor, _changeset_id, _attrs),
    do: Error.fail("Evaluation must be an object")

  def provenance_public(run, actor_name) do
    %{
      id: run.id,
      changeset_id: run.changeset_id,
      actor: %{id: run.actor_id, name: actor_name},
      name: run.name,
      version: run.version,
      trigger: run.trigger,
      base_revision: run.base_revision,
      external_id: run.external_id,
      metadata: run.metadata,
      inserted_at: run.inserted_at
    }
  end

  def evaluation_public(evaluation, creator_name) do
    %{
      id: evaluation.id,
      changeset_id: evaluation.changeset_id,
      creator: %{id: evaluation.creator_id, name: creator_name},
      context: evaluation.context,
      state: evaluation.state,
      summary: evaluation.summary,
      score: evaluation.score,
      pass: evaluation.pass_count,
      fail: evaluation.fail_count,
      duration_ms: evaluation.duration_ms,
      metrics: evaluation.metrics,
      target_url: evaluation.target_url,
      external_id: evaluation.external_id,
      inserted_at: evaluation.inserted_at
    }
  end

  defp context!(value) do
    value = text!(value, "Evaluation context", 100)

    unless Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9 ._\/-]*\z/, value),
      do: Error.fail("Evaluation context contains unsupported characters")

    value
  end

  defp metadata!(value) when is_map(value) do
    reject_sensitive!(value)
    if byte_size(Jason.encode!(value)) > 16_000, do: Error.fail("Metadata is too large")
    value
  end

  defp metadata!(_), do: Error.fail("Metadata must be an object")

  defp reject_sensitive!(value) when is_map(value) do
    Enum.each(value, fn {key, nested} ->
      if is_binary(key) and Regex.match?(@sensitive, key),
        do:
          Error.fail(
            "Metadata cannot contain secrets, credentials, tokens, passwords, or prompts"
          )

      reject_sensitive!(nested)
    end)
  end

  defp reject_sensitive!(value) when is_list(value), do: Enum.each(value, &reject_sensitive!/1)
  defp reject_sensitive!(_), do: :ok

  defp score!(nil), do: nil

  defp score!(value) when is_number(value) and value >= -1.0e9 and value <= 1.0e9,
    do: value / 1

  defp score!(_), do: Error.fail("Evaluation score must be a finite number")

  defp count!(value, _label) when is_integer(value) and value >= 0 and value <= 1_000_000,
    do: value

  defp count!(_value, label), do: Error.fail("#{label} must be a non-negative integer")

  defp duration!(nil), do: nil
  defp duration!(value) when is_integer(value) and value >= 0, do: value
  defp duration!(_), do: Error.fail("Duration must be a non-negative integer")

  defp target_url!(nil), do: nil
  defp target_url!(""), do: nil

  defp target_url!(value) when is_binary(value) and byte_size(value) <= 2_000 do
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and is_nil(uri.userinfo) and
         is_nil(uri.fragment),
       do: value,
       else: Error.fail("Evaluation target URLs must use HTTPS")
  end

  defp target_url!(_), do: Error.fail("Evaluation target URL is too long")

  defp text!(value, label, limit), do: Auth.text!(value, label, limit)
  defp optional_text!(nil, _label, _limit), do: nil
  defp optional_text!("", _label, _limit), do: nil
  defp optional_text!(value, label, limit), do: text!(value, label, limit)
end
