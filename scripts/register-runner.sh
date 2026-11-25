#!/usr/bin/env bash
# Register the Forgejo Actions runner with the local Forgejo, once.
# Idempotent: exits quietly if /data/.runner already exists in the runner volume.
# Only meaningful when CI_ENGINE=forgejo.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
need docker

COMPOSE_DIR=${FORGE_COMPOSE_DIR:-}
if [ -z "$COMPOSE_DIR" ]; then
  if [ -d /opt/forge/compose ]; then COMPOSE_DIR=/opt/forge/compose; else COMPOSE_DIR="$HERE/../compose"; fi
fi
ENV_FILE="$COMPOSE_DIR/.env"
[ -r "$ENV_FILE" ] || die "no $ENV_FILE"
load_env "$ENV_FILE"
if [ "${CI_ENGINE:-forgejo}" != forgejo ]; then
  log INFO "CI_ENGINE=$CI_ENGINE: no runner to register"
  exit 0
fi

FC="$HERE/forge-compose.sh"
RUNNER_DIR="${DATA_DIR:?}/runner"
if [ -s "$RUNNER_DIR/.runner" ]; then
  log INFO "runner already registered ($RUNNER_DIR/.runner)"
  exit 0
fi

mkdir -p "$RUNNER_DIR"
# The runner image runs as uid 1001. Own the directory for it; where chown is not
# possible (some desktop Docker setups) fall back to world-writable.
chown 1001:1001 "$RUNNER_DIR" 2>/dev/null || chmod 0777 "$RUNNER_DIR"

health() { docker inspect -f '{{.State.Health.Status}}' forgejo 2>/dev/null || true; }
log INFO "waiting for forgejo to report healthy"
for _ in $(seq 1 60); do
  [ "$(health)" = healthy ] && break
  sleep 5
done
[ "$(health)" = healthy ] || die "forgejo is not healthy"

log INFO "requesting a runner registration token"
token=$(docker exec -u git forgejo forgejo actions generate-runner-token | tr -d '\r\n')
[ -n "$token" ] || die "empty registration token"

"$FC" run -T --rm --no-deps runner forgejo-runner generate-config > "$RUNNER_DIR/config.yml"
# Job containers run inside the dind daemon, on a network of its own, so they cannot
# resolve the compose service name "forgejo" that jobs are told to clone from
# (actions/checkout fails with "Could not resolve host: forgejo"). "host" puts them in
# dind's network namespace, which sits on the compose network and does resolve it.
sed -i -E 's/^([[:space:]]+)network: ""/\1network: "host"/' "$RUNNER_DIR/config.yml"
grep -qE '^[[:space:]]+network: "host"' "$RUNNER_DIR/config.yml" || die "could not set container.network in $RUNNER_DIR/config.yml (runner config format changed?)"
"$FC" run -T --rm --no-deps runner forgejo-runner register --no-interactive \
  --instance http://forgejo:3000 --token "$token" \
  --name "${RUNNER_NAME:?}" --labels "${RUNNER_LABELS:?}" >/dev/null
unset token
[ -s "$RUNNER_DIR/.runner" ] || die "registration finished but $RUNNER_DIR/.runner is missing"
log INFO "runner registered as ${RUNNER_NAME}; starting it"
"$FC" up -d runner
