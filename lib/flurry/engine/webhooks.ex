defmodule Flurry.Engine.Webhooks do
  import Ecto.Query
  alias Flurry.{Error, Repo}
  alias Flurry.Engine.Repositories
  alias Flurry.Integrations.Endpoint
  alias Flurry.Schema.{Webhook, WebhookDelivery}
  alias Flurry.Security.Vault

  @max_attempts 5
  @secret_context "flurry.webhook.v1"

  def create(repository, actor, attrs, resolver \\ nil) do
    unless Repositories.permitted?(repository, actor, :manage),
      do: Error.fail("Owner access required", 403)

    id = Ecto.UUID.generate()
    url = validate_url!(attrs["url"], resolver)
    events = events!(attrs["events"] || ["*"])
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    webhook =
      Repo.insert!(%Webhook{
        id: id,
        repository_id: repository.id,
        creator_id: actor.id,
        url: url,
        secret: Vault.encrypt(secret, context(id)),
        events: events
      })

    %{webhook: public(webhook), secret: secret}
  end

  def list(repository) do
    Repo.all(
      from(w in Webhook,
        where: w.repository_id == ^repository.id,
        order_by: [asc: w.inserted_at]
      )
    )
    |> Enum.map(&public/1)
  end

  def update(repository, actor, id, attrs, resolver \\ nil) do
    unless Repositories.permitted?(repository, actor, :manage),
      do: Error.fail("Owner access required", 403)

    webhook = get!(repository, id)

    values =
      %{}
      |> optional(attrs, "url", fn value -> validate_url!(value, resolver) end)
      |> optional(attrs, "events", &events!/1)
      |> optional(attrs, "enabled", &boolean!/1)

    webhook |> Ecto.Changeset.change(values) |> Repo.update!() |> public()
  end

  def delete(repository, actor, id) do
    unless Repositories.permitted?(repository, actor, :manage),
      do: Error.fail("Owner access required", 403)

    Repo.delete!(get!(repository, id))
    :ok
  end

  def emit(repository, event, payload) when is_map(payload) do
    event = event!(event)
    normalized = normalize_payload!(payload)
    now = DateTime.utc_now()

    hooks =
      Repo.all(
        from(w in Webhook,
          where:
            w.repository_id == ^repository.id and w.enabled and
              (fragment("? = ANY(?)", ^event, w.events) or fragment("? = ANY(?)", "*", w.events))
        )
      )

    Enum.map(hooks, fn webhook ->
      Repo.insert!(%WebhookDelivery{
        id: Ecto.UUID.generate(),
        webhook_id: webhook.id,
        repository_id: repository.id,
        event: event,
        payload: normalized,
        next_attempt_at: now
      })
    end)
  end

  def deliveries(repository, webhook_id, limit \\ 50) do
    limit = limit |> max(1) |> min(100)

    Repo.all(
      from(d in WebhookDelivery,
        where: d.repository_id == ^repository.id and d.webhook_id == ^webhook_id,
        order_by: [desc: d.inserted_at],
        limit: ^limit
      )
    )
    |> Enum.map(&delivery_public/1)
  end

  def claim(limit \\ 10) do
    limit = limit |> max(1) |> min(50)
    now = DateTime.utc_now()
    stale = DateTime.add(now, -300, :second)

    {:ok, deliveries} =
      Repo.transaction(fn ->
        Repo.all(
          from(d in WebhookDelivery,
            where:
              d.attempt < @max_attempts and
                ((d.state == "pending" and d.next_attempt_at <= ^now) or
                   (d.state == "delivering" and d.updated_at <= ^stale)),
            order_by: [asc: d.next_attempt_at, asc: d.inserted_at],
            limit: ^limit,
            lock: "FOR UPDATE SKIP LOCKED"
          )
        )
        |> Enum.map(fn delivery ->
          delivery
          |> Ecto.Changeset.change(state: "delivering", attempt: delivery.attempt + 1)
          |> Repo.update!()
        end)
      end)

    deliveries
  end

  def deliver(delivery, requester \\ &request/3, resolver \\ nil) do
    delivery = Repo.get!(WebhookDelivery, delivery.id)
    webhook = Repo.get!(Webhook, delivery.webhook_id)
    url = validate_url!(webhook.url, resolver)
    timestamp = DateTime.utc_now() |> DateTime.to_unix() |> Integer.to_string()

    body =
      Jason.encode!(%{
        "id" => delivery.id,
        "event" => delivery.event,
        "repository_id" => delivery.repository_id,
        "payload" => delivery.payload
      })

    secret = Vault.decrypt(webhook.secret, context(webhook.id))
    signature = sign(secret, timestamp, body)

    headers = [
      {"content-type", "application/json"},
      {"user-agent", "Flurry-Hook/1"},
      {"x-flurry-delivery", delivery.id},
      {"x-flurry-event", delivery.event},
      {"x-flurry-timestamp", timestamp},
      {"x-flurry-signature", signature}
    ]

    result =
      try do
        requester.(url, headers, body)
      rescue
        error -> {:error, Exception.message(error)}
      catch
        kind, reason -> {:error, Exception.format(kind, reason, [])}
      end

    finish(delivery, signature, result)
  rescue
    error in Flurry.Error -> finish(delivery, nil, {:error, error.message})
  end

  def process(limit \\ 10, requester \\ &request/3, resolver \\ nil) do
    claim(limit) |> Enum.map(&deliver(&1, requester, resolver))
  end

  def sign(secret, timestamp, body) do
    digest = :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> body)
    "sha256=" <> Base.encode16(digest, case: :lower)
  end

  def public(webhook) do
    %{
      id: webhook.id,
      url: webhook.url,
      events: webhook.events,
      enabled: webhook.enabled,
      inserted_at: webhook.inserted_at,
      updated_at: webhook.updated_at
    }
  end

  def delivery_public(delivery) do
    %{
      id: delivery.id,
      webhook_id: delivery.webhook_id,
      event: delivery.event,
      state: delivery.state,
      attempt: delivery.attempt,
      status: delivery.status,
      response: delivery.response,
      error: delivery.error,
      next_attempt_at: delivery.next_attempt_at,
      inserted_at: delivery.inserted_at,
      updated_at: delivery.updated_at
    }
  end

  defp get!(repository, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)), do: Error.fail("Webhook not found", 404)

    Repo.one(from(w in Webhook, where: w.id == ^id and w.repository_id == ^repository.id)) ||
      Error.fail("Webhook not found", 404)
  end

  defp finish(delivery, signature, {:ok, status, response}) when status in 200..299 do
    delivery
    |> Ecto.Changeset.change(
      state: "delivered",
      status: status,
      response: text(response),
      error: nil,
      signature: signature
    )
    |> Repo.update!()
    |> delivery_public()
  end

  defp finish(delivery, signature, {:ok, status, response}) do
    retry(delivery, signature, status, text(response), "Endpoint returned HTTP #{status}")
  end

  defp finish(delivery, signature, {:error, error}) do
    retry(delivery, signature, nil, nil, text(error))
  end

  defp finish(delivery, signature, other) do
    retry(delivery, signature, nil, nil, "Invalid delivery response: #{text(inspect(other))}")
  end

  defp retry(delivery, signature, status, response, error) do
    attempt = max(delivery.attempt, 1)
    dead = attempt >= @max_attempts
    delay = min(trunc(:math.pow(2, attempt - 1)) * 30, 3600)

    delivery
    |> Ecto.Changeset.change(
      state: if(dead, do: "dead", else: "pending"),
      attempt: attempt,
      status: status,
      response: response,
      error: error,
      signature: signature,
      next_attempt_at: DateTime.add(DateTime.utc_now(), delay, :second)
    )
    |> Repo.update!()
    |> delivery_public()
  end

  defp request(url, headers, body) do
    case Req.post(url,
           headers: headers,
           body: body,
           redirect: false,
           retry: false,
           receive_timeout: 10_000,
           connect_options: [timeout: 5_000]
         ) do
      {:ok, response} -> {:ok, response.status, response.body}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp validate_url!(value, nil), do: Endpoint.validate!(value)
  defp validate_url!(value, resolver), do: Endpoint.validate!(value, resolver)

  defp events!(events) when is_list(events) and length(events) in 1..50 do
    events = events |> Enum.map(&event!/1) |> Enum.uniq()
    if "*" in events and length(events) > 1, do: Error.fail("Wildcard webhook events stand alone")
    events
  end

  defp events!(_), do: Error.fail("Choose between 1 and 50 webhook events")

  defp event!("*"), do: "*"

  defp event!(event) when is_binary(event) do
    event = String.trim(event)

    if byte_size(event) in 1..64 and Regex.match?(~r/\A[a-z][a-z0-9]*(?:\.[a-z0-9]+)*\z/, event),
      do: event,
      else: Error.fail("Webhook event names use lowercase dot-separated words")
  end

  defp event!(_), do: Error.fail("Webhook event name is invalid")

  defp normalize_payload!(payload) do
    body = Jason.encode!(payload)
    if byte_size(body) > 262_144, do: Error.fail("Webhook payload is too large")
    Jason.decode!(body)
  rescue
    Jason.EncodeError -> Error.fail("Webhook payload must contain JSON values")
  end

  defp optional(values, attrs, key, transform) do
    if Map.has_key?(attrs, key),
      do: Map.put(values, String.to_atom(key), transform.(attrs[key])),
      else: values
  end

  defp boolean!(value) when is_boolean(value), do: value
  defp boolean!(_), do: Error.fail("Enabled must be true or false")

  defp text(nil), do: nil
  defp text(value) when is_binary(value), do: value |> String.slice(0, 4_000)
  defp text(value), do: value |> inspect() |> String.slice(0, 4_000)

  defp context(id), do: @secret_context <> ":" <> id
end
