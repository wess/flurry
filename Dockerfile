# syntax=docker/dockerfile:1.7

ARG ELIXIR_IMAGE=hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20250428-slim
ARG BUN_IMAGE=oven/bun:1.4.4-slim
ARG DEBIAN_IMAGE=debian:bookworm-slim

FROM ${BUN_IMAGE} AS web

WORKDIR /app/web
COPY web/package.json web/bun.lock ./
RUN bun install --frozen-lockfile
COPY web ./
RUN bun run typecheck && bun run build

FROM ${ELIXIR_IMAGE} AS build

RUN apt-get update \
    && apt-get install --yes --no-install-recommends build-essential git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
COPY --from=web /app/priv/static priv/static
RUN mix compile && mix release

FROM ${DEBIAN_IMAGE} AS runtime

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates curl git libstdc++6 libncurses6 openssh-client openssl tini \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 flurry \
    && mkdir -p /app /var/lib/flurry/objects \
    && chown -R flurry:flurry /app /var/lib/flurry

WORKDIR /app
ENV HOME=/home/flurry \
    LANG=C.UTF-8 \
    PORT=4040 \
    FLURRY_HOST=0.0.0.0 \
    FLURRY_STORE=/var/lib/flurry/objects

COPY --from=build --chown=flurry:flurry /app/_build/prod/rel/flurry ./
COPY --chown=flurry:flurry docker/entrypoint.sh /usr/local/bin/flurryentrypoint

USER flurry
EXPOSE 4040
VOLUME ["/var/lib/flurry"]
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=5 \
  CMD curl --fail --silent http://127.0.0.1:4040/api/health >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/flurryentrypoint"]
CMD ["/app/bin/flurry", "start"]
