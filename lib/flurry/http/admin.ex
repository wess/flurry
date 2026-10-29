defmodule Flurry.Http.Admin do
  use Plug.Router
  alias Flurry.{Instance, Audit, Error}
  plug(:match)
  plug(:authorize)
  plug(:dispatch)

  get "/" do
    json(conn, Instance.details(conn.assigns.user))
  end

  patch "/" do
    Flurry.Security.Accounts.confirm!(conn.assigns.user, conn.body_params)
    Instance.update(conn.assigns.user, conn.body_params)
    json(conn, Instance.details(conn.assigns.user))
  end

  get "/users" do
    json(conn, %{users: Instance.users(conn.assigns.user)})
  end

  patch "/users/:id" do
    Flurry.Security.Accounts.confirm!(conn.assigns.user, conn.body_params)
    json(conn, %{user: Instance.update_user(conn.assigns.user, id, conn.body_params)})
  end

  get "/audit" do
    json(conn, %{events: Audit.list(conn.assigns.user)})
  end

  get "/overview" do
    Flurry.Instance.admin!(conn.assigns.user)

    json(conn, %{
      users: Flurry.Repo.aggregate(Flurry.Schema.User, :count),
      repositories: Flurry.Repo.aggregate(Flurry.Schema.Repository, :count),
      owner: Flurry.Instance.owner?(conn.assigns.user)
    })
  end

  match _ do
    json(conn, %{error: "Administration endpoint not found"}, 404)
  end

  defp authorize(conn, _) do
    unless conn.assigns.credential && conn.assigns.credential.kind == :session,
      do: Error.fail("Sign in with a browser session", 401)

    Instance.admin!(conn.assigns.user)

    if conn.method in ["POST", "PATCH"] and
         not Flurry.Http.Limits.allow?(Flurry.Http.Client.address(conn)),
       do: Error.fail("Too many attempts; try again in a minute", 429)

    conn
  end

  defp json(conn, value, status \\ 200),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, Jason.encode!(value))
end
