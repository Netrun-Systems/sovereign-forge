#!/usr/bin/env bash
# docker compose wrapper that assembles the right -f files from .env.
#   CI_ENGINE=forgejo|jenkins   WITH_CADDY=true|false
# Installed on cloud hosts as /usr/local/sbin/forge-compose.
# usage: forge-compose.sh <any docker compose arguments>   e.g.  up -d | ps | logs -f forgejo
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

COMPOSE_DIR=${FORGE_COMPOSE_DIR:-}
if [ -z "$COMPOSE_DIR" ]; then
  if [ -d /opt/forge/compose ]; then COMPOSE_DIR=/opt/forge/compose; else COMPOSE_DIR="$HERE/../compose"; fi
fi
COMPOSE_DIR=$(cd "$COMPOSE_DIR" && pwd)
ENV_FILE="$COMPOSE_DIR/.env"
[ -r "$ENV_FILE" ] || die "no $ENV_FILE; run scripts/gen-env.sh first"

ci=$(env_get "$ENV_FILE" CI_ENGINE)
caddy=$(env_get "$ENV_FILE" WITH_CADDY)
files=(-f "$COMPOSE_DIR/docker-compose.forgejo.yml")
[ "$ci" = jenkins ] && files+=(-f "$COMPOSE_DIR/docker-compose.jenkins.yml")
[ "$caddy" = true ] && files+=(-f "$COMPOSE_DIR/docker-compose.caddy.yml")

exec docker compose --project-directory "$COMPOSE_DIR" --env-file "$ENV_FILE" "${files[@]}" "$@"
