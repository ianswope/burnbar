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
  .barWidget.defaultSection == "center" and
  .barWidget.defaults.showLocal == true and
  (.barWidget.schema | map(.key) | index("localThreshold")) != null
' manifest.json >/dev/null || fail "manifest contract"
ok "manifest contract"

# The widget draws exactly one cell per bucket and aligns to the newest bucket.
# It reads the count from the service; the only thing that can drift is the
# fallback clamp each file carries for the moment before they bind, so both
# clamps must be byte-identical and agree with the manifest's default and
# range. (bars: 0 used to be 12 in the widget and 6 in the service.)
clamp() { grep -oP "boundedInt\(\"$1\", [0-9, ]+\)" "$2" | head -1 || true; }
man_bars=$(jq -r '.barWidget.defaults.bars' manifest.json)
man_bars_min=$(jq -r '.barWidget.schema[] | select(.key=="bars") | .min' manifest.json)
man_bars_max=$(jq -r '.barWidget.schema[] | select(.key=="bars") | .max' manifest.json)
qml_clamp=$(clamp bars BarWidget.qml); svc_clamp=$(clamp bars Service.qml)
[ -n "$qml_clamp" ] && [ "$qml_clamp" = "$svc_clamp" ] || fail "bars clamp differs: widget '$qml_clamp' vs service '$svc_clamp'"
[ "$svc_clamp" = "boundedInt(\"bars\", $man_bars, $man_bars_min, $man_bars_max)" ] || fail "bars clamp '$svc_clamp' != manifest ($man_bars, $man_bars_min..$man_bars_max)"
grep -q 'svc ? svc.bucketCount' BarWidget.qml || fail "widget must take its cell count from the service"
ok "cell count == bucket count ($man_bars, clamp $man_bars_min..$man_bars_max)"

# Same trap on the local lane: the widget draws localCells cells, the service
# keeps a ring localCells long. Drift and the oldest sample is drawn as zero.
man_local=$(jq -r '.barWidget.defaults.localCells' manifest.json)
man_local_min=$(jq -r '.barWidget.schema[] | select(.key=="localCells") | .min' manifest.json)
man_local_max=$(jq -r '.barWidget.schema[] | select(.key=="localCells") | .max' manifest.json)
qml_lclamp=$(clamp localCells BarWidget.qml); svc_lclamp=$(clamp localCells Service.qml)
[ -n "$qml_lclamp" ] && [ "$qml_lclamp" = "$svc_lclamp" ] || fail "localCells clamp differs: widget '$qml_lclamp' vs service '$svc_lclamp'"
[ "$svc_lclamp" = "boundedInt(\"localCells\", $man_local, $man_local_min, $man_local_max)" ] || fail "localCells clamp '$svc_lclamp' != manifest"
grep -q 'svc ? svc.localCells' BarWidget.qml || fail "widget must take its local cell count from the service"
ok "local cell count == local ring length ($man_local, clamp $man_local_min..$man_local_max)"

echo "== runtime dependency =="
command -v python3 >/dev/null || fail "python3 missing"
python3 - <<'PY' || exit 1
import sys
assert sys.version_info >= (3, 8), "python 3.8+ required"
PY
ok "python3 present"
# stdlib only: a marketplace plugin must not need pip
for script in bin/burnbar-collect bin/burnbar-local-status bin/burnbar-local-control; do
  ! grep -qE '^\s*import\s+(requests|yaml|numpy)' "$script" || fail "third-party import in $script"
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$script" || fail "$script does not parse"
done
ok "all three collectors are stdlib-only and parse"

echo "== local intelligence unit tests =="
python3 -m unittest discover -s tests -p 'test_local_scripts.py' -q >/dev/null \
  || fail "local script unit tests"
ok "ollama url/json hardening tests"

# The local probe must degrade to a clean offline JSON object rather than
# crashing when nothing is listening — that path is what draws the red core.
offline=$(OLLAMA_HOST=http://127.0.0.1:1 python3 bin/burnbar-local-status --threshold 8)
echo "$offline" | jq -e '.online == false and .load == 0' >/dev/null \
  || fail "offline probe did not report a clean offline object"
ok "local probe degrades to offline JSON"

echo "== collector against a fixture =="
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export XDG_STATE_HOME="$tmp/state"
# The caller's real cache must never leak into the fixture, and the clock is
# pinned one minute past the next 30-minute grid line: two runs then compare
# byte for byte across a bucket boundary, and the window arithmetic below is
# deterministic. Fixture records stamped "now" are 1–31 minutes old to it.
export XDG_CACHE_HOME="$tmp/cache"
real_now=$(date +%s)
pinned=$(( ( (real_now / 1800) + 1 ) * 1800 + 60 ))
export BURNBAR_NOW_MS=$(( pinned * 1000 ))
# Local tokens come from the Ollama journal; the fixture must never read the
# real one. An empty file means "journal readable, nothing in it".
: > "$tmp/journal-empty.txt"
export BURNBAR_OLLAMA_JOURNAL="$tmp/journal-empty.txt"
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

# Plan limits are copied out of Omarchy's usage records together with the
# record's own timestamp and status text, so the widget can refuse to present
# a stale 0% as live. This record is eight hours old and says the sign-in
# expired; the Codex record does not exist at all.
mkdir -p "$tmp/state/omarchy/agents/usage"
old_iso=$(date -u -d '8 hours ago' +%Y-%m-%dT%H:%M:%S+00:00)
future_iso=$(date -u -d '2 hours' +%Y-%m-%dT%H:%M:%S+00:00)
printf '{"limits":[{"label":"Weekly (7-day)","percent":0.42,"resetsAt":"%s"}],"updatedAt":"%s","usageStatusText":"Sign-in expired"}\n' \
  "$future_iso" "$old_iso" > "$tmp/state/omarchy/agents/usage/claude.json"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
jq -e '.claude.limits[0].percent == 0.42 and .claude.limits[0].resetsAt != "" and .claude.limitsStatus == "Sign-in expired"' "$out" >/dev/null \
  || fail "limits or status not carried from the usage record"
at=$(jq -r '.claude.limitsMeasuredAt' "$out")
age_h=$(( ( $(date +%s) * 1000 - at ) / 3600000 ))
{ [ "$age_h" -ge 7 ] && [ "$age_h" -le 9 ]; } || fail "limitsMeasuredAt is not the record's own timestamp (age ${age_h}h)"
jq -e '.codex.limits == [] and .codex.limitsMeasuredAt == 0 and .codex.limitsStatus == ""' "$out" >/dev/null \
  || fail "a missing usage record should read as no limits, never updated"
ok "plan limits carry the record's own timestamp and status"

# Omarchy's Claude collector re-stamps its record with *cached* limits when
# the probe fails, so updatedAt can be fresh while the figure is hours old.
# The probe cache next to it carries fetchedAtMs from the last successful
# probe; that is the measurement time. Here the record says "now", the probe
# cache says eight hours ago, and the record is a silent-fallback one.
mkdir -p "$tmp/cache/omarchy/agent-usage"
now_plain=$(date -u +%Y-%m-%dT%H:%M:%S+00:00)
old_ms=$(( ( $(date +%s) - 8 * 3600 ) * 1000 ))
printf '{"fetchedAtMs":%s,"limits":[]}\n' "$old_ms" > "$tmp/cache/omarchy/agent-usage/claude-limits.json"
printf '{"limits":[{"label":"Weekly (7-day)","percent":0.0,"resetsAt":"%s"}],"updatedAt":"%s","usageStatusText":"","retryAdvised":true}\n' \
  "$future_iso" "$now_plain" > "$tmp/state/omarchy/agents/usage/claude.json"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.limitsMeasuredAt' "$out")" = "$old_ms" ] \
  || fail "a re-stamped fallback record must carry the probe's own fetchedAtMs"
[ "$(jq -r '.claude.limitsStatus' "$out")" = "last probe failed, showing last known" ] \
  || fail "retryAdvised on a silent fallback should surface as status"
ok "measurement time comes from the probe cache, not the record stamp"

# Every percentage is normalised on its own: null, junk, NaN, negative and
# percent-scaled values become -1 (unknown) and the run still succeeds and
# still writes valid JSON. Before, "bad" aborted both agents' collection and
# "NaN" wrote a file the widget could not parse.
rm -f "$tmp/cache/omarchy/agent-usage/claude-limits.json"
printf '{"limits":[{"label":"a","percent":null,"resetsAt":"%s"},{"label":"b","percent":"bad","resetsAt":"%s"},{"label":"c","percent":"NaN","resetsAt":"%s"},{"label":"d","percent":-1,"resetsAt":"%s"},{"label":"e","percent":66,"resetsAt":"%s"},{"label":"Weekly (7-day)","percent":0.42,"resetsAt":"%s"}],"updatedAt":"%s"}\n' \
  "$future_iso" "$future_iso" "$future_iso" "$future_iso" "$future_iso" "$future_iso" "$now_plain" \
  > "$tmp/state/omarchy/agents/usage/claude.json"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "junk percentages aborted the collector"
jq -e '[.claude.limits[].percent] == [-1, -1, -1, -1, -1, 0.42]' "$out" >/dev/null \
  || fail "percent normalisation wrong: $(jq -c '[.claude.limits[].percent]' "$out")"
ok "junk percentages become -1, never 0, never a crash, never NaN on disk"

# A syntactically valid record with the wrong shape must be skipped, not
# abort the run — and the totals must be exactly what the good records say.
printf '{"timestamp":"%s","message":{"id":"msg_junk","model":"claude-test","usage":{"input_tokens":"unknown","output_tokens":[]}}}\n' \
  "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","payload":{"type":"token_count","info":"bad"}}\n' \
  "$now_iso" >> "$fake_home/.codex/sessions/2026/09/03/rollout-x.jsonl"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "a malformed record aborted the collector"
[ "$(jq -r '.claude.total' "$out")" = "1250" ] || fail "malformed Claude record changed the total"
[ "$(jq -r '.codex.total' "$out")" = "300" ] || fail "malformed Codex record changed the total"
ok "malformed records are skipped, not fatal"

# A transcript rewritten to different content of the same length, with a
# newer mtime, must be rescanned — the old cache resumed at EOF and kept the
# stale points forever.
same="$fake_home/.claude/projects/p/same.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_same1","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":100}}}\n' "$now_iso" > "$same"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "1350" ] || fail "same-length fixture setup: $(jq -r '.claude.total' "$out")"
printf '{"timestamp":"%s","message":{"id":"msg_same2","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":700}}}\n' "$now_iso" > "$same"
touch -m -d "@$(( $(date +%s) + 5 ))" "$same"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "1950" ] || fail "equal-size rewrite kept stale points: $(jq -r '.claude.total' "$out")"
ok "equal-size rewrite with a new mtime is rescanned"

# ── 1.3.3 audit fixtures ─────────────────────────────────────────────────────
# Codex's counter is cumulative. A rate-limit refresh re-emits the same
# last_token_usage with an unchanged total, and counting last_token_usage
# counted it twice. Three events: a turn, the same snapshot again, a second
# turn — 300 + 0 + 250.
cx2="$fake_home/.codex/sessions/2026/09/03/rollout-y.jsonl"
tc() { printf '{"timestamp":"%s","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"cache_write_input_tokens":0,"output_tokens":%s},"total_token_usage":{"input_tokens":%s,"cached_input_tokens":%s,"cache_write_input_tokens":0,"output_tokens":%s}}}}\n' "$now_iso" "$@"; }
{ tc 500 300 100 500 300 100; tc 500 300 100 500 300 100; tc 200 0 50 700 300 150; } > "$cx2"
before_total=$(jq -r '.codex.total' "$out"); before_turns=$(jq -r '.codex.turns' "$out")
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.codex.total' "$out")" = "$(( before_total + 550 ))" ] \
  || fail "codex cumulative delta wrong: $(jq -r '.codex.total' "$out"), expected $(( before_total + 550 ))"
[ "$(jq -r '.codex.turns' "$out")" = "$(( before_turns + 2 ))" ] || fail "a repeated codex snapshot was counted as a turn"
ok "codex counts cumulative deltas: a repeated snapshot is not a second turn"

# The baseline survives an incremental tail read: a fourth event appended to
# the same file lands as its delta alone (800-300+170 minus 700-300+150 = 120).
tc 100 0 20 800 300 170 >> "$cx2"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.codex.total' "$out")" = "$(( before_total + 670 ))" ] \
  || fail "codex baseline lost across a tail read: $(jq -r '.codex.total' "$out")"
ok "codex cumulative baseline survives an incremental tail read"

# Negative, overflowing (1e999 parses as a float infinity) and boolean counts
# are rejected as records; a record that only read cache is still a turn and
# still feeds the cache-read line, it just adds nothing to the heat.
cl_before=$(jq -r '.claude.total' "$out"); cr_before=$(jq -r '.claude.split.cacheRead' "$out"); turns_before=$(jq -r '.claude.turns' "$out")
printf '{"timestamp":"%s","message":{"id":"msg_neg","model":"claude-test","usage":{"input_tokens":-50,"output_tokens":100}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_over","model":"claude-test","usage":{"input_tokens":1e999,"output_tokens":1}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_bool","model":"claude-test","usage":{"input_tokens":true,"output_tokens":1}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_cacheonly","model":"claude-test","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0,"cache_read_input_tokens":1000}}}\n' "$now_iso" >> "$fake_home/.claude/projects/p/s.jsonl"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "audit records aborted the collector"
[ "$(jq -r '.claude.total' "$out")" = "$cl_before" ] || fail "a negative, overflowing or boolean count changed the total"
[ "$(jq -r '.claude.split.cacheRead' "$out")" = "$(( cr_before + 1000 ))" ] || fail "cache-read-only record lost from the split"
[ "$(jq -r '.claude.turns' "$out")" = "$(( turns_before + 1 ))" ] || fail "cache-read-only record not counted as a turn"
ok "negative, overflowing and boolean counts are rejected; a cache-read-only turn is kept"

# Streaming re-serialises a message with growing output. The final revision
# is the one that counts, not the first seen.
rev="$fake_home/.claude/projects/p/rev.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_rev","model":"claude-test","usage":{"input_tokens":100,"output_tokens":1}}}\n' "$now_iso" > "$rev"
printf '{"timestamp":"%s","message":{"id":"msg_rev","model":"claude-test","usage":{"input_tokens":100,"output_tokens":100}}}\n' "$now_iso" >> "$rev"
cl_before=$(jq -r '.claude.total' "$out")
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "$(( cl_before + 200 ))" ] \
  || fail "claude dedupe kept the preliminary revision: $(jq -r '.claude.total' "$out")"
ok "claude dedupe keeps the final streamed revision, not the first"

# A rewrite that happens to be LONGER than the cached file is not an append.
# The bytes just before the saved offset no longer match, so it is rescanned.
grow="$fake_home/.claude/projects/p/grow.jsonl"
printf '{"timestamp":"%s","message":{"id":"msg_g1","model":"claude-test","usage":{"input_tokens":0,"output_tokens":100}}}\n' "$now_iso" > "$grow"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
cl_before=$(jq -r '.claude.total' "$out")
printf '{"timestamp":"%s","message":{"id":"msg_grow_two","model":"claude-test","usage":{"input_tokens":0,"output_tokens":900}}}\n' "$now_iso" > "$grow"
touch -m -d "@$(( real_now + 7 ))" "$grow"
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "$(( cl_before - 100 + 900 ))" ] \
  || fail "a longer rewrite was resumed as an append: $(jq -r '.claude.total' "$out")"
ok "a longer rewrite fails the tail fingerprint and is rescanned"

# A malformed cache entry is a cache miss for that file, never a crash that
# repeats on every run.
cache="$tmp/state/omarchy/burnbar/scan-cache.json"
jq --arg k "$fake_home/.claude/projects/p/s.jsonl" '.files[$k].points = [["bad"]]' "$cache" > "$cache.new" && mv "$cache.new" "$cache"
cl_before=$(jq -r '.claude.total' "$out")
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12 || fail "a malformed cache entry aborted the collector"
[ "$(jq -r '.claude.total' "$out")" = "$cl_before" ] || fail "a malformed cache entry changed the total: $(jq -r '.claude.total' "$out")"
ok "a malformed cache entry is a cache miss, not a crash"

# Two clocks. The strip's grid holds BUCKETS-1 whole buckets plus the partial
# newest one, so at one minute past a grid line it reaches back 331 minutes;
# the window is 360. A 345-minute-old record must be in the total and in no
# bucket.
old_ts=$(date -u -d "@$(( pinned - 345 * 60 ))" +%Y-%m-%dT%H:%M:%S.000Z)
printf '{"timestamp":"%s","message":{"id":"msg_old","model":"claude-test","usage":{"input_tokens":0,"output_tokens":4000}}}\n' "$old_ts" > "$fake_home/.claude/projects/p/old.jsonl"
cl_before=$(jq -r '.claude.total' "$out")
HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
[ "$(jq -r '.claude.total' "$out")" = "$(( cl_before + 4000 ))" ] \
  || fail "a 345-minute-old record fell out of a 360-minute window: $(jq -r '.claude.total' "$out")"
bsum=$(jq -r '[.buckets[].claude] | add' "$out")
[ "$bsum" = "$cl_before" ] || fail "grid buckets should exclude the pre-grid record (bucket sum $bsum, expected $cl_before)"
jq -e '.claude.trailing.m60 >= 0 and .claude.trailing.m5 >= 0 and .claude.trailing.m5 <= .claude.trailing.m60' "$out" >/dev/null \
  || fail "trailing sums missing or inconsistent"
ok "window totals are exact while the strip's grid stays aligned"

# No activity means no peak time: the panel shows "--", not the window start.
jq -e '(.codex.peak > 0 and .codex.peakAt > 0) or (.codex.peak == 0 and .codex.peakAt == 0)' "$out" >/dev/null \
  || fail "peakAt disagrees with peak"
ok "peakAt is 0 when nothing peaked"

# ── local tokens from the Ollama journal ─────────────────────────────────────
# Real line shapes from journalctl -o short-unix on Ollama 0.32. Two tasks on
# one model: prompt 120 with 36 cached and 84 evaluated + 8 generated, then a
# prompt of 20 with nothing cached and 30 generated. Burn = 92 + 50 = 142;
# cached prefix 36 rides along as the cache read.
j="$tmp/journal.txt"
t0=$(( pinned - 600 ))
cat > "$j" <<EOF
$t0.000000 vic ollama[785]: print_info: general.name          = Meta Llama 3.1 8B Instruct
$(( t0 + 1 )).100000 vic ollama[785]: slot   operator(): id  0 | task 5 | new prompt, n_ctx_slot = 4096, n_keep = 4, task.n_tokens = 120
$(( t0 + 1 )).100000 vic ollama[785]: slot   operator(): id  0 | task 5 | cached n_tokens = 36, memory_seq_rm [36, end)
$(( t0 + 2 )).200000 vic ollama[785]: slot print_timing: id  0 | task 5 | prompt eval time =      90.84 ms /    84 tokens (    1.08 ms per token,   924.74 tokens per second)
$(( t0 + 2 )).200000 vic ollama[785]: slot print_timing: id  0 | task 5 |        eval time =     218.95 ms /     8 tokens (   31.28 ms per token,    31.97 tokens per second)
$(( t0 + 2 )).200000 vic ollama[785]: slot      release: id  0 | task 5 | stop processing: n_tokens = 127, truncated = 0
$(( t0 + 10 )).000000 vic ollama[785]: slot   operator(): id  0 | task 6 | new prompt, n_ctx_slot = 4096, n_keep = 4, task.n_tokens = 20
$(( t0 + 11 )).000000 vic ollama[785]: slot print_timing: id  0 | task 6 | prompt eval time =      20.00 ms /    20 tokens (    1.00 ms per token,  1000.00 tokens per second)
$(( t0 + 11 )).000000 vic ollama[785]: slot print_timing: id  0 | task 6 |        eval time =     900.00 ms /    30 tokens (   30.00 ms per token,    33.33 tokens per second)
$(( t0 + 11 )).000000 vic ollama[785]: slot      release: id  0 | task 6 | stop processing: n_tokens = 49, truncated = 0
$(( t0 + 12 )).000000 vic ollama[785]: slot   operator(): id  0 | task 7 | new prompt, n_ctx_slot = 4096, n_keep = 4, task.n_tokens = 999
EOF
BURNBAR_OLLAMA_JOURNAL="$j" HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
jq -e '.local.available == true and .local.total == 142 and .local.turns == 2
  and .local.split.input == 104 and .local.split.output == 38 and .local.split.cacheRead == 36 and .local.split.cacheWrite == 0
  and .local.byModel["Meta Llama 3.1 8B Instruct"] == 142' "$out" >/dev/null \
  || fail "local journal parse wrong: $(jq -c '.local | {available, total, turns, split, byModel}' "$out")"
ct=$(jq -r '.claude.total' "$out"); xt=$(jq -r '.codex.total' "$out")
want=$(python3 -c "print(round(142 / (142 + $ct + $xt), 6))")
got=$(jq -r '.offloadShare | . * 1000000 | round / 1000000' "$out")
[ "$got" = "$want" ] || fail "offload share $got != $want"
jq -e '[.buckets[].local] | add == 142' "$out" >/dev/null || fail "local tokens missing from the buckets"
ok "local tokens parsed from the runner journal; offload share = local / all burn"

# An unreadable journal is reported with its reason. The last-known points
# stay in the cache (the panel hides the numbers while available is false),
# so the total is not asserted here.
BURNBAR_OLLAMA_JOURNAL="$tmp/does-not-exist.txt" HOME="$fake_home" python3 bin/burnbar-collect --window 360 --buckets 12
jq -e '.local.available == false and (.local.reason | length) > 0' "$out" >/dev/null \
  || fail "unreadable journal not reported: $(jq -c '.local | {available, reason, total}' "$out")"
ok "an unreadable journal reads as unavailable with a reason"

echo
echo "ALL TESTS PASSED"
