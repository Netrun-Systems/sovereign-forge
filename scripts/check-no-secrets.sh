#!/usr/bin/env bash
# Fail if anything that looks like a credential, a key, or a private address is
# tracked in this repository. Used by `make lint` and by the kit's own CI.
#
# It is a tripwire, not a scanner: it catches the mistakes this kit is most likely
# to make. Keep using a real secret scanner on your fork.
set -Eeuo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "$HERE/.."

fail=0
report() { printf 'FAIL  %s\n' "$*"; fail=1; }

# Files to scan: tracked files if this is a git checkout, otherwise everything.
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  mapfile -t files < <(git ls-files --cached --others --exclude-standard)
else
  mapfile -t files < <(find . -type f -not -path './.git/*' -not -path '*/.terraform/*' | sed 's#^\./##')
fi
self=scripts/check-no-secrets.sh

scan() { # scan LABEL REGEX
  local label=$1 re=$2 hits
  hits=$(printf '%s\n' "${files[@]}" | grep -vxF "$self" | grep -v '\.terraform\.lock\.hcl$' \
    | xargs -r grep -InE -e "$re" 2>/dev/null || true)
  # Print file:line only. Echoing the matching line would copy the very secret it found into the CI log.
  [ -z "$hits" ] || { report "$label"; printf '%s\n' "$hits" | cut -d: -f1,2 | sed 's/^/        /'; }
}

scan "AWS access key id"            'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}'
scan "private key block"            '-----BEGIN [A-Z ]*PRIVATE KEY-----'
scan "age secret key"               'AGE-SECRET-KEY-1[0-9A-Z]{20,}'
scan "real-looking age recipient"   'age1[02-9ac-hj-np-z]{58}'
scan "GitHub token"                 'gh[pousr]_[A-Za-z0-9]{30,}'
scan "Slack token"                  'xox[abprs]-[A-Za-z0-9-]{10,}'
scan "private LAN address"          '(^|[^0-9.])(192\.168\.[0-9]+\.[0-9]+|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]+\.[0-9]+)'
scan "password/secret assigned a literal" '(PASSWORD|SECRET|TOKEN|ACCESS_KEY)[A-Z_]*[[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9/+_-]{16,}["'"'"']?[[:space:]]*$'

# .env.example must carry names only.
if [ -f compose/.env.example ]; then
  bad=$(grep -vE '^[[:space:]]*(#.*)?$|^[A-Z][A-Z0-9_]*=$' compose/.env.example || true)
  [ -z "$bad" ] || { report "compose/.env.example has a line that is not NAME= with an empty value"; printf '%s\n' "$bad" | sed 's/^/        /'; }
fi

# Real env/key files must never be tracked.
tracked_bad=$(printf '%s\n' "${files[@]}" | grep -E '(^|/)(\.env|backup\.env|identity\.txt)$|\.(pem|key)$|\.tfstate' || true)
[ -z "$tracked_bad" ] || { report "files that must never be committed:"; printf '%s\n' "$tracked_bad" | sed 's/^/        /'; }

if [ "$fail" -eq 0 ]; then echo "PASS  no secrets, keys, private addresses or valued env files found (${#files[@]} files scanned)"; fi
exit "$fail"
