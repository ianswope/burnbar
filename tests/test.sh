#!/usr/bin/env bash
# Burn Bar test suite. Mirrors the shape used by other Omarchy plugins: validate
# the manifest, assert the contract the shell relies on, then exercise the
# collector against a synthetic fixture so the test never depends on whatever
# transcripts happen to be on the machine.

set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"

fail() { echo "FAIL: $*" >&2; exit 1; }
ok()   { echo "  ok  $*"; }

echo "== manifest =="
omarchy plugin validate "$repo_dir"
ok "omarchy plugin validate"

jq -e '
  .schemaVersion == 1 and
  .id == "nixfred.burnbar" and
  (.kinds | index("service")) != null and
  (.kinds | index("bar-widget")) != null and
  .entryPoints.service == "Service.qml" and
  .entryPoints.barWidget == "BarWidget.qml" and
  .barWidget.allowMultiple == false and
  .barWidget.defaultSection == "center"
' manifest.json >/dev/null || fail "manifest contract"
ok "manifest contract"

# The widget draws exactly one cell per bucket and aligns to the newest bucket.
# If these defaults ever drift apart again the strip silently covers less time
# than the tooltip claims — the bug this assertion exists to prevent.
man_bars=$(jq -r '.barWidget.defaults.bars' manifest.json)
qml_cells=$(grep -oP 'setting\("bars", \K[0-9]+' ../burnbar/BarWidget.qml | head -1)
svc_buckets=$(grep -oP 'boundedInt\("bars", \K[0-9]+' Service.qml | head -1)
[ "$man_bars" = "$qml_cells" ] || fail "manifest bars ($man_bars) != widget cells ($qml_cells)"
[ "$man_bars" = "$svc_buckets" ] || fail "manifest bars ($man_bars) != service buckets ($svc_buckets)"
ok "cell count == bucket count ($man_bars)"

echo "== runtime dependency =="
command -v python3 >/dev/null || fail "python3 missing"
python3 - <<'PY' || exit 1
import sys
assert sys.version_info >= (3, 8), "python 3.8+ required"
PY
ok "python3 present"
# stdlib only: a marketplace plugin must not need pip
! grep -qE '^\s*import\s+(requests|yaml|numpy)' bin/burnbar-collect || fail "third-party import"
ok "collector is stdlib-only"

echo "== collector against a fixture =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
fake_home="$tmp/home"
mkdir -p "$fake_home/.claude/projects/p" "$fake_home/.codex/sessions/2026/09/03"

now_iso=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
# Claude: the SAME message.id three times, as the streaming writer emits it.
# Correct handling counts 1000 tokens once, not three times.
for _ in 1 2 3; do
  printf '{"timestamp":"%s","message":{"id":"msg_dupe","model":"claude-test","usage":{"input_tokens":400,"cache_creation_input_tokens":100,"output_tokens":500,"cache_read_input_tokens":999999}}}\n' \
    "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
done
# Codex: one turn worth 300 billable (500 in - 300 cached + 100 out).
printf '{"timestamp":"%s","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":300,"cache_write_input_tokens":0,"output_tokens":100}}}}\n' \
  "$now_iso" > "$fake_home/.codex/sessions/2026/09/03/rollout-x.jsonl"

HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
out="$tmp/state/omarchy/burnbar/history.json"
[ -f "$out" ] || fail "no history.json written"
ok "history.json written"

jq -e '.bucketCount == 12 and (.buckets | length) == 12' "$out" >/dev/null \
  || fail "bucket count mismatch"
ok "12 buckets emitted"

ct=$(jq -r '.claude.total' "$out")
[ "$ct" = "1000" ] || fail "claude total $ct != 1000 (message.id dedupe broken, or cache reads counted)"
ok "claude dedupe by message.id + cache reads excluded"

xt=$(jq -r '.codex.total' "$out")
[ "$xt" = "300" ] || fail "codex total $xt != 300"
ok "codex per-turn delta math"

# Second run must be byte-identical: the incremental cache must not double-count
# points it replays from a file whose mtime is unchanged.
cp "$out" "$tmp/first.json"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
jq -S 'del(.generatedAt)' "$tmp/first.json" > "$tmp/a.json"
jq -S 'del(.generatedAt)' "$out" > "$tmp/b.json"
diff -q "$tmp/a.json" "$tmp/b.json" >/dev/null || fail "cached re-run changed totals"
ok "incremental cache is idempotent"

# Appending must be picked up via the tail read, not ignored.
printf '{"timestamp":"%s","message":{"id":"msg_new","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":250}}}\n' \
  "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
ct2=$(jq -r '.claude.total' "$out")
[ "$ct2" = "1250" ] || fail "append not picked up: $ct2 != 1250"
ok "tail read picks up appended records"

echo
echo "ALL TESTS PASSED"
