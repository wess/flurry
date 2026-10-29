defmodule Flurry.Engine.SourceConnections do
  import Ecto.Query

  alias Flurry.{Audit, Auth, Error, Repo, Store.Objects}
  alias Flurry.Integrations.SourceProvider
  alias Flurry.Schema.SourceConnection
  alias Flurry.Security.Vault

  @state_seconds 600

  def providers do
    configured()
    |> Enum.map(fn {id, config} -> %{id: id, name: config.name, host: config.host} end)
    |> Enum.sort_by(& &1.name)
  end

  def configured?, do: map_size(configured()) > 0

  def list(user) do
    Repo.all(
      from(c in SourceConnection,
        where: c.user_id == ^user.id,
        order_by: [asc: c.provider, asc: c.account]
      )
    )
    |> Enum.map(&public/1)
  end

  def start(user, provider) do
    config = provider!(provider)
    state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    now = DateTime.utc_now()

    Repo.delete_all(from(s in "source_connection_states", where: s.expires_at <= ^now))

    Repo.insert_all("source_connection_states", [
      %{
        digest: Objects.digest(state),
        user_id: Ecto.UUID.dump!(user.id),
        provider: provider,
        expires_at: DateTime.add(now, @state_seconds),
        inserted_at: now
      }
    ])

    query =
      URI.encode_query(%{
        "client_id" => config.client_id,
        "redirect_uri" => callback_url(),
        "response_type" => "code",
        "scope" => config.scope,
        "state" => state
      })

    %{authorization_url: config.authorize_url <> "?" <> query}
  end

  def finish(params) do
    state = bounded(params["state"], "Invalid source connection state", 200)
    code = bounded(params["code"], "The source connection was not authorized", 1000)
    now = DateTime.utc_now()

    row =
      Repo.transaction(fn ->
        row =
          Repo.one(
            from(s in "source_connection_states",
              where: s.digest == ^Objects.digest(state),
              lock: "FOR UPDATE",
              select: %{
                user_id: type(s.user_id, Ecto.UUID),
                provider: s.provider,
                expires_at: s.expires_at
              }
            )
          ) || Error.fail("The source connection has expired; try again", 400)

        Repo.delete_all(
          from(s in "source_connection_states", where: s.digest == ^Objects.digest(state))
        )

        if NaiveDateTime.compare(row.expires_at, DateTime.to_naive(now)) != :gt,
          do: Error.fail("The source connection has expired; try again", 400)

        row
      end)
      |> elem(1)

    config = provider!(row.provider)
    tokens = adapter().exchange(config, code, callback_url())
    ensure_scopes!(config, tokens.scopes)
    account = adapter().account(config, tokens.access_token)
    user = Repo.get!(Flurry.Schema.User, row.user_id)
    connection = save(user, row.provider, config.host, account, tokens)
    Audit.record(user, "source.connection", nil, %{provider: row.provider, account: account})
    public(connection)
  end

  def create(user, attrs) do
    host = String.downcase(String.trim(attrs["host"] || ""))

    unless host in Flurry.Instance.hosts(),
      do: Error.fail("Choose an allowed Git host")

    username = Auth.text!(attrs["username"] || "git", "Git username", 200)
    credentials = Flurry.Git.Remote.credentials(Map.put(attrs, "username", username))
    if credentials.token == "", do: Error.fail("Enter an access token")

    connection =
      save(user, "other", host, username, %{
        access_token: credentials.token,
        refresh_token: nil,
        expires_at: nil,
        scopes: []
      })

    Audit.record(user, "source.connection", nil, %{provider: "other", host: host})
    public(connection)
  end

  def delete(user, id) do
    connection = get!(user, id)
    Repo.delete!(connection)
    Audit.record(user, "source.connection.revoke", nil, %{provider: connection.provider})
    :ok
  end

  def repositories(user, id, query) do
    connection = get!(user, id)

    if connection.provider == "other",
      do: Error.fail("Paste a clone URL for this connection", 400)

    query = if is_binary(query), do: String.trim(query), else: ""
    if byte_size(query) > 200, do: Error.fail("Search is too long")
    {connection, token} = access_token(connection)
    config = provider!(connection.provider)
    adapter().repositories(config, token, query)
  end

  def resolve(_user, nil, _host), do: {nil, %{username: "git", token: ""}}
  def resolve(user, "", host), do: resolve(user, nil, host)

  def resolve(user, id, host) do
    connection = get!(user, id)

    unless connection.host == host,
      do: Error.fail("The selected connection does not match the repository host")

    {connection, credentials(connection)}
  end

  def credentials(user, %SourceConnection{} = connection) do
    unless connection.user_id == user.id, do: Error.fail("Source connection not found", 404)
    {_connection, token} = access_token(connection)
    %{username: username(connection), token: token}
  end

  def public(connection),
    do: Map.take(connection, [:id, :provider, :host, :account, :expires_at, :inserted_at])

  defp credentials(connection) do
    {_connection, token} = access_token(connection)
    %{username: username(connection), token: token}
  end

  defp access_token(connection) do
    connection = maybe_refresh(connection)
    {connection, Vault.decrypt(connection.access_token, context(connection))}
  end

  defp maybe_refresh(%{expires_at: nil} = connection), do: connection

  defp maybe_refresh(connection) do
    if DateTime.compare(connection.expires_at, DateTime.add(DateTime.utc_now(), 120)) == :gt do
      connection
    else
      unless connection.refresh_token,
        do: Error.fail("The source connection expired; reconnect it", 401)

      config = provider!(connection.provider)
      refresh = Vault.decrypt(connection.refresh_token, context(connection))
      tokens = adapter().refresh(config, refresh)
      save_tokens(connection, tokens)
    end
  end

  defp save(user, provider, host, account, tokens) do
    existing =
      Repo.one(
        from(c in SourceConnection,
          where: c.user_id == ^user.id and c.provider == ^provider and c.host == ^host
        )
      )

    connection =
      existing ||
        %SourceConnection{
          id: Ecto.UUID.generate(),
          user_id: user.id,
          provider: provider,
          host: host
        }

    connection
    |> Ecto.Changeset.change([account: account] ++ token_fields(connection, tokens))
    |> Repo.insert_or_update!()
  end

  defp save_tokens(connection, tokens) do
    connection
    |> Ecto.Changeset.change(token_fields(connection, tokens))
    |> Repo.update!()
  end

  defp token_fields(connection, tokens) do
    context = context(connection)

    [
      access_token: Vault.encrypt(tokens.access_token, context),
      refresh_token:
        if(tokens.refresh_token,
          do: Vault.encrypt(tokens.refresh_token, context),
          else: connection.refresh_token
        ),
      expires_at: tokens.expires_at,
      scopes: if(tokens.scopes in [nil, []], do: connection.scopes || [], else: tokens.scopes)
    ]
  end

  defp get!(user, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)),
      do: Error.fail("Source connection not found", 404)

    Repo.one(from(c in SourceConnection, where: c.id == ^id and c.user_id == ^user.id)) ||
      Error.fail("Source connection not found", 404)
  end

  defp username(%{provider: "github"}), do: "x-access-token"
  defp username(%{provider: "gitlab"}), do: "oauth2"
  defp username(connection), do: connection.account

  defp context(connection),
    do:
      "flurry.source-connection.v1:#{connection.user_id}:#{connection.provider}:#{connection.host}"

  defp callback_url,
    do: Application.fetch_env!(:flurry, :public_url) <> "/api/source-connections/callback"

  defp provider!(provider),
    do: Map.get(configured(), provider) || Error.fail("Source provider is not configured", 404)

  defp configured, do: Application.get_env(:flurry, :source_providers, %{})
  defp adapter, do: Application.get_env(:flurry, :source_provider_adapter, SourceProvider)

  defp ensure_scopes!(config, scopes) do
    required = config[:required_scopes] || []

    unless is_list(scopes) and Enum.all?(required, &(&1 in scopes)),
      do: Error.fail("The source connection did not grant its required read access", 403)
  end

  defp bounded(value, message, limit) do
    unless is_binary(value) and byte_size(value) in 1..limit, do: Error.fail(message, 400)
    value
  end
end
