#!/usr/bin/env bash
# Post-deploy assertions. Two halves, run separately or together:
#
#   remote half (from anywhere):  ports, TLS, forge API
#   on-box half (on the host):    containers, CI engine, backup unit, host hardening
#
# usage: verify.sh [--host FQDN] [--ip ADDR] [--ssh user@host] [--on-box]
#                  [--ci forgejo|jenkins] [--wait SECONDS]
#   --host   public DNS name of the forge (enables the remote half)
#   --ip     connect here instead of resolving --host (use before DNS is set up;
#            TLS will still fail until the A record exists and Caddy has a cert)
#   --ssh    also run the on-box half over ssh (this script is piped to the host)
#   --on-box run the on-box half locally (what --ssh does on the other end)
#   --wait   retry the whole run every 15 s for up to SECONDS before giving up
# Exit 0 only if no check FAILED. WARN does not fail the run but is never silent.
# `A && pass || fail` is deliberate below: pass/fail only print and count, they never fail.
# shellcheck disable=SC2015
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]:-$0}")" 2>/dev/null || echo .)" && pwd)"

HOST="" IP="" SSH="" ONBOX=0 CI="" WAIT=0
while [ $# -gt 0 ]; do
  case $1 in
    --host) HOST=$2; shift 2 ;;
    --ip) IP=$2; shift 2 ;;
    --ssh) SSH=$2; shift 2 ;;
    --on-box) ONBOX=1; shift ;;
    --ci) CI=$2; shift 2 ;;
    --wait) WAIT=$2; shift 2 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$HOST$SSH" ] || [ "$ONBOX" = 1 ] || { echo "nothing to check: give --host, --ssh or --on-box" >&2; exit 2; }

PASS=0 FAILN=0 WARNN=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$*"; }
fail() { FAILN=$((FAILN + 1)); printf 'FAIL  %s\n' "$*"; }
warn() { WARNN=$((WARNN + 1)); printf 'WARN  %s\n' "$*"; }

tcp_open() { # tcp_open host port -> 0 if a TCP connection succeeds within 5 s
  # shellcheck disable=SC2016  # $1 and $2 belong to the inner bash
  timeout 5 bash -c ': > /dev/tcp/$1/$2' _ "$1" "$2" 2>/dev/null
}

remote_half() {
  local target=${IP:-$HOST} resolve=() code body
  [ -n "$IP" ] && resolve=(--resolve "$HOST:443:$IP" --resolve "$HOST:80:$IP")

  tcp_open "$target" 80 && pass "tcp 80 open (ACME + redirect)" || fail "tcp 80 closed"
  tcp_open "$target" 443 && pass "tcp 443 open" || fail "tcp 443 closed"
  if tcp_open "$target" 2222; then
    # shellcheck disable=SC2016  # $1 and $2 belong to the inner bash
    banner=$(timeout 5 bash -c 'exec 3<>/dev/tcp/$1/$2; head -c 4 <&3' _ "$target" 2222 2>/dev/null || true)
    [ "$banner" = "SSH-" ] && pass "tcp 2222 answers with an SSH banner (git over ssh)" || fail "tcp 2222 open but no SSH banner"
  else
    fail "tcp 2222 closed (git over ssh)"
  fi
  tcp_open "$target" 3000 && fail "tcp 3000 is reachable from outside (must be loopback only)" || pass "tcp 3000 not reachable (HTTP is behind Caddy)"
  tcp_open "$target" 5432 && fail "tcp 5432 is reachable from outside" || pass "tcp 5432 not reachable"

  [ -n "$HOST" ] || return 0
  code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "${resolve[@]}" "https://$HOST/" 2>/dev/null || true)
  case $code in
    2*|3*) pass "TLS handshake verified and https://$HOST/ answers $code" ;;
    *) fail "https://$HOST/ did not answer cleanly (code='${code:-none}'): DNS not pointing here yet, or no certificate issued yet" ;;
  esac
  code=$(curl -sS --max-time 15 -o /dev/null -w '%{http_code}' "${resolve[@]}" "https://$HOST/api/healthz" 2>/dev/null || true)
  [ "$code" = 200 ] && pass "forge health endpoint /api/healthz = 200" || fail "forge health endpoint /api/healthz = '${code:-none}'"
  body=$(curl -sS --max-time 15 "${resolve[@]}" "https://$HOST/api/v1/version" 2>/dev/null || true)
  case $body in
    *'"version"'*) pass "forge API answers: $body" ;;
    # The kit sets REQUIRE_SIGNIN_VIEW, so an anonymous caller is refused: that is the API answering as designed.
    *'Only signed in user is allowed'*) pass "forge API answers and refuses anonymous callers (REQUIRE_SIGNIN_VIEW)" ;;
    *) fail "forge API /api/v1/version gave no version (body='${body:0:80}')" ;;
  esac
  # Forgejo answers 200 for /user/sign_up even when registration is disabled, and renders
  # "Registration is disabled" in place of the form, so the body decides, not the status.
  code=$(curl -sS --max-time 15 -o /tmp/forge-verify-signup.$$ -w '%{http_code}' "${resolve[@]}" "https://$HOST/user/sign_up" 2>/dev/null || true)
  body=$(cat /tmp/forge-verify-signup.$$ 2>/dev/null || true); rm -f /tmp/forge-verify-signup.$$
  case $code in
    404|303|302|403) pass "self-registration is closed (/user/sign_up = $code)" ;;
    200)
      case $body in
        *'Registration is disabled'*) pass "self-registration is closed (/user/sign_up = 200 with 'Registration is disabled')" ;;
        *'name="user_name"'*) fail "self-registration page is open (/user/sign_up = 200 and shows the sign-up form)" ;;
        *) warn "/user/sign_up = 200 but the page is neither the form nor the disabled notice; check by hand" ;;
      esac ;;
    *) warn "could not determine registration state (/user/sign_up = '${code:-none}')" ;;
  esac
}

onbox_half() {
  local env=/opt/forge/compose/.env c status last now age remote
  [ -n "$CI" ] || CI=$(grep -E '^CI_ENGINE=' "$env" 2>/dev/null | cut -d= -f2 || true)
  [ -n "$CI" ] || CI=forgejo

  for c in forgejo forge-db; do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null || echo missing)
    [ "$status" = healthy ] && pass "container $c healthy" || fail "container $c is '$status'"
  done

  if [ "$CI" = forgejo ]; then
    for c in forge-dind forge-runner; do
      [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || echo false)" = true ] && pass "container $c running" || fail "container $c not running"
    done
    if docker exec forge-runner test -s /data/.runner 2>/dev/null; then
      pass "runner registration file present"
    else
      fail "runner is not registered (no /data/.runner); run scripts/register-runner.sh"
    fi
    # Best effort: the schema is Forgejo's, so degrade to WARN instead of guessing.
    n=$(docker exec forge-db sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from action_runner"' 2>/dev/null | tr -d '[:space:]' || true)
    case $n in
      ''|*[!0-9]*) warn "could not query registered runners from the database" ;;
      0) fail "Forgejo lists 0 registered runners" ;;
      *) pass "Forgejo lists $n registered runner(s)" ;;
    esac
  else
    status=$(docker inspect -f '{{.State.Health.Status}}' forge-jenkins 2>/dev/null || echo missing)
    [ "$status" = healthy ] && pass "container forge-jenkins healthy" || fail "container forge-jenkins is '$status'"
  fi

  systemctl is-enabled --quiet forge-backup.timer && pass "forge-backup.timer enabled" || fail "forge-backup.timer not enabled"
  systemctl is-active --quiet forge-backup.timer && pass "forge-backup.timer active" || fail "forge-backup.timer not active"
  remote=$(grep -E '^BACKUP_REMOTE=' /etc/forge/backup.env 2>/dev/null | cut -d= -f2- || true)
  if [ -z "$remote" ]; then
    warn "BACKUP_REMOTE is unset: the timer is armed but every run will skip. THERE ARE NO BACKUPS."
  elif [ -r /var/lib/forge/last-success ]; then
    last=$(cat /var/lib/forge/last-success); now=$(date -u +%s); age=$(( (now - last) / 3600 ))
    [ "$age" -le 36 ] && pass "last successful backup ${age}h ago" || fail "last successful backup was ${age}h ago"
  else
    warn "no successful backup recorded yet (first run is scheduled for 03:30 UTC; run: systemctl start forge-backup.service)"
  fi

  for f in /opt/forge/compose/.env /etc/forge/backup.env; do
    [ "$(stat -c %a "$f" 2>/dev/null || echo missing)" = 600 ] && pass "$f mode 600" || fail "$f is not mode 600"
  done
  # No `grep -q` after a pipe here: it exits at the first match, the writer gets SIGPIPE, and pipefail
  # then reports the check as failed some of the time.
  ufw status 2>/dev/null | grep '^Status: active' >/dev/null && pass "ufw active" || fail "ufw not active"
  systemctl is-active --quiet fail2ban && pass "fail2ban active" || fail "fail2ban not active"
  sshd -T 2>/dev/null | grep -i '^passwordauthentication no' >/dev/null && pass "sshd password authentication off" || fail "sshd allows password authentication"
  systemctl is-enabled --quiet unattended-upgrades && pass "unattended-upgrades enabled" || fail "unattended-upgrades not enabled"
}

run_once() {
  PASS=0 FAILN=0 WARNN=0
  [ -z "$HOST" ] || { echo "== remote checks: $HOST ${IP:+(via $IP)}"; remote_half; }
  if [ "$ONBOX" = 1 ]; then
    echo "== on-box checks"; onbox_half
  elif [ -n "$SSH" ]; then
    echo "== on-box checks via ssh $SSH"
    # shellcheck disable=SC2086
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH" "sudo bash -s -- --on-box --ci ${CI:-forgejo}" < "$HERE/verify.sh" || fail "ssh on-box run failed (cloud-init may still be running)"
  fi
  echo "== summary: pass=$PASS fail=$FAILN warn=$WARNN"
  [ "$FAILN" -eq 0 ]
}

deadline=$(( $(date +%s) + WAIT ))
while :; do
  if run_once; then exit 0; fi
  [ "$(date +%s)" -lt "$deadline" ] || exit 1
  echo "-- not ready; retrying in 15 s (until $(date -u -d "@$deadline" +%H:%M:%SZ 2>/dev/null || echo deadline))"
  sleep 15
done
