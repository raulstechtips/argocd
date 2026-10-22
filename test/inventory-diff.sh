#!/usr/bin/env bash
# Compare complete inventories. Exit 1 for missing objects, 2 for input errors.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo "Usage: bash test/inventory-diff.sh expected.yaml rendered.yaml" >&2
  exit 2
fi
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
inventory() {
  yq e -N -r 'select(.kind != null) |
    .kind + "/" + (.metadata.namespace // "") + "/" + .metadata.name' "$1" |
    LC_ALL=C sort -u
}
inventory "$1" > "$tmp/expected" || exit 2
inventory "$2" > "$tmp/rendered" || exit 2
yq e -o=json -I=0 'select(.kind != null)' "$1" | jq -s . > "$tmp/expected.json" || exit 2
yq e -o=json -I=0 'select(.kind != null)' "$2" | jq -s . > "$tmp/rendered.json" || exit 2
LC_ALL=C comm -3 "$tmp/expected" "$tmp/rendered"
LC_ALL=C comm -23 "$tmp/expected" "$tmp/rendered" > "$tmp/missing"
LC_ALL=C comm -13 "$tmp/expected" "$tmp/rendered" > "$tmp/added"
rc=0
while IFS= read -r object; do
  case "$object" in
    Deployment/argocd/argocd-redis|Service/argocd/argocd-redis|ServiceAccount/argocd/argocd-redis|Role/argocd/argocd-redis|RoleBinding/argocd/argocd-redis|NetworkPolicy/argocd/argocd-redis-network-policy)
      if grep -Fxq 'StatefulSet/argocd/argocd-redis-ha-server' "$tmp/rendered" &&
         grep -Fxq 'Service/argocd/argocd-redis-ha-haproxy' "$tmp/rendered"; then
        printf 'OK %s: replaced by HA Redis\n' "$object"
      else
        printf 'FIX %s: missing; no HA Redis replacement\n' "$object"
        rc=1
      fi
      ;;
    ClusterRole//argocd-applicationset-controller|ClusterRoleBinding//argocd-applicationset-controller)
      # Opt in only after a live, cluster-wide ApplicationSet inventory proves
      # that these permissions are unused. The default remains fail-closed.
      if [ "${ALLOW_UNUSED_APPSET_CLUSTER_RBAC:-false}" = true ]; then
        printf 'OK - removal, unused %s: approved ApplicationSet inventory\n' "$object"
      else
        printf 'FIX %s: missing; ApplicationSet removal is not approved\n' "$object"
        rc=1
      fi
      ;;
    NetworkPolicy/argocd/*-network-policy)
      name="${object##*/}"
      replacement="${name%-network-policy}"
      # Names and named ports differ upstream. Accept only equivalent rules;
      # adding the approved instance selector can only narrow the peer set.
      if jq -en --arg name "$name" --arg replacement "$replacement" \
        --slurpfile expected "$tmp/expected.json" --slurpfile rendered "$tmp/rendered.json" '
        def normalize($ports):
          .spec |
          walk(if type == "object" and has("matchLabels") and
            .matchLabels["app.kubernetes.io/instance"] == "argocd"
            then del(.matchLabels["app.kubernetes.io/instance"]) else . end) |
          .ingress |= map(
            if has("ports") then .ports |= map(
              .protocol = (.protocol // "TCP") |
              if (.port | type) == "string" then
                .port = ($ports[.port] // error("Unresolved policy port"))
              else . end
            ) else . end
          ) |
          walk(if type == "array" then sort_by(tojson)
            elif type == "object" then to_entries | sort_by(.key) | from_entries
            else . end);
        [$expected[0][] | select(.kind == "NetworkPolicy" and
          .metadata.namespace == "argocd" and .metadata.name == $name)] as $old |
        [$rendered[0][] | select(.kind == "NetworkPolicy" and
          .metadata.namespace == "argocd" and .metadata.name == $replacement)] as $new |
        [$rendered[0][] | select(.spec.template.metadata.labels["app.kubernetes.io/name"] ==
          $new[0].spec.podSelector.matchLabels["app.kubernetes.io/name"]) |
          .spec.template.spec.containers[].ports[]? |
          select(.name != null) | {key:.name, value:.containerPort}] |
        from_entries as $ports |
        ($old | length) == 1 and ($new | length) == 1 and
          (($old[0] | normalize($ports)) == ($new[0] | normalize($ports)))
      ' >/dev/null; then
        printf 'OK - equivalent %s: replaced by NetworkPolicy/argocd/%s\n' "$object" "$replacement"
      else
        printf 'FIX %s: missing; replacement policy is not equivalent\n' "$object"
        rc=1
      fi
      ;;
    *) printf 'FIX %s: missing from render\n' "$object"; rc=1 ;;
  esac
done < "$tmp/missing"
while IFS= read -r object; do
  printf 'ADDED %s: classify in the install proof\n' "$object"
done < "$tmp/added"
if [ "$rc" -eq 0 ]; then echo "PASS no unapproved missing objects"; fi
exit "$rc"
