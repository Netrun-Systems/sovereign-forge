#!/usr/bin/env bash
# Nightly forge backup: tar -> age encrypt -> upload -> READ BACK -> prune.
#
# What is backed up (two artifacts per run, both encrypted before they touch disk
# or the network):
#   forge-data-YYYYMMDD.tar.age       /data/{git,gitea,ssh} from the forgejo container
#                                     (bare repos, LFS, attachments, app.ini, host keys)
#   forge-db-YYYYMMDD.sql.gz.age      pg_dump of the forge database
# plus a .sha256 sidecar for each, used by restore.sh.
#
# Discipline (modelled on a production script that has been restored from):
#   * encrypt before it leaves the host: the host holds only the age PUBLIC key
#   * self-skip, with a log line, until BACKUP_REMOTE is configured
#   * after upload, read the object's size and checksum back from the remote and
#     compare to the local file; a mismatch is a failure, not a warning
#   * prune only after the new backup has been verified
#
# Configuration comes from the environment, or from BACKUP_ENV (default
# /etc/forge/backup.env). Names only here; values live in that file (mode 0600):
#   BACKUP_REMOTE   rclone path, e.g. forge:my-bucket     (unset => skip, exit 0)
#   AGE_RECIPIENT   age public key (age1...) to encrypt to
#   RCLONE_CONFIG_FORGE_*  rclone remote definition for the remote named "forge"
#   LOCAL_DIR=/var/backups/forge  LOCAL_KEEP=2  REMOTE_KEEP=7  WEEKLY_DOW=7
#   VERIFY_FULL=0   set to 1 to re-download and sha256 every uploaded object
#   FORGEJO_CONTAINER=forgejo  DB_CONTAINER=forge-db  STATE_DIR=/var/lib/forge
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

BACKUP_ENV=${BACKUP_ENV:-/etc/forge/backup.env}
[ -r "$BACKUP_ENV" ] && load_env "$BACKUP_ENV"

if [ -z "${BACKUP_REMOTE:-}" ]; then
  log WARN "backup SKIPPED: BACKUP_REMOTE is unset. Nothing was backed up. Configure $BACKUP_ENV."
  exit 0
fi
[ -n "${AGE_RECIPIENT:-}" ] || die "AGE_RECIPIENT is unset; refusing to write an unencrypted backup"
case $AGE_RECIPIENT in age1*) ;; *) die "AGE_RECIPIENT does not look like an age public key" ;; esac

LOCAL_DIR=${LOCAL_DIR:-/var/backups/forge}
LOCAL_KEEP=${LOCAL_KEEP:-2}
REMOTE_KEEP=${REMOTE_KEEP:-7}
WEEKLY_DOW=${WEEKLY_DOW:-7}
VERIFY_FULL=${VERIFY_FULL:-0}
FORGEJO_CONTAINER=${FORGEJO_CONTAINER:-forgejo}
DB_CONTAINER=${DB_CONTAINER:-forge-db}
STATE_DIR=${STATE_DIR:-/var/lib/forge}
MIN_BYTES=${MIN_BYTES:-512}

export RCLONE_LOG_LEVEL=${RCLONE_LOG_LEVEL:-ERROR}
need docker age rclone md5sum sha256sum flock stat
umask 077
mkdir -p "$LOCAL_DIR" "$STATE_DIR"

exec 9>"$STATE_DIR/backup.lock"
flock -n 9 || die "another backup is already running"

on_exit() {
  local status=$?
  if [ "$status" -ne 0 ]; then
    rm -f "$LOCAL_DIR"/.*.partial 2>/dev/null || true
    log ERROR "backup FAILED (exit $status); nothing was pruned after the failing step"
    date -u +%s > "$STATE_DIR/last-failure" 2>/dev/null || true
  fi
}
trap on_exit EXIT

stamp=$(date -u +%Y%m%d)
data_name="forge-data-$stamp.tar.age"
db_name="forge-db-$stamp.sql.gz.age"
started=$(date +%s)
log INFO "backup start stamp=$stamp remote=$BACKUP_REMOTE"

for c in "$FORGEJO_CONTAINER" "$DB_CONTAINER"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null || true)" = true ] || die "container not running: $c"
done

rcl() { rclone "$@" --retries 3 --low-level-retries 10; }

produce_data() { docker exec "$FORGEJO_CONTAINER" tar -C /data -cf - --exclude=gitea/log git gitea ssh; }
produce_db() {
  docker exec "$DB_CONTAINER" sh -c 'exec pg_dump --clean --if-exists -U "$POSTGRES_USER" "$POSTGRES_DB"' | gzip -c
}

# build NAME PRODUCER: stream PRODUCER through age into a .partial file, sanity-check, rename.
build() {
  local name=$1 producer=$2 tmp="$LOCAL_DIR/.$1.partial" size magic
  "$producer" | age -r "$AGE_RECIPIENT" -o "$tmp"
  size=$(stat -c %s "$tmp")
  [ "$size" -ge "$MIN_BYTES" ] || die "$name is only $size bytes; refusing to keep it"
  magic=$(head -c 21 "$tmp")
  [ "$magic" = "age-encryption.org/v1" ] || die "$name does not carry an age header"
  mv "$tmp" "$LOCAL_DIR/$name"
  ( cd "$LOCAL_DIR" && sha256sum "$name" > "$name.sha256" )
  log INFO "built $name bytes=$size"
}

# remote_line PREFIX NAME: print "size md5" as the remote reports it (md5 may be empty).
remote_line() {
  rclone lsf --files-only --format sh --separator ' ' --hash md5 --include "$2" "$BACKUP_REMOTE/$1/" | head -n1
}

# readback PREFIX NAME: prove the object on the remote equals the local file.
readback() {
  local prefix=$1 name=$2 line rsize rhash lsize lmd5 lsha rsha
  line=$(remote_line "$prefix" "$name")
  [ -n "$line" ] || die "readback: $prefix/$name is missing on the remote"
  rsize=${line%% *}
  rhash=${line#* }
  lsize=$(stat -c %s "$LOCAL_DIR/$name")
  [ "$rsize" = "$lsize" ] || die "readback: size mismatch for $prefix/$name (local=$lsize remote=$rsize)"
  lmd5=$(md5sum "$LOCAL_DIR/$name" | cut -d' ' -f1)
  if [ "$VERIFY_FULL" != 1 ] && [[ $rhash =~ ^[0-9a-f]{32}$ ]]; then
    [ "$rhash" = "$lmd5" ] || die "readback: md5 mismatch for $prefix/$name (local=$lmd5 remote=$rhash)"
    log INFO "verified $prefix/$name size=$rsize md5=$lmd5"
  else
    # The remote cannot give us a checksum (or a full check was requested): download and hash.
    lsha=$(sha256sum "$LOCAL_DIR/$name" | cut -d' ' -f1)
    rsha=$(rclone cat "$BACKUP_REMOTE/$prefix/$name" | sha256sum | cut -d' ' -f1)
    [ "$rsha" = "$lsha" ] || die "readback: sha256 mismatch for $prefix/$name"
    log INFO "verified $prefix/$name size=$rsize sha256=$lsha (full read-back)"
  fi
}

prune_remote() { # keep the newest REMOTE_KEEP of each kind under daily/
  local pat n old
  local -a names
  for pat in 'forge-data-*.tar.age' 'forge-db-*.sql.gz.age'; do
    mapfile -t names < <(rclone lsf --files-only --include "$pat" "$BACKUP_REMOTE/daily/" | sort)
    n=${#names[@]}
    [ "$n" -gt "$REMOTE_KEEP" ] || continue
    for old in "${names[@]:0:$((n - REMOTE_KEEP))}"; do
      rclone deletefile "$BACKUP_REMOTE/daily/$old"
      rclone deletefile "$BACKUP_REMOTE/daily/$old.sha256" || true
      log INFO "pruned remote daily/$old"
    done
  done
}

prune_local() {
  local pat n old
  local -a names
  for pat in 'forge-data-*.tar.age' 'forge-db-*.sql.gz.age'; do
    mapfile -t names < <(find "$LOCAL_DIR" -maxdepth 1 -name "$pat" -printf '%f\n' | sort)
    n=${#names[@]}
    [ "$n" -gt "$LOCAL_KEEP" ] || continue
    for old in "${names[@]:0:$((n - LOCAL_KEEP))}"; do
      rm -f "$LOCAL_DIR/$old" "$LOCAL_DIR/$old.sha256"
      log INFO "pruned local $old"
    done
  done
}

build "$data_name" produce_data
build "$db_name" produce_db

for n in "$data_name" "$db_name"; do
  rcl copyto "$LOCAL_DIR/$n" "$BACKUP_REMOTE/daily/$n"
  rcl copyto "$LOCAL_DIR/$n.sha256" "$BACKUP_REMOTE/daily/$n.sha256"
done
for n in "$data_name" "$db_name" "$data_name.sha256" "$db_name.sha256"; do
  readback daily "$n"
done

# Weekly copy: a server-side copy (no second upload), kept long by the bucket lifecycle rules.
if [ "$(date -u +%u)" = "$WEEKLY_DOW" ] || [ "${FORCE_WEEKLY:-0}" = 1 ]; then
  for n in "$data_name" "$db_name" "$data_name.sha256" "$db_name.sha256"; do
    rcl copyto "$BACKUP_REMOTE/daily/$n" "$BACKUP_REMOTE/weekly/$n"
    readback weekly "$n"
  done
fi

prune_remote
prune_local

rm -f "$STATE_DIR/last-failure"
date -u +%s > "$STATE_DIR/last-success"
printf '%s\n%s\n' "$data_name" "$db_name" > "$STATE_DIR/last-success-files"
log INFO "backup OK data=$data_name db=$db_name seconds=$(( $(date +%s) - started ))"
