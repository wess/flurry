# Flurry

**Source control, kept simple.**

Flurry is a Git-compatible source control system built around immutable changes,
explicit review, and a small trusted server core. Use ordinary Git over HTTPS or
SSH, work offline with the native `fsc` client, or manage a project in the browser.
Every path reaches the same repository history and review policy.

Flurry keeps source work local. Editors, builds, tests, analysis, and automation
run where they belong. The server coordinates the state a team must agree on:
repository objects, revision identity, access, reviews, policy, and retained
evidence from external systems.

The result is a source host that is easy to reason about. A submitted revision
does not change underneath a reviewer. Landing is an explicit, atomic operation.
Automation can report what it did without gaining an execution environment inside
the server.

## What Flurry is for

Flurry covers the daily work around a repository:

- any number of public and private repositories
- HTTPS and SSH Git clone, fetch, and push
- offline commits, branches, tags, merges, and diffs through `fsc`
- immutable changesets with review, comments, approvals, and protected landing
- organizations, role-based teams, agent accounts, collaborators, issues, wikis, releases, stars, and watches
- public, unlisted, and private multi-file snippets with immutable revisions and syntax highlighting
- signed webhooks, revision statuses, evaluation history, and automation provenance
- structured automated review with verified findings and revision-aware resolution history
- a local MCP server for bounded repository, review, search, and evaluation tools
- content-addressed file storage with per-file, per-project, and account storage limits
- imports from an existing Git repository and explicit synchronization with its source
- account security, passwordless passkeys, scoped tokens, authenticator codes, recovery codes, and audit history

The detailed, tested feature matrix lives in
[docs/capabilities.md](docs/capabilities.md). That document also names unsupported
formats and deliberate limits.

## Architecture

Flurry separates the source-control engine from its transport and storage edges.

```text
 Git clients        fsc        browser        external automation
      \              |            |                    /
       +-------------+------------+-------------------+
                             |
                        HTTPS / SSH API
                             |
              +--------------+---------------+
              |                              |
       repository engine               policy and review
    objects, trees, revisions       access, decisions, landing
              |                              |
              +--------------+---------------+
                             |
                 +-----------+-----------+
                 |                       |
            PostgreSQL             object storage
         metadata and refs       files and trees by hash
```

### Source identity

A changeset is a versioned, ordered record of its repository, parent, author,
message, changed paths, and provenance. Its identity is a SHA-256 digest of that
record. Database triggers prevent changesets from being updated or deleted.

Files and directory trees are separate, compressed, content-addressed objects.
Reads verify the object type and hash. Directory manifests are derived indexes;
they can be rebuilt from immutable changesets and their parents.

### Submission and landing

Submitting a change stores its objects, creates an immutable changeset, and opens
a review. It does not move `main`.

Landing locks the review and branch head, rechecks authorization and approval,
and compares every changed path with the current head. A compatible stale change
is rebased into a new immutable changeset that retains its reviewed source. A
conflict leaves the branch untouched. Advancing the ref and closing the review
happen in one database transaction.

### Local work, shared truth

Working copies, builds, tests, and analysis do not have to run on the server.
Clients publish immutable revisions and bounded result records through authenticated,
idempotent APIs. Flurry retains the actor, tool, version, outcome, and external
reference while keeping credentials, prompts, and arbitrary workloads out of the
record.

Mutable revision statuses answer "what is the latest result?" Immutable evaluation
attempts answer "what happened over time?" Repository owners choose which named
status contexts affect branch policy.

### Compatibility boundary

Flurry uses its own SHA-256 object and changeset model internally. Git object IDs,
parents, tags, and executable modes are preserved at the compatibility boundary.
Native and Git clients therefore share review and branch policy without making Git
the server's internal source of truth.

See [docs/architecture.md](docs/architecture.md) for the full consistency,
security, storage limits, and recovery design.

## Use Flurry

### In the browser

Create an account, then create a blank repository or import an existing one. The
first account on a new instance becomes its owner. New repositories are private
unless you choose public visibility.

For a browser-native change:

1. Open a repository and choose **New change**.
2. Add or replace files and submit the change.
3. Review the diff, discuss it, and record a decision.
4. Land the approved review.

The repository page exposes files, history, reviews, activity, issues, releases,
settings, clone URLs, and source synchronization from one place.

Profiles have stable `/<username>` URLs. Sign-in accepts either a username or an
email address with the account password.

The snippet surface shares small pieces of code without requiring a repository.
Snippets may contain up to twenty text files, keep immutable revision history,
offer raw-file links, and support public, unlisted, or private visibility.

### With Git

Copy the HTTPS or SSH URL shown on the repository page, then use normal Git
commands:

```sh
git clone https://flurry.example/repositories/REPOSITORY_ID.git
cd project
git switch -c feature/readme
git add .
git commit -m "Explain the architecture"
git push -u origin feature/readme
```

Topic branches advance directly when policy allows it. A push to protected
`main` creates a review and does not report an unlanded revision as the remote
head.

### With `fsc`

`fsc` is Flurry's native working-copy client. It records commits locally, works
without a network connection, and understands Flurry reviews directly.

```sh
cargo install --path cli --locked

fsc auth login
fsc clone REPOSITORY_ID project
cd project
fsc add .
fsc commit -m "Explain the architecture"
fsc push
```

The client also supports branches, tags, two-parent merges, status, diffs,
fetch/pull, review actions, and recovery after an interrupted working-copy update.
See [cli/readme.md](cli/readme.md) for its commands and safety limits.

### With MCP

`fsc mcp` serves Flurry tools over stdio for local assistants and development
tools. It uses the same saved credential and server-side authorization as other
`fsc` commands. The default surface is read-only.

```sh
fsc --server https://flurry.example auth login --token-stdin
fsc --server https://flurry.example mcp
```

A client configuration points directly at the executable:

```json
{
  "mcpServers": {
    "flurry": {
      "command": "/absolute/path/to/fsc",
      "args": ["--server", "https://flurry.example", "mcp"]
    }
  }
}
```

Start with `mcp --allow-writes` only when the client needs to append review
comments or immutable evaluation attempts. That flag does not bypass token scope,
repository restrictions, role checks, rate limits, or repository policy.

### Link an existing Git repository

Choose **New repository**, then **Import a repository**. Flurry imports the
selected branch and its reachable history. Import and pull never modify the
source repository.

Public repositories need only an allowed HTTPS clone URL. When a source
provider is configured, a user can connect an account, browse private repositories,
and select one without copying credentials into the import form. Other allowed
Git hosts can be connected with a username and access token.

After import:

- **Pull updates** compares the source with the last shared snapshot and opens a
  review for compatible incoming work.
- **Push to source** exports one selected, landed Flurry revision with an exact
  commit lease. A concurrent source update is rejected instead of overwritten.

One-time transfer credentials stay in worker memory and are never retained.
Connected-account tokens are encrypted with `FLURRY_SECRET_KEY`, bound to their
owner and provider, and decrypted only for an active repository transfer. They
are never returned by the API or included in logs and error records.

## Run with Docker

The quickest self-hosted installation needs only Docker with the Compose plugin:

```sh
docker compose up -d
```

Open <http://localhost:4040> and create the owner account. Compose starts Flurry
and PostgreSQL, applies database migrations before every start, and keeps database
and repository objects in named volumes. Future upgrades are:

```sh
docker compose pull
docker compose up -d
```

To build the image from this checkout instead of pulling the published image:

```sh
docker compose up --build -d
```

For a public instance, create an ignored `.env` file beside `compose.yml`:

```dotenv
FLURRY_DATABASE_PASSWORD=replace-with-a-long-url-safe-password
FLURRY_PUBLIC_URL=https://git.example.com
FLURRY_SECURE_COOKIES=true
```

Terminate TLS at a reverse proxy and forward traffic to port `4040`. The database
is not published to the host. The `database` and `objects` volumes are one recovery
set; back up both together as described in [docs/backups.md](docs/backups.md).
Additional mail, source-provider, S3, SSH, and policy settings from
[.env.example](.env.example) can be added to the `flurry.environment` section of
`compose.yml`.

The complete install, upgrade, reverse-proxy, health-check, and recovery procedure
is in [docs/docker.md](docs/docker.md).

## Run locally

You need Elixir 1.18+, Erlang/OTP 27+, PostgreSQL 14+, Bun 1.4.4+, Rust 1.89+
for `fsc`, and Git 2.40+ for Git transport and linked sources.

```sh
mix setup

cd web
bun install --frozen-lockfile
bun run build
cd ..

mix run --no-halt
```

Open <http://localhost:4040> and create the owner account. Local development
binds to `127.0.0.1:4040`, stores objects under `data/objects`, and uses a
PostgreSQL database named `flurry` by default.

Set `DATABASE_URL` when the local database role cannot create or connect to that
database. [.env.example](.env.example) documents the remaining settings for:

- public origin and trusted reverse proxies
- secure cookies, rate limits, and encryption keys
- local or S3-compatible object storage
- account email delivery
- HTTPS and SSH Git hosting
- instance-wide file and retained-storage limits

Keep credentials out of the repository. Production secrets belong in the
deployment environment, and the object store must remain private.

For MCP, prefer a short-lived, repository-scoped read token. Store it through
`fsc auth login --token-stdin` so the credential stays in the operating-system
credential store instead of a client configuration file.

## Development

Run the backend checks from the repository root:

```sh
mix format --check-formatted
mix compile --warnings-as-errors
MIX_ENV=test mix test
```

Run the browser checks from `web/`:

```sh
bun run typecheck
bun run build
bunx playwright install chromium
bun run test
```

Run the native client checks from `cli/`:

```sh
cargo fmt --check
cargo test --locked
cargo clippy --all-targets --all-features -- -D warnings
```

Backend tests use the isolated `flurrytest` database. Browser tests use
`flurrye2e`, start a server on port 4041, and write screenshots and traces to the
ignored `artifacts` directory.

## Project state

Flurry is a working development alpha. It does not execute repository code on
the server. Interactive native conflict resolution, avatar uploads, hosted build
runners, and unreachable-object collection are not implemented yet.

Production can use a private S3-compatible object store; local development uses
the same storage interface with an atomic filesystem driver. PostgreSQL and the
complete object prefix form one recovery set. Read
[docs/backups.md](docs/backups.md) before operating a public instance.

Further reading:

- [capabilities](docs/capabilities.md): implemented workflows and explicit limits
- [architecture](docs/architecture.md): data model, consistency, security, and boundaries
- [roadmap](docs/roadmap.md): planned directions, including linked Flurry engines
- [settings](docs/settings.md): instance policy, storage limits, and account controls
- [storage and recovery](docs/backups.md): backup sets, restoration, and verification
- [native client](cli/readme.md): `fsc` commands, transports, and recovery behavior

## License

Flurry is available under the [Apache License 2.0](LICENSE).
