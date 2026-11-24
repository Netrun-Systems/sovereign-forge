#!/usr/bin/env bash
# Mirror every repository of a GitHub org (or user) into the forge:
#   git clone --mirror  ->  create the repo on the forge if missing  ->  git push --mirror
# Re-runnable: an existing local mirror is refreshed with `git remote update --prune`.
#
# Credentials are read from the environment, never from arguments, and are handed
# to git through GIT_CONFIG_* so they do not appear in `ps`:
#   GITHUB_TOKEN   token that can read the repositories (read-only is enough)
#   FORGE_TOKEN    forge access token with write:repository and write:organization
#   FORGE_USER     forge username that owns FORGE_TOKEN
#
# usage: mirror-from-github.sh --github ORG --forge-url https://forge.example.com
#                              [--forge-owner NAME] [--owner-type org|user] [--user]
#                              [--workdir DIR] [--include-archived] [--lfs] [--dry-run]
#   --github ORG        GitHub organisation (or user, with --user) to read
#   --forge-owner NAME  forge organisation/user to write into (default: same as --github)
#   --owner-type        whether FORGE-OWNER is an org (default; created if absent) or a user
#   --lfs               also fetch and push Git LFS objects (needs git-lfs)
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"

GH_OWNER="" FORGE_URL="" FORGE_OWNER="" OWNER_TYPE=org GH_IS_USER=0 WORKDIR="" ARCHIVED=0 LFS=0 DRY=0
GITHUB_API=${GITHUB_API:-https://api.github.com}
while [ $# -gt 0 ]; do
  case $1 in
    --github) GH_OWNER=$2; shift 2 ;;
    --forge-url) FORGE_URL=${2%/}; shift 2 ;;
    --forge-owner) FORGE_OWNER=$2; shift 2 ;;
    --owner-type) OWNER_TYPE=$2; shift 2 ;;
    --user) GH_IS_USER=1; shift ;;
    --workdir) WORKDIR=$2; shift 2 ;;
    --include-archived) ARCHIVED=1; shift ;;
    --lfs) LFS=1; shift ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) sed -n '2,23p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[ -n "$GH_OWNER" ] && [ -n "$FORGE_URL" ] || die "--github and --forge-url are required"
FORGE_OWNER=${FORGE_OWNER:-$GH_OWNER}
case $OWNER_TYPE in org|user) ;; *) die "--owner-type must be org or user" ;; esac
: "${GITHUB_TOKEN:?set GITHUB_TOKEN (read access to the source repositories)}"
: "${FORGE_TOKEN:?set FORGE_TOKEN (forge access token)}"
: "${FORGE_USER:?set FORGE_USER (forge username that owns FORGE_TOKEN)}"
need git curl jq base64
[ "$LFS" = 0 ] || need git-lfs
WORKDIR=${WORKDIR:-$PWD/.work/mirrors}
mkdir -p "$WORKDIR"

b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
GH_AUTH="AUTHORIZATION: basic $(b64 "x-access-token:$GITHUB_TOKEN")"
FG_AUTH="AUTHORIZATION: basic $(b64 "$FORGE_USER:$FORGE_TOKEN")"

# git_as KIND ARGS...: run git with an http.extraheader supplied through the environment.
git_as() {
  local kind=$1 hdr; shift
  if [ "$kind" = gh ]; then hdr=$GH_AUTH; else hdr=$FG_AUTH; fi
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.extraheader GIT_CONFIG_VALUE_0=$hdr GIT_TERMINAL_PROMPT=0 git "$@"
}

forge_api() { # forge_api METHOD PATH [json-body] -> prints "<body>\n<http code>"
  local method=$1 path=$2 data=${3:-}
  if [ -n "$data" ]; then
    curl -sS -X "$method" -H "Authorization: token $FORGE_TOKEN" -H 'Content-Type: application/json' \
      -d "$data" -w '\n%{http_code}' "$FORGE_URL/api/v1$path"
  else
    curl -sS -X "$method" -H "Authorization: token $FORGE_TOKEN" -w '\n%{http_code}' "$FORGE_URL/api/v1$path"
  fi
}

ensure_owner() {
  [ "$OWNER_TYPE" = user ] && return 0
  local code
  code=$(forge_api GET "/orgs/$FORGE_OWNER" | tail -n1)
  if [ "$code" = 200 ]; then return 0; fi
  [ "$DRY" = 0 ] || { log INFO "dry-run: would create forge org $FORGE_OWNER"; return 0; }
  code=$(forge_api POST /orgs "$(jq -nc --arg u "$FORGE_OWNER" '{username:$u,visibility:"private"}')" | tail -n1)
  [ "$code" = 201 ] || die "could not create forge org $FORGE_OWNER (HTTP $code)"
  log INFO "created forge org $FORGE_OWNER (private)"
}

ensure_repo() { # ensure_repo NAME PRIVATE(true|false) DESCRIPTION
  local name=$1 private=$2 desc=$3 code path body
  code=$(forge_api GET "/repos/$FORGE_OWNER/$name" | tail -n1)
  [ "$code" = 200 ] && return 0
  [ "$DRY" = 0 ] || { log INFO "dry-run: would create forge repo $FORGE_OWNER/$name"; return 0; }
  if [ "$OWNER_TYPE" = org ]; then path="/orgs/$FORGE_OWNER/repos"; else path=/user/repos; fi
  body=$(jq -nc --arg n "$name" --arg d "$desc" --argjson p "$private" '{name:$n,description:$d,private:$p,auto_init:false}')
  code=$(forge_api POST "$path" "$body" | tail -n1)
  case $code in 201|409) ;; *) die "could not create $FORGE_OWNER/$name (HTTP $code)" ;; esac
}

list_repos() { # prints one JSON object per line: name, private, archived, description
  local page=1 url chunk
  while :; do
    if [ "$GH_IS_USER" = 1 ]; then url="$GITHUB_API/users/$GH_OWNER/repos?per_page=100&page=$page&type=owner"
    else url="$GITHUB_API/orgs/$GH_OWNER/repos?per_page=100&page=$page&type=all"; fi
    chunk=$(curl -fsS -H "Authorization: Bearer $GITHUB_TOKEN" -H 'Accept: application/vnd.github+json' "$url")
    [ "$(jq length <<<"$chunk")" -gt 0 ] || break
    jq -c '.[] | {name, private, archived, description: (.description // "")}' <<<"$chunk"
    page=$((page + 1))
  done
}

# mirror_one runs inside an `if`, where `set -e` is suspended, so every step checks itself.
mirror_one() {
  local name=$1 private=$2 desc=$3 dir="$WORKDIR/$1.git" url="$FORGE_URL/$FORGE_OWNER/$1.git"
  ensure_repo "$name" "$private" "$desc" || return 1
  if [ -d "$dir" ]; then
    git_as gh -C "$dir" remote update --prune || return 1
  else
    git_as gh clone --mirror "https://github.com/$GH_OWNER/$name.git" "$dir" || return 1
  fi
  # GitHub's pull-request refs are read-only on the forge side (it owns refs/pull itself).
  git -C "$dir" for-each-ref --format='delete %(refname)' refs/pull | git -C "$dir" update-ref --stdin || return 1
  if [ "$LFS" = 1 ]; then git_as gh -C "$dir" lfs fetch --all || return 1; fi
  git_as fg -C "$dir" push --mirror "$url" || return 1
  if [ "$LFS" = 1 ]; then git_as fg -C "$dir" lfs push --all "$url" || return 1; fi
}

ensure_owner
total=0 done_=0 skipped=0 failed=0
failures=()
while IFS= read -r repo; do
  name=$(jq -r .name <<<"$repo")
  private=$(jq -r .private <<<"$repo")
  archived=$(jq -r .archived <<<"$repo")
  desc=$(jq -r .description <<<"$repo")
  total=$((total + 1))
  if [ "$archived" = true ] && [ "$ARCHIVED" = 0 ]; then
    log INFO "skip $name (archived; use --include-archived)"; skipped=$((skipped + 1)); continue
  fi
  if [ "$DRY" = 1 ]; then
    log INFO "dry-run: would mirror $GH_OWNER/$name -> $FORGE_OWNER/$name (private=$private)"; continue
  fi
  log INFO "mirroring $name"
  if ! mirror_one "$name" "$private" "$desc"; then
    failed=$((failed + 1)); failures+=("$name"); log ERROR "FAILED $name"
  else
    done_=$((done_ + 1))
  fi
done < <(list_repos)

log INFO "summary: listed=$total mirrored=$done_ skipped=$skipped failed=$failed dry_run=$DRY"
if [ "$failed" -gt 0 ]; then
  log ERROR "failed repositories: ${failures[*]}"
  exit 1
fi
