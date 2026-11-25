#!/usr/bin/env bash
# The logic behind the Makefile targets. Runs on your machine, never on the forge host.
#
# usage:
#   forgectl.sh deploy aws|azure      terraform init + apply (Terraform asks before applying), then verify
#   forgectl.sh local                 Docker Compose on this machine, no TLS
#   forgectl.sh backup                run a backup now: over ssh if FORGE_SSH is set, else locally
#   forgectl.sh destroy aws|azure|local
#
# Environment:
#   TERRAFORM=terraform   AUTO_APPROVE=1 (pass -auto-approve)   VERIFY_WAIT=900
#   FORGE_SSH=user@host   for `backup`
#   CONFIRM=<forge_host>  non-interactive confirmation for `destroy`
#   PURGE=1               `destroy local` also deletes the Docker volumes
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$HERE/.."
# shellcheck source=lib.sh
. "$HERE/lib.sh"

TERRAFORM=${TERRAFORM:-terraform}
VERIFY_WAIT=${VERIFY_WAIT:-900}
apply_flags=()
[ -z "${AUTO_APPROVE:-}" ] || apply_flags+=(-auto-approve)

tf() { "$TERRAFORM" -chdir="$ROOT/terraform/$1" "${@:2}"; }

cmd_deploy() {
  local cloud=${1:-}
  case $cloud in aws|azure) ;; *) die "usage: forgectl.sh deploy aws|azure" ;; esac
  need "$TERRAFORM" ssh
  [ -f "$ROOT/terraform/$cloud/terraform.tfvars" ] || die "missing terraform/$cloud/terraform.tfvars: copy terraform.tfvars.example and fill it in"

  tf "$cloud" init -input=false
  tf "$cloud" apply ${apply_flags[@]+"${apply_flags[@]}"}

  local host ip target ci
  host=$(tf "$cloud" output -raw forge_host)
  ip=$(tf "$cloud" output -raw public_ip)
  target=$(tf "$cloud" output -raw ssh_target)
  ci=$(tf "$cloud" output -raw ci_engine)
  echo
  log INFO "create the DNS A record(s): $host -> $ip   (plus your jenkins_host if ci_engine=jenkins)"
  log INFO "waiting up to ${VERIFY_WAIT}s for first boot, DNS and the TLS certificate"
  "$HERE/verify.sh" --host "$host" --ip "$ip" --ssh "$target" --ci "$ci" --wait "$VERIFY_WAIT"
  echo
  log INFO "first admin password: ssh $target sudo cat /root/forge-admin-credentials.txt"
}

cmd_local() {
  need docker
  WITH_CADDY=${WITH_CADDY:-false} "$HERE/gen-env.sh"
  "$HERE/forge-compose.sh" pull --quiet
  "$HERE/forge-compose.sh" up -d --wait --wait-timeout 300 postgres forgejo
  local env="$ROOT/compose/.env" ci url
  # WITH_CADDY=true selects the Caddy compose file, but nothing else would start the container.
  [ "$(env_get "$env" WITH_CADDY)" != true ] || "$HERE/forge-compose.sh" up -d caddy
  ci=$(env_get "$env" CI_ENGINE)
  if [ "${ci:-forgejo}" = forgejo ]; then
    "$HERE/register-runner.sh"
  else
    "$HERE/forge-compose.sh" up -d jenkins
  fi
  url=$(env_get "$env" FORGE_ROOT_URL)
  echo
  log INFO "forge is up at $url"
  log INFO "create the first administrator:"
  echo "  docker exec -u git forgejo forgejo admin user create --admin --username [NAME] --email [EMAIL] --random-password"
}

cmd_backup() {
  if [ -n "${FORGE_SSH:-}" ]; then
    ssh "$FORGE_SSH" 'sudo systemctl start forge-backup.service; sudo journalctl -u forge-backup.service -n 40 --no-pager'
  else
    BACKUP_ENV="${BACKUP_ENV:-$ROOT/backup.env}" \
      LOCAL_DIR="${LOCAL_DIR:-$ROOT/.work/backups}" \
      STATE_DIR="${STATE_DIR:-$ROOT/.work/state}" \
      "$HERE/backup.sh"
  fi
}

cmd_destroy() {
  local target=${1:-}
  case $target in
    local)
      need docker
      if [ -n "${PURGE:-}" ]; then
        # The runner's registration lives in DATA_DIR, not in a volume, and it belongs to the
        # database about to be deleted. Left behind, the next `make local` says "runner already
        # registered", never starts a runner, and still reports success. The files are owned by
        # the runner's uid, so remove them from inside its image.
        local data_dir
        data_dir=$(env_get "$ROOT/compose/.env" DATA_DIR)
        if [ -d "$data_dir/runner" ]; then
          "$HERE/forge-compose.sh" run -T --rm --no-deps --entrypoint /bin/sh runner \
            -c 'rm -rf /data/.runner /data/config.yml /data/.cache' ||
            log WARN "could not clear the runner registration; delete $data_dir/runner by hand"
        fi
        "$HERE/forge-compose.sh" down --volumes
        log INFO "containers, volumes and the runner registration deleted"
      else
        "$HERE/forge-compose.sh" down
        log INFO "containers removed, volumes kept (PURGE=1 deletes them)"
      fi
      ;;
    aws|azure)
      need "$TERRAFORM"
      local host answer=${CONFIRM:-}
      host=$(tf "$target" output -raw forge_host 2>/dev/null || true)
      [ -n "$host" ] || die "no Terraform state for $target (nothing to destroy, or wrong directory)"
      echo "This destroys the forge at $host and its cloud resources."
      if [ "$target" = azure ]; then
        echo "On Azure it ALSO DELETES THE STORAGE ACCOUNT AND EVERY BACKUP IN IT."
      else
        echo "On AWS the bucket is protected: destroy fails while it holds backups unless force_destroy_bucket = true."
      fi
      if [ -z "$answer" ]; then
        [ -t 0 ] || die "not a terminal: set CONFIRM=$host to proceed non-interactively"
        read -r -p "Type the forge host name to continue: " answer
      fi
      [ "$answer" = "$host" ] || die "confirmation did not match; nothing was destroyed"
      tf "$target" destroy ${apply_flags[@]+"${apply_flags[@]}"}
      ;;
    *) die "usage: forgectl.sh destroy aws|azure|local" ;;
  esac
}

case ${1:-} in
  deploy) shift; cmd_deploy "$@" ;;
  local) cmd_local ;;
  backup) cmd_backup ;;
  destroy) shift; cmd_destroy "$@" ;;
  -h|--help|'') sed -n '2,17p' "$0" ;;
  *) die "unknown command: $1" ;;
esac
