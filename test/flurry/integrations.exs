defmodule Flurry.IntegrationsTest do
  use ExUnit.Case, async: false
  alias Flurry.{Auth, Repo}
  alias Flurry.Engine.{Activity, Automation, Changesets, Repositories, Statuses, Webhooks}
  alias Flurry.Integrations.Endpoint
  alias Flurry.Schema.{Webhook, WebhookDelivery}

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    previous = Application.get_env(:flurry, :encryption_key)
    Application.put_env(:flurry, :encryption_key, :crypto.strong_rand_bytes(32))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:flurry, :encryption_key, previous),
        else: Application.delete_env(:flurry, :encryption_key)
    end)

    :ok
  end

  test "webhook endpoints reject private and ambiguous destinations" do
    public = fn _ -> {:ok, [{93, 184, 216, 34}]} end
    private = fn _ -> {:ok, [{127, 0, 0, 1}]} end
    mixed = fn _ -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 1}]} end

    assert Endpoint.validate!("https://hooks.example.test/events", public) ==
             "https://hooks.example.test/events"

    for {url, resolver} <- [
          {"http://hooks.example.test", public},
          {"https://user:secret@hooks.example.test", public},
          {"https://hooks.example.test/#fragment", public},
          {"https://hooks.example.test", private},
          {"https://hooks.example.test", mixed},
          {"https://127.0.0.1/events", private}
        ] do
      assert_raise Flurry.Error, fn -> Endpoint.validate!(url, resolver) end
    end

    refute Endpoint.public?({10, 0, 0, 1})
    refute Endpoint.public?({0, 0, 0, 0, 0, 0, 0, 1})
    assert Endpoint.public?({93, 184, 216, 34})
  end

  test "deliveries are signed, bounded, and expose no stored secret" do
    owner = user()
    repository = Repositories.create(owner, %{"name" => "hooks"})
    resolver = fn _ -> {:ok, [{93, 184, 216, 34}]} end

    created =
      Webhooks.create(
        repository,
        owner,
        %{"url" => "https://hooks.example.test/events", "events" => ["review.landed"]},
        resolver
      )

    refute Map.has_key?(created.webhook, :secret)
    refute Repo.get!(Webhook, created.webhook.id).secret == created.secret
    assert Webhooks.list(repository) == [created.webhook]
    assert Webhooks.emit(repository, "status.updated", %{"state" => "success"}) == []
    assert [_] = Webhooks.emit(repository, "review.landed", %{"revision" => "abc"})
    [delivery] = Webhooks.claim()

    result =
      Webhooks.deliver(
        delivery,
        fn url, headers, body ->
          send(self(), {:request, url, Map.new(headers), body})
          {:ok, 204, "accepted"}
        end,
        resolver
      )

    assert result.state == "delivered"
    assert result.attempt == 1
    assert result.status == 204
    assert_receive {:request, "https://hooks.example.test/events", headers, body}
    assert headers["x-flurry-delivery"] == delivery.id

    assert headers["x-flurry-signature"] ==
             Webhooks.sign(created.secret, headers["x-flurry-timestamp"], body)

    assert Jason.decode!(body)["payload"] == %{"revision" => "abc"}

    assert [_] = Webhooks.emit(repository, "review.landed", %{"revision" => "def"})
    [failed] = Webhooks.claim()

    pending =
      Webhooks.deliver(failed, fn _, _, _ -> {:error, "connection refused"} end, resolver)

    assert pending.state == "pending"
    assert pending.attempt == 1
    assert DateTime.compare(pending.next_attempt_at, DateTime.utc_now()) == :gt

    dead =
      Repo.get!(WebhookDelivery, pending.id)
      |> Ecto.Changeset.change(state: "delivering", attempt: 5)
      |> Repo.update!()
      |> Webhooks.deliver(fn _, _, _ -> {:ok, 503, "unavailable"} end, resolver)

    assert dead.state == "dead"
    assert dead.attempt == 5
    assert dead.status == 503
  end

  test "commit status contexts update in place and emit repository events" do
    owner = user()
    repository = Repositories.create(owner, %{"name" => "checks"})
    resolver = fn _ -> {:ok, [{93, 184, 216, 34}]} end

    hook =
      Webhooks.create(
        repository,
        owner,
        %{"url" => "https://hooks.example.test/events", "events" => ["status.updated"]},
        resolver
      )

    submitted =
      Changesets.submit(repository, owner, %{
        "base" => nil,
        "message" => "Add file",
        "files" => [%{"path" => "readme.md", "content" => "hello"}]
      })

    pending =
      Statuses.put(repository, owner, submitted.changeset.id, %{
        "context" => "quality/tests",
        "state" => "pending",
        "description" => "Running"
      })

    success =
      Statuses.put(repository, owner, submitted.changeset.id, %{
        "context" => "quality/tests",
        "state" => "success",
        "description" => "Passed",
        "target_url" => "https://checks.example.test/runs/1"
      })

    assert success.id == pending.id
    assert Statuses.summary(repository, submitted.changeset.id).state == "success"

    assert [%{state: "success", description: "Passed"}] =
             Statuses.list(repository, submitted.changeset.id)

    assert length(Webhooks.deliveries(repository, hook.webhook.id)) == 2

    assert_raise Flurry.Error, fn ->
      Statuses.put(repository, owner, submitted.changeset.id, %{
        "context" => "quality/tests",
        "state" => "unknown"
      })
    end
  end

  test "automation provenance and immutable evaluations remain attached to a revision" do
    owner = user()
    repository = Repositories.create(owner, %{"name" => "automation"})

    attrs = %{
      "base" => nil,
      "message" => "Generate parser",
      "files" => [%{"path" => "lib/parser.ex", "content" => "defmodule Parser do\nend\n"}],
      "idempotency_key" => "automation-run-1",
      "automation" => %{
        "name" => "Build worker",
        "version" => "2.4.1",
        "trigger" => "api",
        "external_id" => "run-19",
        "metadata" => %{"model" => "internal", "attempt" => 2}
      }
    }

    submitted = Changesets.submit(repository, owner, attrs)
    assert Changesets.submit(repository, owner, attrs) == submitted

    assert_raise Flurry.Error, ~r/idempotency key/, fn ->
      Changesets.submit(repository, owner, put_in(attrs, ["automation", "external_id"], "run-20"))
    end

    provenance = Automation.provenance(repository, submitted.changeset.id)
    assert provenance.name == "Build worker"
    assert provenance.version == "2.4.1"
    assert provenance.base_revision == nil
    assert provenance.metadata == %{"model" => "internal", "attempt" => 2}

    first =
      Automation.evaluate(repository, owner, submitted.changeset.id, %{
        "context" => "quality/tests",
        "state" => "failure",
        "summary" => "One regression",
        "score" => 0.82,
        "pass" => 18,
        "fail" => 1,
        "duration_ms" => 410,
        "metrics" => %{"coverage" => 91.2}
      })

    second =
      Automation.evaluate(repository, owner, submitted.changeset.id, %{
        "context" => "quality/tests",
        "state" => "success",
        "summary" => "All checks passed",
        "score" => 1.0,
        "pass" => 19,
        "fail" => 0
      })

    assert first.id != second.id

    assert Enum.map(Automation.evaluations(repository, submitted.changeset.id), & &1.state) == [
             "success",
             "failure"
           ]

    events = Activity.list(repository)
    assert Enum.any?(events, &(&1.type == "change.submitted" and &1.title == "Generate parser"))
    assert Enum.count(events, &(&1.type == "evaluation.created")) == 2

    assert_raise Flurry.Error, ~r/cannot contain/, fn ->
      Automation.submission(%{
        "name" => "Unsafe worker",
        "metadata" => %{"nested" => %{"prompt" => "private input"}}
      })
    end
  end

  defp user do
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, _} =
      Auth.signup(%{
        "name" => "Test user",
        "username" => "u" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    user
  end
end
