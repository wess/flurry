defmodule Flurry.Http.Settings do
  use Plug.Router
  import Plug.Conn
  alias Flurry.{Auth, Error, Audit}
  alias Flurry.Security.{Accounts, Agents, Sessions, Tokens, Factor, Passkeys, Vault}
  plug(:match)
  plug(:authorize)
  plug(:dispatch)

  get "/account" do
    json(conn, %{user: Auth.me(conn.assigns.user), two_factor_available: Vault.available?()})
  end

  patch "/credentials" do
    {user, token} = Accounts.change(conn.assigns.user, conn.body_params)
    rotate(conn, user, token)
  end

  patch "/preferences" do
    user = Accounts.preferences(conn.assigns.user, conn.body_params)
    json(conn, %{user: Auth.me(user)})
  end

  get "/sessions" do
    json(conn, %{sessions: Sessions.list(conn.assigns.user, conn.assigns.token)})
  end

  post "/sessions/others" do
    Sessions.revoke_others(conn.assigns.user, conn.assigns.token)
    json(conn, %{ok: true})
  end

  delete "/sessions/:id" do
    Sessions.revoke(conn.assigns.user, id)
    json(conn, %{ok: true})
  end

  get "/tokens" do
    json(conn, %{tokens: Tokens.list(conn.assigns.user)})
  end

  post "/tokens" do
    json(conn, Tokens.create(conn.assigns.user, conn.body_params))
  end

  delete "/tokens/:id" do
    Tokens.revoke(conn.assigns.user, id)
    json(conn, %{ok: true})
  end

  get "/agents" do
    json(conn, %{agents: Agents.list(conn.assigns.user)})
  end

  post "/agents" do
    json(conn, Agents.create(conn.assigns.user, conn.body_params), 201)
  end

  post "/agents/:id/rotate" do
    json(conn, Agents.rotate(conn.assigns.user, id, conn.body_params))
  end

  post "/agents/:id/revoke" do
    json(conn, Agents.revoke(conn.assigns.user, id, conn.body_params))
  end

  post "/twofactor/prepare" do
    json(conn, Factor.prepare(conn.assigns.user, conn.body_params))
  end

  post "/twofactor/enable" do
    {user, token, codes} = Factor.enable(conn.assigns.user, conn.body_params)
    rotate(conn, user, token, %{recovery_codes: codes})
  end

  post "/twofactor/disable" do
    {user, token} = Factor.disable(conn.assigns.user, conn.body_params)
    rotate(conn, user, token)
  end

  post "/twofactor/recovery-codes" do
    {user, token, codes} = Factor.regenerate(conn.assigns.user, conn.body_params)
    rotate(conn, user, token, %{recovery_codes: codes})
  end

  get "/passkeys" do
    json(conn, %{passkeys: Passkeys.list(conn.assigns.user)})
  end

  post "/passkeys/registration/options" do
    json(
      conn,
      Passkeys.registration_options(
        conn.assigns.user,
        conn.body_params,
        Passkeys.relying_party(conn)
      )
    )
  end

  post "/passkeys/registration/verify" do
    {passkey, user, token} = Passkeys.register(conn.assigns.user, conn.body_params)
    rotate(conn, user, token, %{passkey: passkey})
  end

  patch "/passkeys/:id" do
    json(conn, %{passkey: Passkeys.rename(conn.assigns.user, id, conn.body_params)})
  end

  delete "/passkeys/:id" do
    {user, token} = Passkeys.revoke(conn.assigns.user, id, conn.body_params)
    rotate(conn, user, token)
  end

  get "/audit" do
    json(conn, %{events: Audit.list(conn.assigns.user)})
  end

  get "/removed" do
    json(conn, %{repositories: Flurry.Engine.Settings.removed(conn.assigns.user)})
  end

  post "/removed/:id/restore" do
    Flurry.Engine.Settings.restore(conn.assigns.user, id)
    json(conn, %{ok: true})
  end

  match _ do
    json(conn, %{error: "Settings endpoint not found"}, 404)
  end

  defp authorize(conn, _) do
    unless conn.assigns.user && conn.assigns.credential.kind == :session,
      do: Error.fail("Sign in with a browser session to manage account settings", 401)

    if conn.method in ["POST", "PATCH"] and
         not Flurry.Http.Limits.allow?(Flurry.Http.Client.address(conn)),
       do: Error.fail("Too many attempts; try again in a minute", 429)

    conn
  end

  defp rotate(conn, user, token, extra \\ %{}) do
    options = [
      http_only: true,
      same_site: "Strict",
      max_age: 604_800,
      secure: Application.get_env(:flurry, :secure_cookies, false)
    ]

    options =
      case Application.get_env(:flurry, :cookie_domain) do
        nil -> options
        domain -> Keyword.put(options, :domain, domain)
      end

    conn
    |> put_resp_cookie("flurry", token, options)
    |> json(Map.merge(%{user: Auth.me(user), token: token}, extra))
  end

  defp json(conn, value, status \\ 200),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, Jason.encode!(value))
end
