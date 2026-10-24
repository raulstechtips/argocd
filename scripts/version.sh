#!/usr/bin/env bash
# Manual GitHub Actions backup: Jenkins is the main pipeline and publishes higher versions.
# Version = charts/Chart.yaml version with the patch raised by one, plus the build kind.
set -euo pipefail

BRANCH_RE='^(feature|bugfix|hotfix|release)/([A-Z][A-Z0-9]*-[0-9]+)(-.*)?$'
if [[ "$GITHUB_REF_NAME" == main ]]; then
  TYPE=main
elif [[ "$GITHUB_REF_NAME" =~ $BRANCH_RE ]]; then
  TYPE="${BASH_REMATCH[1]}-${BASH_REMATCH[2],,}"
else
  printf '::error::Branch "%s" must be <type>/<KEY>-<number>[-text]. The type must be feature, bugfix, hotfix or release. Example: feature/DEVSECOPS-54-argocd-chart.\n' "$GITHUB_REF_NAME"
  exit 1
fi

CHART_VERSION=$(yq '.version' charts/Chart.yaml)
if ! [[ "$CHART_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo '::error::Version in charts/Chart.yaml must be X.Y.Z.'
  exit 1
fi
BASE="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
VERSION="${BASE}-${TYPE}-${GITHUB_SHA::7}-${GITHUB_RUN_NUMBER}"

echo "VERSION=$VERSION"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
  echo "version=$VERSION" >> "$GITHUB_OUTPUT"
fi
