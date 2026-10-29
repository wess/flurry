# Docker installation

The supported container setup runs Flurry and PostgreSQL with Docker Compose.
It applies database migrations before the application starts, checks both services,
and stores the database and repository objects in separate named volumes.

## Start an instance

Clone the repository and start the published multi-architecture image:

```sh
git clone https://github.com/wess/flurry.git
cd flurry
docker compose up -d
```

Open <http://localhost:4040> and create the owner account. Confirm both services:

```sh
docker compose ps
curl --fail http://localhost:4040/api/health
```

The first account owns the instance. Configure registration, storage ceilings,
repository defaults, and service policy under Administration.

## Public deployment

Create an ignored `.env` beside `compose.yml`:

```dotenv
FLURRY_DATABASE_PASSWORD=replace-with-a-long-url-safe-password
FLURRY_PUBLIC_URL=https://git.example.com
FLURRY_SECURE_COOKIES=true
```

Put an HTTPS reverse proxy in front of port `4040`. Forward the original host and
scheme, restrict direct access to the application port, and do not publish the
PostgreSQL port. Set `FLURRY_TRUSTED_PROXIES` in `compose.yml` when the proxy address
must be trusted for client-IP handling.

The Compose password is embedded in a PostgreSQL URL, so it must be URL-safe. For
secrets that contain reserved URL characters, provide a fully encoded
`DATABASE_URL` through your deployment environment instead.

## Configuration

`compose.yml` sets only the database, bind address, public origin, cookie policy,
and local object directory. Add optional variables from [.env.example](../.env.example)
to the `flurry.environment` map when you need:

- outbound account email;
- source-provider connections;
- private S3-compatible object storage;
- SSH Git transport;
- trusted reverse proxies or additional HTTPS origins;
- instance rate limits and storage ceilings.

Keep production secrets outside the repository. OAuth source providers require
both `FLURRY_SECRET_KEY` and `FLURRY_PUBLIC_URL`.

## Build locally

To build from the current checkout instead of pulling GHCR:

```sh
docker compose up --build -d
```

The image builds the browser bundle, compiles an Elixir release, runs as an
unprivileged user, and includes Git and SSH clients for repository transfers.

## Upgrade

```sh
docker compose pull
docker compose up -d
docker compose ps
curl --fail https://git.example.com/api/health
```

The entrypoint applies pending migrations before starting the new release. Do not
set `FLURRY_SKIP_MIGRATIONS=true` unless another deployment job has already run the
same release migrations.

## Back up and recover

The `database` and `objects` volumes are one consistency set. PostgreSQL contains
the references needed to interpret the content-addressed object directory. Back up
both on the same schedule and retain them together. See [backups.md](backups.md) for
the storage contract, S3 migration procedure, and recovery verification.

Inspect volume names with:

```sh
docker volume ls --filter label=com.docker.compose.project=flurry
```

Before accepting traffic after recovery, verify the health endpoint, representative
file reads, history, reviews, and Git clone/fetch behavior.
