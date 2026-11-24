#!/usr/bin/env bash
# Restore drill: pull -> verify checksum -> decrypt -> verify tar -> list repos.
#
# Run this from a machine that holds the age IDENTITY (the private key). The forge
# host never has it, so a compromised host cannot read its own backups, and the
# drill proves the backups are readable by the one party who must be able to.
#
# usage: restore.sh --identity FILE [--env-file FILE] [--tier daily|weekly]
#                   [--date YYYYMMDD|latest] [--extract-to DIR] [--list] [--keep]
#   --env-file    same format as the host's backup.env (BACKUP_REMOTE + RCLONE_CONFIG_FORGE_*).
#                 Credentials for the drill should be read-only; the host's key is not needed.
#   --extract-to  also unpack the data tar and the SQL dump into DIR (never into a live forge)
#   --list        print every owner/repo found in the backup
#   --keep        keep the downloaded ciphertext in the work dir
# Exit code 0 only if every check passed.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

IDENTITY="" ENV_FILE="" TIER=daily WANT=latest EXTRACT="" LIST=0 KEEP=0
while [ $# -gt 0 ]; do
  case $1 in
    --identity) IDENTITY=$2; shift 2 ;;
    --env-file) ENV_FILE=$2; shift 2 ;;
    --tier) TIER=$2; shift 2 ;;
    --date) WANT=$2; shift 2 ;;
    --extract-to) EXTRACT=$2; shift 2 ;;
    --list) LIST=1; shift ;;
    --keep) KEEP=1; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$ENV_FILE" ] && load_env "$ENV_FILE"
[ -n "$IDENTITY" ] && [ -r "$IDENTITY" ] || die "--identity FILE is required and must be readable"
[ -n "${BACKUP_REMOTE:-}" ] || die "BACKUP_REMOTE is unset (use --env-file)"
case $TIER in daily|weekly) ;; *) die "--tier must be daily or weekly" ;; esac
export RCLONE_LOG_LEVEL=${RCLONE_LOG_LEVEL:-ERROR}
need age rclone tar sha256sum gunzip grep

WORK=$(mktemp -d "${TMPDIR:-/tmp}/forge-restore.XXXXXX")
cleanup() { [ "$KEEP" = 1 ] && log INFO "kept $WORK" || rm -rf "$WORK"; }
trap cleanup EXIT

if [ "$WANT" = latest ]; then
  data_name=$(rclone lsf --files-only --include 'forge-data-*.tar.age' "$BACKUP_REMOTE/$TIER/" | sort | tail -n1)
  [ -n "$data_name" ] || die "no data backups found under $BACKUP_REMOTE/$TIER/"
  WANT=${data_name#forge-data-}; WANT=${WANT%.tar.age}
fi
data_name="forge-data-$WANT.tar.age"
db_name="forge-db-$WANT.sql.gz.age"
log INFO "drill tier=$TIER date=$WANT"

for n in "$data_name" "$db_name"; do
  rclone copyto "$BACKUP_REMOTE/$TIER/$n" "$WORK/$n" --retries 3
  rclone copyto "$BACKUP_REMOTE/$TIER/$n.sha256" "$WORK/$n.sha256" --retries 3
  ( cd "$WORK" && sha256sum --check --status "$n.sha256" ) || die "sha256 mismatch for $n (corrupt or tampered)"
  log INFO "checksum ok $n bytes=$(stat -c %s "$WORK/$n")"
done

# Data archive: decrypt, require a valid tar, count repositories.
age -d -i "$IDENTITY" "$WORK/$data_name" | tar -tf - > "$WORK/listing.txt" || die "data archive did not decrypt to a valid tar"
total=$(wc -l < "$WORK/listing.txt")
grep -E '^git/repositories/[^/]+/[^/]+\.git/?$' "$WORK/listing.txt" | sed -E 's#^git/repositories/##; s#/$##' | sort > "$WORK/repos.txt" || true
repos=$(wc -l < "$WORK/repos.txt")
[ "$repos" -gt 0 ] || die "tar is valid ($total entries) but contains no repositories"
grep -q '^gitea/conf/app.ini$' "$WORK/listing.txt" || log WARN "gitea/conf/app.ini not found in the archive"
log INFO "data archive valid: entries=$total repositories=$repos"
[ "$LIST" = 1 ] && sed 's/^/  /' "$WORK/repos.txt"

# Database dump: decrypt, gunzip, require a real pg_dump with the repository table.
tables=$(age -d -i "$IDENTITY" "$WORK/$db_name" | gunzip | grep -c '^CREATE TABLE public\.repository ' || true)
[ "$tables" -ge 1 ] || die "database dump decrypted but has no public.repository table"
log INFO "database dump valid (public.repository present)"

if [ -n "$EXTRACT" ]; then
  mkdir -p "$EXTRACT"
  age -d -i "$IDENTITY" "$WORK/$data_name" | tar -xf - -C "$EXTRACT"
  age -d -i "$IDENTITY" "$WORK/$db_name" | gunzip > "$EXTRACT/forge-db.sql"
  log INFO "extracted to $EXTRACT (follow RUNBOOK.md 'Full restore' to put it back)"
fi
log INFO "RESTORE DRILL PASS date=$WANT repositories=$repos"
