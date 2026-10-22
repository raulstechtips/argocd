#!/usr/bin/env bash
# Read the live workload. Exit 1 for differences, 2 for input or API errors.
# Output can contain workload configuration. Keep it outside git.
set -euo pipefail
if [ "$#" -ne 3 ]; then
  echo "Usage: bash test/workload-compare.sh kind name rendered.yaml" >&2
  exit 2
fi
export KIND="$1" NAME="$2"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
yq ea -o=json -I=0 'select(.kind == strenv(KIND) and .metadata.name == strenv(NAME))' "$3" |
  jq -es 'if length == 1 then .[0] else error("Expected one rendered workload") end' > "$tmp/rendered" || exit 2
namespace="$(jq -r '.metadata.namespace // "argocd"' "$tmp/rendered")"
kubectl -n "$namespace" get "$KIND" "$NAME" -o yaml |
  yq -o=json > "$tmp/live" || exit 2
for input in live rendered; do
  jq -S '
    # Remove only the approved API defaults, and do it on both inputs.
    def container_defaults:
      if .terminationMessagePath == "/dev/termination-log"
        then del(.terminationMessagePath) else . end |
      if .terminationMessagePolicy == "File"
        then del(.terminationMessagePolicy) else . end |
      if .securityContext == {} then del(.securityContext) else . end |
      if has("env") then .env |= map(
        if .valueFrom.fieldRef.apiVersion == "v1"
          then del(.valueFrom.fieldRef.apiVersion) else . end
      ) else . end |
      reduce ["livenessProbe", "readinessProbe", "startupProbe"][] as $probe (.;
        if has($probe) then
          .[$probe] |= (
            if .httpGet.scheme == "HTTP" then del(.httpGet.scheme) else . end |
            if .initialDelaySeconds == 0 then del(.initialDelaySeconds) else . end
          )
        else . end);
    .spec |
    del(.selector, .template.metadata.labels, .template.metadata.creationTimestamp) |
    .template.metadata.annotations = (.template.metadata.annotations // {}) |
    if .progressDeadlineSeconds == 600 then del(.progressDeadlineSeconds) else . end |
    if .strategy == {type:"RollingUpdate", rollingUpdate:{maxSurge:"25%", maxUnavailable:"25%"}}
      then del(.strategy) else . end |
    if .podManagementPolicy == "OrderedReady" then del(.podManagementPolicy) else . end |
    if .updateStrategy == {type:"RollingUpdate", rollingUpdate:{partition:0}}
      then del(.updateStrategy) else . end |
    if .persistentVolumeClaimRetentionPolicy == {whenDeleted:"Retain", whenScaled:"Retain"}
      then del(.persistentVolumeClaimRetentionPolicy) else . end |
    .template.spec |= (
      if .restartPolicy == "Always" then del(.restartPolicy) else . end |
      if .schedulerName == "default-scheduler" then del(.schedulerName) else . end |
      if .securityContext == {} then del(.securityContext) else . end |
      if .serviceAccount == .serviceAccountName then del(.serviceAccount) else . end |
      .containers |= map(container_defaults) |
      if has("initContainers") then .initContainers |= map(container_defaults) else . end |
      if has("volumes") then .volumes |= map(
        if .configMap.defaultMode == 420 then del(.configMap.defaultMode) else . end |
        if .secret.defaultMode == 420 then del(.secret.defaultMode) else . end
      ) else . end
    ) |
    # Sort only collections whose order has no meaning. Keep env, args, command
    # and initContainers in order: later entries can depend on earlier ones.
    .template.spec |= (
      .containers |= (map(
        if has("volumeMounts") then .volumeMounts |= sort_by(.name) else . end |
        if has("ports") then .ports |= sort_by(.name // "") else . end
      ) | sort_by(.name)) |
      if has("volumes") then .volumes |= sort_by(.name) else . end
    )
  ' "$tmp/$input" > "$tmp/$input-normalized"
done
jq -nr --slurpfile live "$tmp/live" --slurpfile rendered "$tmp/rendered" '
  $live[0].spec.template.spec.containers[] | .name as $old |
  select($rendered[0].spec.template.spec.containers | any(
    .name == $old or ("argocd-" + .name) == $old or
    ($old == "dex" and .name == "dex-server")
  ) | not) |
  "FIX missing container: " + $old
'
set +e
diff -u --label "live $KIND/$NAME" --label "rendered $KIND/$NAME" \
  "$tmp/live-normalized" "$tmp/rendered-normalized"
rc=$?
set -e
if [ "$rc" -eq 0 ]; then echo "PASS $KIND/$NAME workload fields match"; fi
exit "$rc"
