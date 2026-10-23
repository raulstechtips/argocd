#!/usr/bin/env bash
# Offline tests for scripts/retention.sh using a stub gh. Run: bash test/retention_test.sh
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
script="$root/scripts/retention.sh"
fixture="$root/test/fixtures/retention-versions.json"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
# Like the real API: raulstechtips is an organization, so /users/ paths return 404.
case " $* " in
  *" /users/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *" /orgs/raulstechtips/packages/container/charts%2Fargocd/versions"*) ;;
  *) echo "gh: unexpected path (HTTP 404)" >&2; exit 1 ;;
esac
case " $* " in
  *" DELETE "*) exit 0 ;;
esac
case "${STUB_MODE:-ok}" in
  404) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  500) echo "gh: Internal Server Error (HTTP 500)" >&2; exit 1 ;;
  paged) jq -c '.[0:3]' "$STUB_FIXTURE"; jq -c '.[3:]' "$STUB_FIXTURE" ;;
  *) cat "$STUB_FIXTURE" ;;
esac
STUB
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" STUB_LOG="$T/log" STUB_FIXTURE="$fixture"
export RETENTION_NOW=1792627200   # 2026-10-22T00:00:00Z
pass=0; failn=0
check() { if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass+1)); else echo "FAIL $1: expected [$3] got [$2]"; failn=$((failn+1)); fi; }
run() { : >"$STUB_LOG"; out="$("$@" 2>&1)"; rc=$?; }
deleted() { grep -c 'DELETE' "$STUB_LOG" || true; }
delids() { grep 'DELETE' "$STUB_LOG" | sed -E 's#.*/versions/([0-9]+)$#\1#' | sort | tr '\n' ' '; }
nonzero() { if [ "$1" -ne 0 ]; then echo yes; else echo no; fi; }

# 1 offline file, dry-run: decisions right, gh never called
RETENTION_VERSIONS_FILE="$fixture" run bash "$script" --dry-run
check "offline dry-run rc" "$rc" 0
check "offline would-delete 104+105" "$(echo "$out" | grep '^would-delete' | sed -E 's/^would-delete id=([0-9]+).*/\1/' | tr '\n' ' ')" "104 105 "
check "offline keeps 4" "$(echo "$out" | grep -c 'KEEP')" 4
check "offline untagged kept w/ notice" "$(echo "$out" | grep -c '::notice::KEEP id=106')" 1
check "offline main old kept" "$(echo "$out" | grep -c 'KEEP id=101 .*has main release tag')" 1
check "offline gh calls" "$(wc -l <"$STUB_LOG" | tr -d ' ')" 0
check "offline no DELETE line" "$(echo "$out" | grep -c '^DELETE')" 0

# 2 stub list, dry-run: one GET, zero DELETE calls
run bash "$script" --dry-run
check "dry-run rc" "$rc" 0
check "dry-run DELETE calls" "$(deleted)" 0
check "dry-run list calls" "$(wc -l <"$STUB_LOG" | tr -d ' ')" 1

# 3 apply: DELETE only for 104 and 105
run bash "$script" --apply
check "apply rc" "$rc" 0
check "apply DELETE count" "$(deleted)" 2
check "apply DELETE ids" "$(delids)" "104 105 "

# 4 paginated output (several arrays)
STUB_MODE=paged run bash "$script" --apply
check "paged rc" "$rc" 0
check "paged DELETE ids" "$(delids)" "104 105 "

# 5 404 -> exit 0 notice
STUB_MODE=404 run bash "$script" --apply
check "404 rc" "$rc" 0
check "404 notice" "$(echo "$out" | grep -c '::notice::')" 1
check "404 no DELETE" "$(deleted)" 0

# 6 500 -> non-zero
STUB_MODE=500 run bash "$script" --apply
check "500 nonzero" "$(nonzero "$rc")" yes
check "500 no DELETE" "$(deleted)" 0

# 7 malformed input -> fail closed, no DELETE
bad="$T/bad.json"
echo 'not json{' >"$bad"; STUB_FIXTURE="$bad" run bash "$script" --apply
check "bad json nonzero" "$(nonzero "$rc")" yes
check "bad json no DELETE" "$(deleted)" 0
jq 'map(if .id==104 then del(.created_at) else . end)' "$fixture" >"$bad"; STUB_FIXTURE="$bad" run bash "$script" --apply
check "missing created_at nonzero" "$(nonzero "$rc")" yes
check "missing created_at no DELETE" "$(deleted)" 0
jq 'map(if .id==104 then .created_at="yesterday" else . end)' "$fixture" >"$bad"; STUB_FIXTURE="$bad" run bash "$script" --apply
check "bad date nonzero" "$(nonzero "$rc")" yes
check "bad date no DELETE" "$(deleted)" 0
jq 'map(if .id==104 then del(.metadata) else . end)' "$fixture" >"$bad"; STUB_FIXTURE="$bad" run bash "$script" --apply
check "missing tags nonzero" "$(nonzero "$rc")" yes
check "missing tags no DELETE" "$(deleted)" 0
echo '{"message":"x"}' >"$bad"; STUB_FIXTURE="$bad" run bash "$script" --apply
check "non-array nonzero" "$(nonzero "$rc")" yes
check "non-array no DELETE" "$(deleted)" 0

# 8 org API path: a /users/ call is a defect (404 on an org would hide a no-op retention)
run bash "$script" --apply
check "no /users/ path called" "$(grep -c '/users/' "$STUB_LOG" || true)" 0
check "list uses orgs path" "$(grep -c '^api --paginate /orgs/raulstechtips/packages/container/charts%2Fargocd/versions?' "$STUB_LOG")" 1
check "delete uses orgs path" "$(grep -c '^api --method DELETE /orgs/raulstechtips/packages/container/charts%2Fargocd/versions/10[45]$' "$STUB_LOG")" 2
check "script has no /users/ path" "$(grep -c 'users/' "$script" || true)" 0

# 8b fail-safe classifier: only dated branch builds can be deleted. Every other shape is KEEP.
extra="$T/extra.json"
mk() { jq -n --argjson id "$1" --arg c "$2" --argjson tags "$3" '{id:$id,created_at:$c,metadata:{container:{tags:$tags}}}'; }
{
  mk 301 2026-09-01T10:00:00Z '["3.0.0"]'
  mk 302 2026-09-01T10:00:00Z '["latest"]'
  mk 303 2026-09-01T10:00:00Z '["v3.0.0"]'
  mk 304 2026-09-01T10:00:00Z '["3.0.0-feature-devsecops-54-abc1234"]'
  mk 305 2026-09-01T10:00:00Z '[]'
  mk 306 2026-09-01T10:00:00Z '["3.0.0-main-abc1234-7","latest"]'
  mk 307 2026-09-01T10:00:00Z '["3.0.0-feature-devsecops-54-abc1234-7"]'
  mk 308 2026-10-21T10:00:00Z '["3.0.0-feature-devsecops-54-abc1234-7"]'
  mk 309 2026-09-01T10:00:00Z '["3.0.0-feature-devsecops-54-abc1234-7","latest"]'
  mk 310 2026-09-01T10:00:00Z '["3.0.0-feature-devsecops-54-abc1234-7","3.0.0-bugfix-devsecops-54-def5678-8"]'
} | jq -s '.' >"$extra"
RETENTION_VERSIONS_FILE="$extra" run bash "$script" --dry-run
check "classifier rc" "$rc" 0
for id in 301 302 303 304 305 306 308 309; do
  check "classifier KEEP $id" "$(echo "$out" | grep -c "KEEP id=$id ")" 1
done
check "classifier would-delete 307+310" "$(echo "$out" | grep '^would-delete' | sed -E 's/^would-delete id=([0-9]+).*/\1/' | tr '\n' ' ')" "307 310 "
STUB_FIXTURE="$extra" run bash "$script" --apply
check "classifier apply rc" "$rc" 0
check "classifier apply DELETE ids" "$(delids)" "307 310 "

# 9 mode argument required
run bash "$script"
check "no mode rc" "$rc" 2

echo "passed=$pass failed=$failn"
[ "$failn" -eq 0 ]
