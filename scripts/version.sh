#!/usr/bin/env bash
set -euo pipefail

BRANCH_RE='^([a-z0-9]+(-[a-z0-9]+)*)/([A-Z][A-Z0-9]*-[0-9]+)(-.*)?$'
MAIN_RE='^[0-9]+\.[0-9]+\.[0-9]+-main-[0-9a-f]{7}-[0-9]+$'
if [[ "$GITHUB_REF_NAME" == main ]]; then
  TYPE=main
elif [[ "$GITHUB_REF_NAME" =~ $BRANCH_RE ]]; then
  TYPE="${BASH_REMATCH[1]}-${BASH_REMATCH[3],,}"
else
  printf '::error::Branch "%s" must be <type>/<KEY>-<number>[-text], for example feature/DEVSECOPS-54-argocd-chart.\n' "$GITHUB_REF_NAME"
  exit 1
fi

BASE=${BASE:-$(yq '.version' charts/Chart.yaml)}
if ! [[ "$BASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo '::error::Version in charts/Chart.yaml must be X.Y.Z.'
  exit 1
fi
VERSION="${BASE}-${TYPE}-${GITHUB_SHA::7}-${GITHUB_RUN_NUMBER}"

# CHART_CHANGED and TAGS_FILE permit local checks of this exact CI script.
if [[ -z ${CHART_CHANGED+x} ]]; then
  if [[ "$GITHUB_REF_NAME" == main ]]; then
    if git rev-parse --verify HEAD^ >/dev/null 2>&1; then
      COMPARE=HEAD^
    else
      CHART_CHANGED=true
    fi
  else
    COMPARE=$(git merge-base HEAD origin/main)
  fi
  if [[ -z ${CHART_CHANGED+x} ]]; then
    CHANGED=$(git diff --name-only "$COMPARE" HEAD -- charts/)
    CHART_CHANGED=false
    if [[ -n "$CHANGED" ]]; then
      CHART_CHANGED=true
    fi
  fi
fi

if [[ "$CHART_CHANGED" == true ]]; then
  if [[ -n ${TAGS_FILE:-} ]]; then
    TAGS=$(<"$TAGS_FILE")
  else
    ERROR_FILE=$(mktemp)
    trap 'rm -f "$ERROR_FILE"' EXIT
    if ! TAGS=$(oras repo tags ghcr.io/raulstechtips/charts/argocd 2>"$ERROR_FILE"); then
      if grep -Eq 'NAME_UNKNOWN|name unknown|404 Not Found|: not found' "$ERROR_FILE"; then
        TAGS=''
      else
        cat "$ERROR_FILE" >&2
        exit 1
      fi
    fi
  fi
  LATEST=$(printf '%s\n' "$TAGS" | { grep -E "$MAIN_RE" || test "$?" -eq 1; } | cut -d- -f1 | sort -V | tail -n 1)
  if [[ -n "$LATEST" ]]; then
    HIGHEST=$(printf '%s\n' "$LATEST" "$BASE" | sort -V | tail -n 1)
    if [[ "$BASE" == "$LATEST" || "$HIGHEST" != "$BASE" ]]; then
      echo "::error::Raise version in charts/Chart.yaml above $LATEST"
      exit 1
    fi
  fi
fi

echo "VERSION=$VERSION"
echo "CHART_CHANGED=$CHART_CHANGED"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
