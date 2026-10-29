defmodule Flurry.Http.Router do
  use Plug.Router
  use Plug.ErrorHandler
  require Logger
  alias Flurry.{Auth, Error, Profiles}

  alias Flurry.Engine.{
    Activity,
    Archives,
    Automation,
    Changesets,
    Collaboration,
    Keys,
    Notifications,
    Organizations,
    Policies,
    Repositories,
    RepositoryLifecycle,
    ReviewFindings,
    Reviews,
    Search,
    SourceConnections,
    Sources,
    Snippets,
    Statuses,
    Symbols,
    Trace,
    Webhooks
  }

  alias Flurry.Store.{Objects, Tree}
  alias Flurry.Security.Passkeys

  plug(Plug.Logger)
  plug(Plug.Head)
  plug(:headers)

  plug(Plug.Static,
    at: "/",
    from: :flurry,
    only: [
      "assets",
      "favicon.svg",
      "robots.txt",
      "sitemap.xml",
      "llms.txt",
      "llm.txt",
      "openapi.json"
    ]
  )

  plug(:guard_request)
  plug(:match)
  plug(:identify)
  plug(Flurry.Http.Body)
  plug(:object_body)
  plug(:dispatch)

  get "/api/health" do
    Flurry.Repo.query!("SELECT 1")
    json(conn, %{status: "ok", version: Application.spec(:flurry, :vsn) |> to_string()})
  end

  get "/api/session" do
    json(conn, %{
      ready: Auth.ready?(),
      user: if(conn.assigns.user, do: Auth.me(conn.assigns.user), else: nil),
      site: Flurry.Instance.public()
    })
  end

  get "/.well-known/passkey-endpoints" do
    rp = Passkeys.relying_party(conn)
    url = rp.origin <> "/settings/security"
    json(conn, %{enroll: url, manage: url})
  end

  post "/api/setup" do
    limited!(conn)
    {user, token} = Auth.setup(conn.body_params)
    signed_in(conn, user, token)
  end

  post "/api/signup" do
    limited!(conn)
    {user, token} = Auth.signup(conn.body_params)
    signed_in(conn, user, token)
  end

  post "/api/login" do
    limited!(conn)
    {user, token} = Auth.login(conn.body_params)
    signed_in(conn, user, token)
  end

  post "/api/passkeys/authentication/options" do
    limited!(conn)
    json(conn, Passkeys.authentication_options(Passkeys.relying_party(conn)))
  end

  post "/api/passkeys/authentication/verify" do
    limited!(conn)
    {user, token} = Passkeys.authenticate(conn.body_params)
    signed_in(conn, user, token)
  end

  post "/api/email/verification" do
    limited!(conn)
    Flurry.Security.Identity.send_verification(user!(conn))
    json(conn, %{sent: true})
  end

  post "/api/email/verify" do
    limited!(conn)
    user = Flurry.Security.Identity.verify(conn.body_params["token"])
    json(conn, %{verified: true, user: Auth.me(user)})
  end

  post "/api/password/reset-request" do
    limited!(conn)
    Flurry.Security.Identity.request_reset(conn.body_params["email"])
    json(conn, %{sent: true})
  end

  post "/api/password/reset" do
    limited!(conn)

    Flurry.Security.Identity.reset_password(
      conn.body_params["token"],
      conn.body_params["password"]
    )

    json(conn, %{reset: true})
  end

  delete "/api/session" do
    Auth.revoke(conn.assigns.token)
    conn |> delete_resp_cookie("flurry") |> json(%{ok: true})
  end

  get "/api/profiles/:username" do
    json(conn, Profiles.get(username, conn.assigns.user))
  end

  patch "/api/profile" do
    user = Profiles.update(user!(conn), conn.body_params)
    json(conn, Auth.me(user))
  end

  get "/api/keys/signing" do
    json(conn, %{keys: Keys.signing(user!(conn))})
  end

  post "/api/keys/signing" do
    json(conn, Keys.add_signing(user!(conn), conn.body_params), 201)
  end

  delete "/api/keys/signing/:key" do
    Keys.remove_signing(user!(conn), key)
    json(conn, %{ok: true})
  end

  get "/api/keys/ssh" do
    json(conn, %{keys: Keys.ssh(user!(conn))})
  end

  post "/api/keys/ssh" do
    json(conn, Keys.add_ssh(user!(conn), conn.body_params), 201)
  end

  delete "/api/keys/ssh/:key" do
    Keys.remove_ssh(user!(conn), key)
    json(conn, %{ok: true})
  end

  get "/api/notifications" do
    conn = fetch_query_params(conn)
    json(conn, Notifications.list(user!(conn), conn.params["unread"] == "true"))
  end

  post "/api/notifications/read-all" do
    json(conn, Notifications.read_all(user!(conn)))
  end

  post "/api/notifications/:notification/read" do
    json(conn, Notifications.read(user!(conn), notification))
  end

  forward("/api/settings", to: Flurry.Http.Settings)
  forward("/api/admin", to: Flurry.Http.Admin)

  get "/api/explore" do
    json(conn, %{repositories: Repositories.explore()})
  end

  get "/api/snippets" do
    conn = fetch_query_params(conn)
    json(conn, %{snippets: Snippets.list(conn.assigns.user, conn.params)})
  end

  post "/api/snippets" do
    limited!(conn)
    json(conn, Snippets.create(user!(conn), conn.body_params), 201)
  end

  get "/api/snippets/:slug/raw/*path" do
    conn = fetch_query_params(conn)

    {name, content} =
      Snippets.raw(conn.assigns.user, slug, Enum.join(path, "/"), conn.params["version"])

    filename = String.replace(name, ["\"", "\r", "\n"], "")

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("content-disposition", ~s(inline; filename="#{filename}"))
    |> send_resp(200, content)
  end

  get "/api/snippets/:slug" do
    conn = fetch_query_params(conn)
    json(conn, Snippets.get(conn.assigns.user, slug, conn.params["version"]))
  end

  patch "/api/snippets/:slug" do
    json(conn, Snippets.update(user!(conn), slug, conn.body_params))
  end

  delete "/api/snippets/:slug" do
    Snippets.delete(user!(conn), slug)
    json(conn, %{ok: true})
  end

  post "/api/snippets/:slug/fork" do
    json(conn, Snippets.fork(user!(conn), slug), 201)
  end

  post "/api/snippets/:slug/star" do
    json(conn, Snippets.star(user!(conn), slug, conn.body_params["enabled"]))
  end

  get "/api/organizations" do
    json(conn, %{organizations: Organizations.list(user!(conn))})
  end

  post "/api/organizations" do
    organization = Organizations.create(user!(conn), conn.body_params)
    json(conn, Organizations.public(organization), 201)
  end

  get "/api/organizations/:organization" do
    user = user!(conn)
    organization = Organizations.get(user, organization)
    json(conn, Organizations.detail(organization, user))
  end

  post "/api/organizations/:organization/members" do
    user = user!(conn)
    organization = Organizations.get(user, organization, :manage)
    json(conn, Organizations.member(organization, user, conn.body_params), 201)
  end

  delete "/api/organizations/:organization/members/:member" do
    user = user!(conn)
    organization = Organizations.get(user, organization, :manage)
    Organizations.remove_member(organization, user, member)
    json(conn, %{ok: true})
  end

  post "/api/organizations/:organization/teams" do
    user = user!(conn)
    organization = Organizations.get(user, organization, :manage)
    team = Organizations.create_team(organization, user, conn.body_params)
    json(conn, Organizations.team_public(team), 201)
  end

  post "/api/organizations/:organization/teams/:team/members" do
    user = user!(conn)
    organization = Organizations.get(user, organization)
    team = Organizations.get_team(organization, team)
    Organizations.add_team_member(team, user, conn.body_params)
    json(conn, %{ok: true}, 201)
  end

  delete "/api/organizations/:organization/teams/:team/members/:member" do
    user = user!(conn)
    organization = Organizations.get(user, organization)
    team = Organizations.get_team(organization, team)
    Organizations.remove_team_member(team, user, member)
    json(conn, %{ok: true})
  end

  put "/api/organizations/:organization/teams/:team/repositories/:repository" do
    user = user!(conn)
    organization = Organizations.get(user, organization, :manage)
    team = Organizations.get_team(organization, team)
    repository = Repositories.get(user, repository, :manage)
    Organizations.grant(team, user, repository, conn.body_params["role"])
    json(conn, %{ok: true})
  end

  delete "/api/organizations/:organization/teams/:team/repositories/:repository" do
    user = user!(conn)
    organization = Organizations.get(user, organization, :manage)
    team = Organizations.get_team(organization, team)
    Organizations.revoke(team, user, repository)
    json(conn, %{ok: true})
  end

  get "/api/repositories" do
    repositories = Repositories.list(user!(conn))
    scope = conn.assigns.credential.repository_id

    json(conn, %{
      repositories:
        if(scope, do: Enum.filter(repositories, &(&1.id == scope)), else: repositories)
    })
  end

  post "/api/repositories" do
    repository = Repositories.create(user!(conn), conn.body_params)
    json(conn, Repositories.public(repository), 201)
  end

  post "/api/repositories/:id/duplicate" do
    user = user!(conn)
    repository = Repositories.get(user, id)
    copy = RepositoryLifecycle.duplicate(repository, user, conn.body_params)
    json(conn, Repositories.public(copy), 201)
  end

  post "/api/repositories/:id/transfer" do
    limited!(conn)
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    json(conn, RepositoryLifecycle.request_transfer(repository, user, conn.body_params), 201)
  end

  get "/api/repository-transfers" do
    json(conn, %{transfers: RepositoryLifecycle.transfers(user!(conn))})
  end

  post "/api/repository-transfers/:transfer/accept" do
    json(conn, RepositoryLifecycle.accept_transfer(user!(conn), transfer))
  end

  post "/api/repository-transfers/:transfer/cancel" do
    json(conn, RepositoryLifecycle.cancel_transfer(user!(conn), transfer))
  end

  post "/api/imports" do
    repository = Sources.create(user!(conn), conn.body_params)
    json(conn, Repositories.public(repository), 202)
  end

  get "/api/source-connections" do
    user = user!(conn)

    json(conn, %{
      providers: SourceConnections.providers(),
      connections: SourceConnections.list(user)
    })
  end

  post "/api/source-connections" do
    json(conn, SourceConnections.create(user!(conn), conn.body_params), 201)
  end

  post "/api/source-connections/:provider/start" do
    limited!(conn)
    json(conn, SourceConnections.start(user!(conn), provider))
  end

  get "/api/source-connections/callback" do
    conn = fetch_query_params(conn)
    SourceConnections.finish(conn.query_params)

    conn
    |> put_resp_header("location", "/import?connected=true")
    |> send_resp(302, "")
  end

  get "/api/source-connections/:id/repositories" do
    conn = fetch_query_params(conn)
    repositories = SourceConnections.repositories(user!(conn), id, conn.query_params["query"])
    json(conn, %{repositories: repositories})
  end

  delete "/api/source-connections/:id" do
    SourceConnections.delete(user!(conn), id)
    json(conn, %{ok: true})
  end

  get "/api/repositories/:id/source" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{source: Sources.get(repository) |> Sources.public()})
  end

  post "/api/repositories/:id/source/unlink" do
    limited!(conn)
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    Flurry.Engine.Settings.unlink(repository, user, conn.body_params)
    json(conn, %{ok: true})
  end

  post "/api/repositories/:id/source/:operation" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)

    unless operation in ["import", "pull", "push"],
      do: Error.fail("Unknown source operation", 404)

    json(conn, %{source: Sources.transfer(repository, user, operation, conn.body_params)}, 202)
  end

  get "/api/repositories/:id" do
    repository = Repositories.get(conn.assigns.user, id)

    json(
      conn,
      Map.put(
        Repositories.public(repository),
        :role,
        Repositories.role(repository, conn.assigns.user)
      )
    )
  end

  patch "/api/repositories/:id" do
    limited!(conn)
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)

    json(
      conn,
      Flurry.Engine.Settings.update(repository, user, conn.body_params) |> Repositories.public()
    )
  end

  post "/api/repositories/:id/lifecycle" do
    limited!(conn)
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)

    json(
      conn,
      Flurry.Engine.Settings.lifecycle(repository, user, conn.body_params)
      |> Repositories.public()
    )
  end

  get "/api/repositories/:id/members" do
    repository = Repositories.get(user!(conn), id, :manage)
    json(conn, %{members: Flurry.Engine.Settings.members(repository)})
  end

  post "/api/repositories/:id/members" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    Flurry.Engine.Settings.member(repository, user, conn.body_params)
    json(conn, %{members: Flurry.Engine.Settings.members(repository)})
  end

  get "/api/repositories/:id/labels" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{labels: Collaboration.labels(repository)})
  end

  post "/api/repositories/:id/labels" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Collaboration.create_label(repository, conn.body_params), 201)
  end

  get "/api/repositories/:id/milestones" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{milestones: Collaboration.milestones(repository)})
  end

  post "/api/repositories/:id/milestones" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Collaboration.create_milestone(repository, user, conn.body_params), 201)
  end

  get "/api/repositories/:id/issues" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{issues: Collaboration.issues(repository, fetch_query_params(conn).params)})
  end

  post "/api/repositories/:id/issues" do
    user = user!(conn)
    repository = Repositories.get(user, id, :read)
    json(conn, Collaboration.create_issue(repository, user, conn.body_params), 201)
  end

  get "/api/repositories/:id/issues/:number" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, Collaboration.issue(repository, number))
  end

  patch "/api/repositories/:id/issues/:number" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Collaboration.update_issue(repository, number, conn.body_params))
  end

  post "/api/repositories/:id/issues/:number/comments" do
    user = user!(conn)
    repository = Repositories.get(user, id, :read)
    json(conn, Collaboration.comment(repository, number, user, conn.body_params), 201)
  end

  get "/api/repositories/:id/releases" do
    repository = Repositories.get(conn.assigns.user, id)
    drafts = conn.assigns.user && Repositories.permitted?(repository, conn.assigns.user, :write)
    json(conn, %{releases: Collaboration.releases(repository, drafts)})
  end

  post "/api/repositories/:id/releases" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Collaboration.create_release(repository, user, conn.body_params), 201)
  end

  post "/api/repositories/:id/releases/:release/assets" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Collaboration.add_asset(repository, release, conn.body_params), 201)
  end

  get "/api/repositories/:id/release-assets/:asset" do
    repository = Repositories.get(conn.assigns.user, id)
    {record, bytes} = Collaboration.asset(repository, asset)

    conn
    |> put_resp_content_type(record.content_type)
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{String.replace(record.name, "\"", "")}")
    )
    |> send_resp(200, bytes)
  end

  get "/api/repositories/:id/wiki" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{pages: Collaboration.wiki(repository)})
  end

  get "/api/repositories/:id/wiki/:slug" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, Collaboration.wiki_page(repository, slug))
  end

  put "/api/repositories/:id/wiki/:slug" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Collaboration.put_wiki(repository, user, slug, conn.body_params))
  end

  get "/api/repositories/:id/topics" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{topics: Collaboration.topics(repository)})
  end

  put "/api/repositories/:id/topics" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, %{topics: Collaboration.put_topics(repository, conn.body_params["topics"])})
  end

  put "/api/repositories/:id/watching/:kind" do
    user = user!(conn)
    repository = Repositories.get(user, id)
    json(conn, Collaboration.subscribe(repository, user, kind, conn.body_params["enabled"]))
  end

  get "/api/repositories/:id/audit" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    json(conn, %{events: Flurry.Audit.list(user, repository)})
  end

  get "/api/repositories/:id/git/:revision" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, Flurry.Git.View.public(repository, revision))
  end

  get "/api/repositories/:id/refs" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, Flurry.Engine.Refs.list(repository))
  end

  post "/api/repositories/:id/tags" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Flurry.Engine.Refs.tag(repository, user, conn.body_params))
  end

  get "/api/repositories/:id/pushes/:request" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Flurry.Engine.Transfers.receipt(repository, user, request))
  end

  post "/api/repositories/:id/pushes" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Flurry.Engine.Transfers.push(repository, user, conn.body_params))
  end

  get "/api/repositories/:id/ancestry" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)

    json(conn, %{
      ancestor:
        Flurry.Engine.Graph.ancestor?(
          repository,
          conn.params["ancestor"],
          conn.params["descendant"]
        )
    })
  end

  get "/api/repositories/:id/mergebase" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)

    json(conn, %{
      base: Flurry.Engine.Graph.merge_base(repository, conn.params["left"], conn.params["right"])
    })
  end

  get "/api/repositories/:id/tree" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    revision = Changesets.resolve(repository, conn.params["revision"])
    path = conn.params["path"] || ""
    if path != "", do: Tree.path!(path)
    root = Changesets.root(repository, revision)
    json(conn, %{revision: revision, path: path, entries: Tree.list(root, path)})
  end

  get "/api/repositories/:id/file" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    revision = Changesets.resolve(repository, conn.params["revision"])
    path = Tree.path!(conn.params["path"])
    root = Changesets.root(repository, revision)
    entry = Tree.entry(root, path)
    unless entry && entry["type"] == "blob", do: Error.fail("File not found", 404)

    if conn.params["raw"] == "true" do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header("content-disposition", "attachment")
      |> send_resp(200, Objects.get(:blob, entry["hash"]))
    else
      json(
        conn,
        Map.merge(Changesets.contents(entry["hash"], conn.params["preview"] == "true"), %{
          path: path,
          hash: entry["hash"],
          revision: revision
        })
      )
    end
  end

  get "/api/repositories/:id/history" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    revision = Changesets.resolve(repository, conn.params["revision"])
    json(conn, %{changesets: Changesets.history(repository, revision)})
  end

  get "/api/repositories/:id/activity" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{events: Activity.list(repository)})
  end

  get "/api/repositories/:id/archive" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    revision = Changesets.resolve(repository, conn.params["revision"])
    archive = Archives.create(repository, revision)
    filename = repository.name <> "-" <> String.slice(revision, 0, 12) <> ".tar.gz"

    conn
    |> put_resp_content_type("application/gzip")
    |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
    |> send_resp(200, archive)
  end

  get "/api/repositories/:id/compare" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    base = conn.params["base"] || Error.fail("A base revision is required")
    head = conn.params["head"] || Error.fail("A head revision is required")
    base = Changesets.get(repository, base).id
    head = Changesets.get(repository, head).id
    json(conn, Trace.compare(repository, base, head))
  end

  get "/api/repositories/:id/path-history" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    revision = Changesets.resolve(repository, conn.params["revision"])
    json(conn, Trace.path_history(repository, revision, conn.params["path"]))
  end

  get "/api/repositories/:id/blame" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    revision = Changesets.resolve(repository, conn.params["revision"])
    json(conn, Trace.blame(repository, revision, conn.params["path"]))
  end

  get "/api/repositories/:id/search" do
    conn = fetch_query_params(conn)
    repository = Repositories.get(conn.assigns.user, id)
    revision = Changesets.resolve(repository, conn.params["revision"])

    result =
      case conn.params["type"] || "code" do
        "code" -> Search.code(repository, revision, conn.params)
        "path" -> Search.paths(repository, revision, conn.params)
        _ -> Error.fail("Choose code or path search")
      end

    json(conn, result)
  end

  post "/api/repositories/:id/changesets" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)

    attrs =
      case get_req_header(conn, "idempotency-key") do
        [] -> conn.body_params
        [key] -> Map.put(conn.body_params, "idempotency_key", key)
        _ -> Error.fail("Send one Idempotency-Key header")
      end

    json(conn, Changesets.submit(repository, user, attrs), 201)
  end

  get "/api/repositories/:id/codeowners" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{rules: Policies.codeowners(repository)})
  end

  post "/api/repositories/:id/codeowners" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    json(conn, Policies.add_codeowner(repository, user, conn.body_params), 201)
  end

  delete "/api/repositories/:id/codeowners/:rule" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    Policies.remove_codeowner(repository, user, rule)
    json(conn, %{ok: true})
  end

  get "/api/repositories/:id/deploy-keys" do
    repository = Repositories.get(user!(conn), id, :manage)
    json(conn, %{keys: Keys.deploy(repository)})
  end

  post "/api/repositories/:id/deploy-keys" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    json(conn, Keys.add_deploy(repository, user, conn.body_params), 201)
  end

  delete "/api/repositories/:id/deploy-keys/:key" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    Keys.remove_deploy(repository, user, key)
    json(conn, %{ok: true})
  end

  get "/api/repositories/:id/changesets/:change/statuses" do
    repository = Repositories.get(conn.assigns.user, id)
    Changesets.get(repository, change)
    json(conn, Statuses.summary(repository, change))
  end

  get "/api/repositories/:id/changesets/:change/evaluations" do
    repository = Repositories.get(conn.assigns.user, id)

    json(conn, %{
      provenance: Automation.provenance(repository, change),
      evaluations: Automation.evaluations(repository, change)
    })
  end

  post "/api/repositories/:id/changesets/:change/evaluations" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Automation.evaluate(repository, user, change, conn.body_params), 201)
  end

  put "/api/repositories/:id/changesets/:change/statuses" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Statuses.put(repository, user, change, conn.body_params))
  end

  get "/api/repositories/:id/webhooks" do
    repository = Repositories.get(user!(conn), id, :manage)
    json(conn, %{webhooks: Webhooks.list(repository)})
  end

  post "/api/repositories/:id/webhooks" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    json(conn, Webhooks.create(repository, user, conn.body_params), 201)
  end

  patch "/api/repositories/:id/webhooks/:webhook" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    json(conn, Webhooks.update(repository, user, webhook, conn.body_params))
  end

  delete "/api/repositories/:id/webhooks/:webhook" do
    user = user!(conn)
    repository = Repositories.get(user, id, :manage)
    Webhooks.delete(repository, user, webhook)
    json(conn, %{ok: true})
  end

  get "/api/repositories/:id/webhooks/:webhook/deliveries" do
    repository = Repositories.get(user!(conn), id, :manage)
    json(conn, %{deliveries: Webhooks.deliveries(repository, webhook)})
  end

  get "/api/repositories/:id/changesets/:change" do
    repository = Repositories.get(conn.assigns.user, id)
    changeset = Changesets.get(repository, change)

    json(conn, %{
      changeset: Changesets.public(changeset),
      diff: Changesets.diff(repository, changeset) |> Symbols.annotate(),
      provenance: Automation.provenance(repository, changeset.id),
      evaluations: Automation.evaluations(repository, changeset.id)
    })
  end

  get "/api/repositories/:id/reviews" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, %{reviews: Reviews.list(repository)})
  end

  get "/api/repositories/:id/reviews/:review" do
    repository = Repositories.get(conn.assigns.user, id)
    json(conn, Reviews.get(repository, review) |> then(&Reviews.detail(repository, &1)))
  end

  get "/api/repositories/:id/reviews/:review/runs" do
    repository = Repositories.get(conn.assigns.user, id)
    item = Reviews.get(repository, review)
    json(conn, ReviewFindings.detail(repository, item))
  end

  post "/api/repositories/:id/reviews/:review/runs" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    item = Reviews.get(repository, review)
    json(conn, ReviewFindings.request(repository, item, user, conn.body_params), 201)
  end

  patch "/api/repositories/:id/reviews/:review/runs/:run" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    item = Reviews.get(repository, review)
    json(conn, ReviewFindings.update_run(repository, item, user, run, conn.body_params))
  end

  post "/api/repositories/:id/reviews/:review/runs/:run/findings" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    item = Reviews.get(repository, review)
    json(conn, ReviewFindings.add_finding(repository, item, user, run, conn.body_params), 201)
  end

  post "/api/repositories/:id/reviews/:review/findings/:finding/:action" do
    user = user!(conn)
    repository = Repositories.get(user, id)
    item = Reviews.get(repository, review)

    unless action in ["verified", "resolved", "dismissed", "reopened"],
      do: Error.fail("Finding action not found", 404)

    json(conn, ReviewFindings.act(repository, item, user, finding, action, conn.body_params))
  end

  post "/api/repositories/:id/reviews/:review/comments" do
    user = user!(conn)
    repository = Repositories.get(user, id)
    json(conn, Reviews.comment(repository, user, review, conn.body_params), 201)
  end

  post "/api/repositories/:id/reviews/:review/approve" do
    user = user!(conn)
    repository = Repositories.get(user, id, :review)
    json(conn, Reviews.approve(repository, review, user) |> Reviews.public())
  end

  post "/api/repositories/:id/reviews/:review/reject" do
    user = user!(conn)
    repository = Repositories.get(user, id, :review)
    json(conn, Reviews.reject(repository, review, user) |> Reviews.public())
  end

  post "/api/repositories/:id/reviews/:review/reviewers" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    json(conn, Reviews.request_reviewers(repository, review, user, conn.body_params["user_ids"]))
  end

  patch "/api/repositories/:id/reviews/:review/revision" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    revised = Reviews.revise(repository, review, user, conn.body_params["changeset_id"])
    json(conn, Reviews.detail(repository, revised))
  end

  post "/api/repositories/:id/reviews/:review/land" do
    user = user!(conn)
    repository = Repositories.get(user, id, :review)
    json(conn, Reviews.land(repository, review, user))
  end

  post "/repositories/:id.git/info/lfs/objects/batch" do
    operation = conn.body_params["operation"]

    {repository, user} =
      if operation == "upload" do
        user = user!(conn)
        {Repositories.get(user, id, :write), user}
      else
        {Repositories.get(conn.assigns.user, id), conn.assigns.user}
      end

    base = request_origin(conn) <> "/repositories/#{repository.id}.git/info/lfs"

    lfs_json(conn, Flurry.Git.Lfs.batch(repository, user, conn.body_params, base))
  end

  put "/repositories/:id.git/info/lfs/objects/:oid" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    conn = Flurry.Git.Lfs.receive(repository, oid, conn)
    send_resp(conn, 200, "")
  end

  get "/repositories/:id.git/info/lfs/objects/:oid" do
    repository = Repositories.get(conn.assigns.user, id)
    {object, path} = Flurry.Git.Lfs.object(repository, oid)

    conn
    |> put_resp_content_type("application/octet-stream")
    |> put_resp_header("content-length", to_string(object.size))
    |> send_file(200, path)
  end

  post "/repositories/:id.git/info/lfs/locks" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    lfs_json(conn, Flurry.Git.Lfs.create_lock(repository, user, conn.body_params), 201)
  end

  get "/repositories/:id.git/info/lfs/locks" do
    repository = Repositories.get(conn.assigns.user, id)
    lfs_json(conn, Flurry.Git.Lfs.locks(repository, fetch_query_params(conn).params))
  end

  post "/repositories/:id.git/info/lfs/locks/verify" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    lfs_json(conn, Flurry.Git.Lfs.verify_locks(repository, user))
  end

  post "/repositories/:id.git/info/lfs/locks/:lock/unlock" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    lfs_json(conn, Flurry.Git.Lfs.unlock(repository, user, lock, conn.body_params))
  end

  get "/repositories/:id.git/info/refs" do
    conn = fetch_query_params(conn)
    service = conn.params["service"]

    repository =
      if service == "git-receive-pack",
        do: Repositories.get(user!(conn), id, :write),
        else: Repositories.get(conn.assigns.user, id)

    body = Flurry.Git.SmartHttp.advertise(repository, service)

    conn
    |> put_resp_content_type("application/x-#{service}-advertisement")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, body)
  end

  post "/repositories/:id.git/git-upload-pack" do
    repository = Repositories.get(conn.assigns.user, id)
    {body, conn} = Flurry.Git.SmartHttp.read_body(conn)
    result = Flurry.Git.SmartHttp.upload(repository, body)

    conn
    |> put_resp_content_type("application/x-git-upload-pack-result")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, result)
  end

  post "/repositories/:id.git/git-receive-pack" do
    user = user!(conn)
    repository = Repositories.get(user, id, :write)
    {body, conn} = Flurry.Git.SmartHttp.read_body(conn)
    result = Flurry.Git.SmartHttp.receive(repository, user, body)

    conn
    |> put_resp_content_type("application/x-git-receive-pack-result")
    |> put_resp_header("cache-control", "no-cache")
    |> send_resp(200, result)
  end

  match "/api/*path" do
    json(conn, %{error: "Endpoint not found"}, 404)
  end

  get "/*path" do
    index = Application.app_dir(:flurry, "priv/static/index.html")

    if File.exists?(index) do
      conn
      |> put_resp_content_type("text/html")
      |> put_resp_header("cache-control", "no-cache")
      |> send_file(200, index)
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(503, "Build the frontend: cd web && bun install && bun run build")
    end
  end

  match _ do
    json(conn, %{error: "Endpoint not found"}, 404)
  end

  defp headers(conn, _) do
    conn
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-frame-options", "DENY")
    |> put_resp_header("referrer-policy", "same-origin")
    |> put_resp_header("cross-origin-opener-policy", "same-origin")
    |> put_resp_header("cross-origin-resource-policy", "same-origin")
    |> put_resp_header(
      "permissions-policy",
      "camera=(), microphone=(), geolocation=(), payment=()"
    )
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    )
  end

  defp guard_request(conn, _) do
    if conn.method not in ["GET", "HEAD", "OPTIONS"] do
      case get_req_header(conn, "origin") do
        [] ->
          :ok

        [origin] ->
          allowed = [public_origin(conn) | Application.get_env(:flurry, :allowed_origins, [])]

          unless origin in allowed,
            do: Error.fail("Cross-origin writes are not allowed", 403)

        _ ->
          Error.fail("Invalid origin", 403)
      end

      if get_req_header(conn, "sec-fetch-site") == ["cross-site"],
        do: Error.fail("Cross-site writes are not allowed", 403)
    end

    conn
  end

  defp identify(conn, _) do
    conn = fetch_cookies(conn)

    {token, bearer} =
      case get_req_header(conn, "authorization") do
        [] -> {conn.cookies["flurry"], false}
        [header] -> {authorization!(header), true}
        _ -> Error.fail("Send one Authorization header", 400)
      end

    credential = Flurry.Security.Sessions.credential(token, bearer)
    user = if credential, do: credential.user
    conn = conn |> assign(:token, token) |> assign(:credential, credential) |> assign(:user, user)
    guard_access(conn)
  end

  defp guard_access(conn) do
    path = conn.request_path

    public_auth =
      path in [
        "/api/health",
        "/api/session",
        "/api/setup",
        "/api/signup",
        "/api/login",
        "/api/passkeys/authentication/options",
        "/api/passkeys/authentication/verify",
        "/api/source-connections/callback"
      ] or
        (conn.method in ["GET", "HEAD"] and
           (path == "/api/snippets" or String.starts_with?(path, "/api/snippets/")))

    if String.starts_with?(path, "/api/") and not public_auth and
         Flurry.Instance.get().require_signin and not conn.assigns.user,
       do: Error.fail("Sign in to view this instance", 401)

    if String.starts_with?(path, "/api/") and conn.assigns.user do
      limit = Application.get_env(:flurry, :api_rate_limit, 600)

      unless Flurry.Http.Limits.allow?({:api, conn.assigns.user.id}, limit),
        do: Error.fail("Too many API requests; try again in a minute", 429)
    end

    credential = conn.assigns.credential

    if credential && credential.kind == :token do
      smart_git =
        Regex.match?(
          ~r"\A/repositories/[0-9a-f-]{36}\.git/(?:info/refs|git-upload-pack|git-receive-pack|info/lfs/.+)\z",
          path
        )

      if credential.repository_id && path == "/api/repositories" &&
           conn.method not in ["GET", "HEAD"],
         do: Error.fail("This token cannot create repositories", 403)

      snippets = String.starts_with?(path, "/api/snippets") and is_nil(credential.repository_id)

      unless String.starts_with?(path, "/api/repositories") or path == "/api/explore" or
               snippets or smart_git,
             do: Error.fail("API tokens cannot manage account or instance settings", 403)

      if credential.access == "read" and conn.method not in ["GET", "HEAD"],
        do: Error.fail("This API token has read-only access", 403)

      if conn.method not in ["GET", "HEAD"] and
           (String.contains?(path, ["/members", "/lifecycle", "/source"]) or
              Regex.match?(~r{\A/api/repositories/[^/]+\z}, path)),
         do:
           Error.fail(
             "Use a browser session to manage repository settings and source connections",
             403
           )

      if credential.repository_id && path != "/api/repositories" do
        repository = credential.repository_id

        unless path == "/api/repositories/" <> repository or
                 String.starts_with?(path, "/api/repositories/" <> repository <> "/") or
                 String.starts_with?(path, "/repositories/" <> repository <> ".git/"),
               do: Error.fail("This API token is restricted to another repository", 403)
      end
    end

    if credential && credential.kind == :agent do
      smart_git =
        Regex.match?(
          ~r"\A/repositories/[0-9a-f-]{36}\.git/(?:info/refs|git-upload-pack|git-receive-pack|info/lfs/.+)\z",
          path
        )

      unless String.starts_with?(path, "/api/repositories") or
               path == "/api/organizations" or smart_git,
             do: Error.fail("Agent credentials can only access assigned repositories", 403)

      if conn.method not in ["GET", "HEAD"] and
           (path == "/api/repositories" or
              String.contains?(path, [
                "/members",
                "/lifecycle",
                "/source",
                "/duplicate",
                "/transfer",
                "/codeowners",
                "/deploy-keys",
                "/webhooks"
              ]) or
              Regex.match?(~r{\A/api/repositories/[^/]+\z}, path)),
         do: Error.fail("Agent accounts cannot manage repositories or permissions", 403)
    end

    conn
  end

  defp user!(conn), do: conn.assigns.user || Error.fail("Sign in to continue", 401)

  defp object_body(conn, _) do
    smart_git = String.ends_with?(conn.request_path, ["/git-upload-pack", "/git-receive-pack"])

    if conn.method in ["POST", "PATCH"] and not smart_git and not is_map(conn.body_params),
      do: Error.fail("The request body must be a JSON object")

    conn
  end

  defp basic_token(encoded) do
    with {:ok, value} <- Base.decode64(encoded),
         [_username, token] <- String.split(value, ":", parts: 2),
         true <- token != "" do
      token
    else
      _ -> nil
    end
  end

  defp authorization!(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] when token != "" ->
        case String.downcase(scheme) do
          "bearer" -> token
          "basic" -> basic_token(token) || Error.fail("Invalid Authorization header", 401)
          _ -> Error.fail("Invalid Authorization header", 401)
        end

      _ ->
        Error.fail("Invalid Authorization header", 401)
    end
  end

  defp limited!(conn),
    do:
      unless(Flurry.Http.Limits.allow?(Flurry.Http.Client.address(conn)),
        do: Error.fail("Too many attempts; try again in a minute", 429)
      )

  defp signed_in(conn, user, token) do
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
    |> json(%{user: Auth.me(user), token: token})
  end

  defp lfs_json(conn, value, status \\ 200) do
    conn
    |> put_resp_content_type("application/vnd.git-lfs+json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(status, Jason.encode!(value))
  end

  defp request_origin(conn) do
    default = if conn.scheme == :https, do: 443, else: 80
    port = if conn.port == default, do: "", else: ":#{conn.port}"
    "#{conn.scheme}://#{conn.host}#{port}"
  end

  defp public_origin(conn),
    do: Application.get_env(:flurry, :public_url) || request_origin(conn)

  defp json(conn, value, status \\ 200),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(status, Jason.encode!(value))

  @impl Plug.ErrorHandler
  def handle_errors(conn, %{reason: %Error{} = error}) do
    json(conn, %{error: error.message, details: error.details}, error.status)
  end

  def handle_errors(conn, %{reason: reason}) do
    status = Plug.Exception.status(reason)
    if status >= 500, do: Logger.error("Request failed: #{Exception.message(reason)}")

    message =
      if status >= 500, do: "The request failed; check the server log", else: "Invalid request"

    json(conn, %{error: message}, status)
  end
end
