#!/bin/sh
set -eu

if [ "${FLURRY_SKIP_MIGRATIONS:-false}" != "true" ]; then
  /app/bin/flurry eval "Flurry.Release.migrate()"
fi

exec "$@"
