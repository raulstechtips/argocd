#!/usr/bin/env bash
# Offline regression tests for the approved default normalization.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The child script can only make this read-only call. No cluster is contacted.
kubectl() {
  if [ "$*" != "-n argocd get $TEST_KIND example -o yaml" ]; then
    echo "Unexpected kubectl call: $*" >&2
    return 2
  fi
  printf '%s\n' "$LIVE_WORKLOAD"
}
export -f kubectl
export TEST_KIND=Deployment
bare="$(jq -cn '{
  apiVersion:"apps/v1", kind:"Deployment",
  metadata:{name:"example",namespace:"argocd"},
  spec:{replicas:1,selector:{matchLabels:{app:"example"}},template:{
    metadata:{labels:{app:"example"}},
    spec:{serviceAccountName:"example",containers:[{
      name:"main",image:"example.test/app:1",
      env:[{name:"NAMESPACE",valueFrom:{fieldRef:{fieldPath:"metadata.namespace"}}}],
      livenessProbe:{httpGet:{path:"/healthz",port:8080}}
    }],volumes:[{name:"config",configMap:{name:"config"}},
      {name:"secret",secret:{secretName:"secret"}}]}
  }}
}')"
defaults="$(printf '%s\n' "$bare" | jq '
  .spec.progressDeadlineSeconds=600 |
  .spec.strategy={type:"RollingUpdate",rollingUpdate:{maxSurge:"25%",maxUnavailable:"25%"}} |
  .spec.template.spec |= (
    .restartPolicy="Always" | .schedulerName="default-scheduler" |
    .securityContext={} | .serviceAccount=.serviceAccountName |
    .containers[0] |= (
      .terminationMessagePath="/dev/termination-log" |
      .terminationMessagePolicy="File" |
      .securityContext={} |
      .env[0].valueFrom.fieldRef.apiVersion="v1" |
      .livenessProbe.httpGet.scheme="HTTP" |
      .livenessProbe.initialDelaySeconds=0
    ) |
    .volumes[0].configMap.defaultMode=420 |
    .volumes[1].secret.defaultMode=420
  )
')"
check() {
  local label="$1" expected="$2" live="$3" rendered="$4" rc=0
  printf '%s\n' "$rendered" > "$tmp/rendered.json"
  LIVE_WORKLOAD="$live" bash "$root/test/workload-compare.sh" \
    "$TEST_KIND" example "$tmp/rendered.json" > "$tmp/output" || rc=$?
  if [ "$rc" -ne "$expected" ]; then
    printf 'FAIL %s: expected exit %s, got %s\n' "$label" "$expected" "$rc" >&2
    return 1
  fi
  printf 'PASS %s\n' "$label"
}
check "live API defaults" 0 "$defaults" "$bare"
check "rendered API defaults" 0 "$bare" "$defaults"

changed="$(printf '%s\n' "$defaults" | jq '.spec.template.spec.schedulerName="custom-scheduler"')"
check "non-default scheduler stays visible" 1 "$bare" "$changed"
changed="$(printf '%s\n' "$defaults" | jq '.spec.template.spec.volumes[0].configMap.defaultMode=256')"
check "non-default file mode stays visible" 1 "$bare" "$changed"
changed="$(printf '%s\n' "$defaults" | jq '.spec.template.spec.containers[0].livenessProbe.httpGet.scheme="HTTPS"')"
check "non-default probe scheme stays visible" 1 "$bare" "$changed"
changed="$(printf '%s\n' "$defaults" | jq '.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds=5')"
check "non-default probe delay stays visible" 1 "$bare" "$changed"
changed="$(printf '%s\n' "$bare" | jq '.spec.template.spec.containers += [{name:"kustomize-envsubst",image:"ubuntu:22.04"}]')"
check "missing sidecar fails" 1 "$changed" "$bare"
grep -Fxq 'FIX missing container: kustomize-envsubst' "$tmp/output"

export TEST_KIND=StatefulSet
bare="$(printf '%s\n' "$bare" | jq '.kind="StatefulSet" | .spec.serviceName="example"')"
defaults="$(printf '%s\n' "$bare" | jq '
  .spec.podManagementPolicy="OrderedReady" |
  .spec.updateStrategy={type:"RollingUpdate",rollingUpdate:{partition:0}} |
  .spec.persistentVolumeClaimRetentionPolicy={whenDeleted:"Retain",whenScaled:"Retain"}
')"
check "StatefulSet API defaults" 0 "$defaults" "$bare"
changed="$(printf '%s\n' "$defaults" | jq '.spec.updateStrategy.rollingUpdate.partition=1')"
check "non-default StatefulSet partition stays visible" 1 "$bare" "$changed"
