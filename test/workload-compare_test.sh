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

changed="$(printf '%s\n' "$bare" | jq '.spec.template.metadata.labels.app="changed"')"
check "pod label change stays visible" 1 "$bare" "$changed"
changed="$(printf '%s\n' "$bare" | jq '.spec.selector.matchLabels.instance="argocd"')"
check "selector addition stays visible" 1 "$bare" "$changed"
changed="$(printf '%s\n' "$bare" | jq '.spec.template.metadata.labels += {
  "helm.sh/chart":"example-1", "app.kubernetes.io/version":"1",
  "app.kubernetes.io/managed-by":"Helm"}')"
check "volatile Helm labels are ignored" 0 "$bare" "$changed"

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
# Isolate the missing-container guard from the full field comparison.
diff() { return 0; }
export -f diff
diff "$tmp/output" /dev/null
check "missing sidecar fails even without a field diff" 1 "$changed" "$bare"
unset -f diff

ordered="$(printf '%s\n' "$bare" | jq '.spec.template.spec.containers[0] |= (
  .volumeMounts=[{name:"config",mountPath:"/config"},{name:"secret",mountPath:"/secret"}] |
  .ports=[{name:"http",containerPort:8080},{name:"metrics",containerPort:9090}]
)')"
reversed="$(printf '%s\n' "$ordered" | jq '.spec.template.spec |= (
  .volumes |= reverse |
  .containers[0].volumeMounts |= reverse |
  .containers[0].ports |= reverse
)')"
check "reordered volumes mounts and ports match" 0 "$ordered" "$reversed"

ordered="$(printf '%s\n' "$bare" | jq '.spec.template.spec.containers[0].env=[{name:"BASE",value:"before"},{name:"DEPENDENT",value:"$(BASE)"}]')"
reversed="$(printf '%s\n' "$ordered" | jq '.spec.template.spec.containers[0].env |= reverse')"
check "reordered dependent env stays visible" 1 "$ordered" "$reversed"
for field in args command initContainers; do
  if [ "$field" = initContainers ]; then
    ordered="$(printf '%s\n' "$bare" | jq '.spec.template.spec.initContainers=[
      {name:"first",image:"example.test/app:1"},{name:"second",image:"example.test/app:1"}]')"
    reversed="$(printf '%s\n' "$ordered" | jq '.spec.template.spec.initContainers |= reverse')"
  else
    ordered="$(printf '%s\n' "$bare" | jq --arg field "$field" '.spec.template.spec.containers[0][$field]=["first","second"]')"
    reversed="$(printf '%s\n' "$ordered" | jq --arg field "$field" '.spec.template.spec.containers[0][$field] |= reverse')"
  fi
  check "reordered $field stays visible" 1 "$ordered" "$reversed"
done

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
