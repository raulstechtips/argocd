#!/usr/bin/env bash
# Check every Service targetPort against each selected rendered pod template.
# Exit 1 for a FIX, 2 for input errors. This command does not use the cluster.
set -euo pipefail
if [ "$#" -ne 1 ]; then
  echo "Usage: bash test/service-targetport-check.sh rendered.yaml" >&2
  exit 2
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
yq ea -o=json -I=0 'select(.kind != null)' "$1" | jq -s . > "$tmp/objects" || exit 2
jq -r '
  . as $objects |
  [.[] | select(.kind == "Service") |
    . as $svc |
    [.spec.selector // {} | to_entries[]] as $selector |
    [$objects[] | select(.spec.template != null) |
      select((.metadata.namespace // "argocd") == ($svc.metadata.namespace // "argocd")) |
      . as $workload |
      select(($selector | length) > 0 and
        all($selector[];
          if .key == "statefulset.kubernetes.io/pod-name" and $workload.kind == "StatefulSet" then
            .value as $name |
            any(range($workload.spec.ordinals.start // 0;
              ($workload.spec.ordinals.start // 0) + ($workload.spec.replicas // 1));
              $name == ($workload.metadata.name + "-" + tostring))
          else $workload.spec.template.metadata.labels[.key] == .value end))
    ] as $workloads |
    if ($workloads | length) == 0 then
      "FIX Service/\(.metadata.name): no selected rendered workload"
    else
      .spec.ports[] | . as $port |
      ($port.targetPort // $port.port) as $target |
      $workloads[] |
      [.spec.template.spec.containers[].ports[]? |
        select((.protocol // "TCP") == ($port.protocol // "TCP")) |
        select(if ($target | type) == "number" then .containerPort == $target else .name == $target end)
      ] as $matches |
      (if ($matches | length) > 0 then "PASS" else "FIX" end) +
      " Service/\($svc.metadata.name) \($port.name // "-"):\($port.port) -> \($target) on \(.kind)/\(.metadata.name)"
    end
  ] | if length == 0 then ["FIX input contains no Services"] else . end | .[]
' "$tmp/objects" > "$tmp/result" || exit 2
cat "$tmp/result"
if grep -q '^FIX ' "$tmp/result"; then exit 1; fi
