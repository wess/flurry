defmodule Flurry.ReviewFindingsTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Changesets, Repositories, ReviewFindings, Reviews, Settings, Statuses}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    owner = user("Owner")
    reporter = user("Reporter")
    verifier = user("Verifier")

    Settings.member(
      repository = Repositories.create(owner, %{"name" => unique("review")}),
      owner,
      %{
        "username" => reporter.username,
        "role" => "write"
      }
    )

    Settings.member(repository, owner, %{
      "username" => verifier.username,
      "role" => "maintain"
    })

    submitted = submit(repository, owner, nil, "unsafe\nvalue\n")
    review = Reviews.get(repository, submitted.review_id)

    %{
      owner: owner,
      reporter: reporter,
      verifier: verifier,
      repository: repository,
      review: review
    }
  end

  test "verified findings are structured, revision-bound, and can publish an optional status",
       ctx do
    run =
      ReviewFindings.request(ctx.repository, ctx.review, ctx.reporter, %{
        "profiles" => ["correctness", "security"],
        "status_context" => "review/verified-findings"
      })

    finding =
      ReviewFindings.add_finding(ctx.repository, ctx.review, ctx.reporter, run.id, %{
        "fingerprint" => "unsafe-value:readme",
        "category" => "security",
        "severity" => "high",
        "classification" => "introduced",
        "title" => "Untrusted value is accepted",
        "body" => "The new value reaches a sensitive operation without validation.",
        "evidence" => "The changed branch has no ownership check.",
        "path" => "readme.md",
        "side" => "after",
        "line" => 1
      })

    assert finding.state == "open"
    refute finding.verified
    assert finding.current

    assert_raise Flurry.Error, ~r/different account/, fn ->
      ReviewFindings.act(ctx.repository, ctx.review, ctx.reporter, finding.id, "verified")
    end

    verified =
      ReviewFindings.act(ctx.repository, ctx.review, ctx.verifier, finding.id, "verified", %{
        "note" => "Confirmed against the changed call path."
      })

    assert verified.verified
    assert hd(verified.events).actor.id == ctx.verifier.id

    agent =
      ctx.reporter
      |> Ecto.Changeset.change(account_type: "agent")
      |> Repo.update!()

    assert_raise Flurry.Error, ~r/human maintainer/, fn ->
      ReviewFindings.act(ctx.repository, ctx.review, agent, finding.id, "resolved")
    end

    completed =
      ReviewFindings.update_run(ctx.repository, ctx.review, ctx.reporter, run.id, %{
        "state" => "completed",
        "summary" => "Specialists completed and verification finished.",
        "reconcile" => true
      })

    assert completed.state == "completed"

    assert [%{context: "review/verified-findings", state: "failure"}] =
             Statuses.list(ctx.repository, ctx.review.changeset_id)

    resolved =
      ReviewFindings.act(ctx.repository, ctx.review, ctx.verifier, finding.id, "resolved", %{
        "note" => "Fixed in the next revision."
      })

    assert resolved.state == "resolved"
    assert Enum.map(resolved.events, & &1.action) == ["verified", "resolved"]
    assert [%{state: "success"}] = Statuses.list(ctx.repository, ctx.review.changeset_id)
  end

  test "stable fingerprints carry findings forward and completed runs reconcile fixed findings",
       ctx do
    first = ReviewFindings.request(ctx.repository, ctx.review, ctx.reporter)

    old =
      ReviewFindings.add_finding(ctx.repository, ctx.review, ctx.reporter, first.id, finding())

    next = submit(ctx.repository, ctx.owner, nil, "safer\nvalue\n")
    Repo.delete!(Reviews.get(ctx.repository, next.review_id))
    review = Reviews.revise(ctx.repository, ctx.review.id, ctx.owner, next.changeset.id)
    second = ReviewFindings.request(ctx.repository, review, ctx.reporter)

    current =
      ReviewFindings.add_finding(ctx.repository, review, ctx.reporter, second.id, %{
        finding()
        | "body" => "The finding still applies on the new revision.",
          "line" => 2
      })

    findings = ReviewFindings.list_findings(ctx.repository, review)
    assert Enum.find(findings, &(&1.id == old.id)).state == "superseded"
    assert current.current

    third = ReviewFindings.request(ctx.repository, review, ctx.reporter)

    ReviewFindings.update_run(ctx.repository, review, ctx.reporter, third.id, %{
      "state" => "completed",
      "reconcile" => true
    })

    findings = ReviewFindings.list_findings(ctx.repository, review)
    reconciled = Enum.find(findings, &(&1.id == current.id))
    assert reconciled.state == "not_reproduced"
    assert List.last(reconciled.events).action == "not_reproduced"
  end

  test "a repeated fingerprint supersedes the prior finding on the same revision", ctx do
    first = ReviewFindings.request(ctx.repository, ctx.review, ctx.reporter)

    old =
      ReviewFindings.add_finding(ctx.repository, ctx.review, ctx.reporter, first.id, finding())

    second = ReviewFindings.request(ctx.repository, ctx.review, ctx.reporter)

    current =
      ReviewFindings.add_finding(ctx.repository, ctx.review, ctx.reporter, second.id, finding())

    findings = ReviewFindings.list_findings(ctx.repository, ctx.review)
    assert Enum.find(findings, &(&1.id == old.id)).state == "superseded"
    assert Enum.find(findings, &(&1.id == current.id)).state == "open"
  end

  test "repository trigger requests runs without executing repository code", ctx do
    repository =
      Settings.update(ctx.repository, ctx.owner, %{
        "review_trigger" => "every_revision",
        "review_profiles" => ["correctness", "regression"],
        "review_status_context" => "review/findings"
      })

    submitted = submit(repository, ctx.owner, nil, "automatic\n")
    review = Reviews.get(repository, submitted.review_id)

    assert [%{trigger: "review_opened", state: "requested"} = run] =
             ReviewFindings.list_runs(repository, review)

    assert run.profiles == ["correctness", "regression"]
    assert run.status_context == "review/findings"
  end

  test "finding evidence cannot be rewritten", ctx do
    run = ReviewFindings.request(ctx.repository, ctx.review, ctx.reporter)

    finding =
      ReviewFindings.add_finding(ctx.repository, ctx.review, ctx.reporter, run.id, finding())

    assert_raise Postgrex.Error, ~r/review evidence is immutable/, fn ->
      Repo.query!("UPDATE review_findings SET title = 'rewritten' WHERE id = $1", [
        Ecto.UUID.dump!(finding.id)
      ])
    end
  end

  test "review deletion can cascade through immutable review evidence", ctx do
    run = ReviewFindings.request(ctx.repository, ctx.review, ctx.reporter)
    ReviewFindings.add_finding(ctx.repository, ctx.review, ctx.reporter, run.id, finding())

    Repo.delete!(ctx.review)
    refute Repo.get(Flurry.Schema.Review, ctx.review.id)
  end

  defp finding do
    %{
      "fingerprint" => "stable-finding",
      "category" => "correctness",
      "severity" => "medium",
      "classification" => "introduced",
      "title" => "Value can become stale",
      "body" => "The new value is read after its validity window.",
      "evidence" => "The changed path reuses the previous value.",
      "path" => "readme.md",
      "side" => "after",
      "line" => 1
    }
  end

  defp submit(repository, user, base, content) do
    Changesets.submit(repository, user, %{
      "base" => base,
      "message" => "Review finding fixture",
      "files" => [%{"path" => "readme.md", "content" => content}]
    })
  end

  defp user(label) do
    value = unique("u")

    {user, _} =
      Auth.signup(%{
        "name" => label,
        "username" => value,
        "email" => value <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end

  defp unique(prefix), do: prefix <> (Ecto.UUID.generate() |> String.replace("-", ""))
end
