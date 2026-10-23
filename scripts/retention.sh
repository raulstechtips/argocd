#!/usr/bin/env bash
# Delete dated branch-build chart versions (every tag made by CI branch builds) older than 7 days from GHCR.
# Keep everything else: untagged, main, release, manual and unrecognised tags.
# Usage: scripts/retention.sh --dry-run|--apply   (reads GH_TOKEN for gh)
# Test hooks (offline): RETENTION_VERSIONS_FILE=<json file> skips the list API call;
#                       RETENTION_NOW=<epoch seconds> replaces the current time.
set -euo pipefail

# raulstechtips is a GitHub organization: use the orgs API path. The user-scoped path returns 404 for an org.
PKG_OWNER_PATH="orgs/raulstechtips"
OWNER_PATH="/${PKG_OWNER_PATH}/packages/container/charts%2Fargocd/versions"
# Dated branch build as scripts/version.sh makes it: X.Y.Z-<type>-<key>-<number>-<sha7>-<run>.
BRANCH_BUILD_RE='^[0-9]+\.[0-9]+\.[0-9]+-(feature|bugfix|hotfix|release)-[a-z][a-z0-9]*-[0-9]+-[0-9a-f]{7}-[0-9]+$'
# Explicit guard: a tag that ends in the main shape is never deleted.
MAIN_GUARD_RE='-main-[0-9a-f]{7}-[0-9]+$'
MAX_AGE_SECONDS=604800

mode="${1:-}"
case "$mode" in
  --dry-run|--apply) ;;
  *) echo "usage: $0 --dry-run|--apply" >&2; exit 2 ;;
esac

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "${RETENTION_VERSIONS_FILE:-}" ]; then
  cp "$RETENTION_VERSIONS_FILE" "$work/raw.json"
else
  if ! gh api --paginate "${OWNER_PATH}?per_page=100" >"$work/raw.json" 2>"$work/err.txt"; then
    if grep -q 'HTTP 404' "$work/err.txt"; then
      echo "::notice::Package charts/argocd not found (HTTP 404). Nothing to clean."
      exit 0
    fi
    cat "$work/err.txt" >&2
    echo "::error::GitHub API list call failed." >&2
    exit 1
  fi
fi

# --paginate prints one JSON array per page: merge them. Fail closed on bad JSON.
if ! jq -s 'add // []' "$work/raw.json" >"$work/versions.json" 2>/dev/null; then
  echo "::error::Version list is not valid JSON. Nothing deleted." >&2
  exit 1
fi

# Every item needs a numeric id, a parseable created_at and a tags array. Else fail closed.
if ! jq -e 'type == "array" and all(.[];
      (.id | type == "number")
      and (.created_at | type == "string"
           and ((sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null) != null))
      and ((.metadata.container.tags // null) | type == "array"))' \
    "$work/versions.json" >/dev/null 2>&1; then
  echo "::error::Malformed version data (missing id, created_at or tags). Nothing deleted." >&2
  exit 1
fi

if [ -n "${RETENTION_NOW:-}" ]; then
  now="$RETENTION_NOW"
else
  now="$(jq -n 'now | floor')"
fi

jq -r --argjson now "$now" --arg re "$BRANCH_BUILD_RE" --arg guard "$MAIN_GUARD_RE" --argjson max "$MAX_AGE_SECONDS" '
  .[] |
  (.metadata.container.tags) as $tags |
  (.created_at | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $created |
  (if ($tags | length) == 0 then
     ["KEEP", "untagged version kept (never deleted)"]
   elif any($tags[]; test($guard)) then
     ["KEEP", "has main release tag"]
   elif any($tags[]; test($re) | not) then
     ["KEEP", "has a tag that is not a dated branch build"]
   elif ($now - $created) > $max then
     ["DELETE", "dated branch build older than 7 days"]
   else
     ["KEEP", "dated branch build newer than 7 days"]
   end) as $d |
  [$d[0], (.id | tostring), ($tags | join(",")), .created_at, $d[1]] | join("|")' \
  "$work/versions.json" >"$work/decisions.txt"

fail=0
while IFS='|' read -r decision id tags created reason; do
  if [ "$decision" = "KEEP" ] && [ -z "$tags" ]; then
    echo "::notice::KEEP id=$id untagged created=$created - $reason"
  elif [ "$decision" = "KEEP" ]; then
    echo "KEEP id=$id tags=$tags created=$created - $reason"
  elif [ "$mode" = "--dry-run" ]; then
    echo "would-delete id=$id tags=$tags created=$created - $reason (dry run, no API call)"
  else
    echo "DELETE id=$id tags=$tags created=$created - $reason"
    if ! gh api --method DELETE "${OWNER_PATH}/${id}"; then
      echo "::error::DELETE failed for version $id" >&2
      fail=1
      break
    fi
  fi
done <"$work/decisions.txt"

exit "$fail"
