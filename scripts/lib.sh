#!/usr/bin/env bash
# Shared helpers. Sourced, never executed.

log() { # log LEVEL message...
  local level=$1; shift
  printf '%s %-5s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$level" "$*"
}

die() { log ERROR "$*" >&2; exit 1; }

need() { # need cmd...
  local c missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  [ ${#missing[@]} -eq 0 ] || die "missing required command(s): ${missing[*]}"
}

# load_env FILE: export KEY=VALUE lines without evaluating them as shell.
# Variables already present in the environment win over the file.
load_env() {
  local file=$1 line key val
  [ -r "$file" ] || die "cannot read env file: $file"
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in ''|'#'*) continue ;; esac
    key=${line%%=*}
    val=${line#*=}
    [[ $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    [ -n "${!key+x}" ] || export "$key=$val"
  done < "$file"
}

# env_get FILE KEY: print the value of KEY in FILE (empty if unset).
env_get() {
  local file=$1 key=$2 line
  line=$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)
  printf '%s' "${line#*=}"
}
