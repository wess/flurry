defmodule Flurry.SourceProviderFixture do
  def exchange(config, code, redirect_uri) do
    send(Application.fetch_env!(:flurry, :source_provider_test), {
      :exchange,
      config.provider,
      code,
      redirect_uri
    })

    %{
      access_token: "provider access token",
      refresh_token: "provider refresh token",
      expires_at: DateTime.add(DateTime.utc_now(), 3600),
      scopes: ["repo"]
    }
  end

  def account(_config, "provider access token"), do: "connected-user"

  def repositories(_config, "provider access token", query) do
    [%{id: "1", name: "project", full_name: "connected-user/project", query: query}]
  end

  def refresh(_config, "provider refresh token") do
    %{
      access_token: "refreshed access token",
      refresh_token: "refreshed refresh token",
      expires_at: DateTime.add(DateTime.utc_now(), 3600),
      scopes: ["repo"]
    }
  end
end

defmodule Flurry.SourceConnectionsTest do
  use ExUnit.Case, async: false
  import Ecto.Query

  alias Flurry.{Auth, Repo, Store.Objects}
  alias Flurry.Engine.SourceConnections
  alias Flurry.Schema.SourceConnection

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    id = Ecto.UUID.generate() |> String.replace("-", "")

    {user, _token} =
      Auth.signup(%{
        "name" => "Connection owner",
        "username" => "c" <> id,
        "email" => id <> "@example.test",
        "password" => "correct horse battery staple"
      })

    keys = [
      :encryption_key,
      :git_hosts,
      :public_url,
      :source_provider_adapter,
      :source_provider_test,
      :source_providers
    ]

    previous = Map.new(keys, &{&1, Application.get_env(:flurry, &1)})
    Application.put_env(:flurry, :encryption_key, :crypto.strong_rand_bytes(32))
    Application.put_env(:flurry, :git_hosts, ["github.com", "git.example.com"])
    Application.put_env(:flurry, :public_url, "https://flurry.example")
    Application.put_env(:flurry, :source_provider_adapter, Flurry.SourceProviderFixture)
    Application.put_env(:flurry, :source_provider_test, self())

    Application.put_env(:flurry, :source_providers, %{
      "github" => %{
        provider: "github",
        name: "GitHub",
        host: "github.com",
        authorize_url: "https://github.example/authorize",
        token_url: "https://github.example/token",
        api_url: "https://api.github.example",
        scope: "repo",
        required_scopes: ["repo"],
        client_id: "client",
        client_secret: "secret"
      }
    })

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:flurry, key)
        {key, value} -> Application.put_env(:flurry, key, value)
      end)
    end)

    %{user: user}
  end

  test "generic connections encrypt credentials and remain account scoped", %{user: user} do
    public =
      SourceConnections.create(user, %{
        "host" => "git.example.com",
        "username" => "source-user",
        "token" => "plain secret token"
      })

    refute Map.has_key?(public, :access_token)
    connection = Repo.get!(SourceConnection, public.id)
    refute connection.access_token == "plain secret token"

    {resolved, credentials} =
      SourceConnections.resolve(user, connection.id, "git.example.com")

    assert resolved.id == connection.id
    assert credentials == %{username: "source-user", token: "plain secret token"}

    assert_raise Flurry.Error, ~r/does not match/, fn ->
      SourceConnections.resolve(user, connection.id, "github.com")
    end

    {other, _} =
      Auth.signup(%{
        "name" => "Other user",
        "username" => "other" <> String.replace(Ecto.UUID.generate(), "-", ""),
        "email" => Ecto.UUID.generate() <> "@example.test",
        "password" => "correct horse battery staple"
      })

    assert_raise Flurry.Error, ~r/not found/, fn ->
      SourceConnections.resolve(other, connection.id, "git.example.com")
    end
  end

  test "OAuth state is single-use and tokens never enter public connection data", %{user: user} do
    result = SourceConnections.start(user, "github")
    uri = URI.parse(result.authorization_url)
    query = URI.decode_query(uri.query)
    state = query["state"]

    assert uri.host == "github.example"
    assert query["client_id"] == "client"

    assert query["redirect_uri"] ==
             "https://flurry.example/api/source-connections/callback"

    digest = Repo.one!(from(s in "source_connection_states", select: s.digest))
    assert digest == Objects.digest(state)
    refute digest == state

    public = SourceConnections.finish(%{"state" => state, "code" => "temporary code"})
    assert public.account == "connected-user"
    refute inspect(public) =~ "provider access token"

    assert_receive {
      :exchange,
      "github",
      "temporary code",
      "https://flurry.example/api/source-connections/callback"
    }

    assert SourceConnections.repositories(user, public.id, "proj") == [
             %{
               id: "1",
               name: "project",
               full_name: "connected-user/project",
               query: "proj"
             }
           ]

    assert_raise Flurry.Error, ~r/expired/, fn ->
      SourceConnections.finish(%{"state" => state, "code" => "replay"})
    end
  end

  test "connections can be revoked without exposing their secret", %{user: user} do
    connection =
      SourceConnections.create(user, %{
        "host" => "git.example.com",
        "username" => "git",
        "token" => "secret"
      })

    assert length(SourceConnections.list(user)) == 1
    assert :ok == SourceConnections.delete(user, connection.id)
    assert SourceConnections.list(user) == []
  end
end
