#!/usr/bin/env bun
// burnbar-collect — buckets Claude + Codex token burn into a rolling time window.
//
// Reads the raw agent transcripts (the only place per-turn token deltas with
// timestamps actually live) and writes one small JSON the QML widget watches.
// State lives under XDG_STATE_HOME, never inside the plugin directory: a plugin
// writing in its own dir makes Omarchy rebuild every plugin service.
//
// Claude:  ~/.claude/projects/**/*.jsonl   assistant lines carry message.usage.
//          The same assistant message is re-serialized up to 3x as it streams,
//          so message.id is the mandatory dedupe key.
// Codex:   ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl   event_msg lines with
//          payload.type === "token_count" carry info.last_token_usage, already
//          a per-turn delta.

import { readdirSync, statSync, existsSync, mkdirSync, writeFileSync, readFileSync } from "node:fs"
import { join } from "node:path"
import { homedir } from "node:os"

const HOME = homedir()
const STATE = process.env.XDG_STATE_HOME || join(HOME, ".local", "state")
const OUT_DIR = join(STATE, "omarchy", "burnbar")
const OUT_FILE = join(OUT_DIR, "history.json")
const CACHE_FILE = join(OUT_DIR, "scan-cache.json")
const USAGE_DIR = join(STATE, "omarchy", "agents", "usage")

const CLAUDE_ROOT = join(HOME, ".claude", "projects")
const CODEX_ROOT = join(HOME, ".codex", "sessions")

function intArg(flag: string, fallback: number): number {
  const i = process.argv.indexOf(flag)
  if (i < 0 || i + 1 >= process.argv.length) return fallback
  const n = parseInt(process.argv[i + 1]!, 10)
  return Number.isFinite(n) ? n : fallback
}

const WINDOW_MIN = Math.max(30, Math.min(1440, intArg("--window", 360)))
const BUCKETS = Math.max(8, Math.min(64, intArg("--buckets", 24)))
const BUCKET_MS = Math.round((WINDOW_MIN * 60_000) / BUCKETS)

const now = Date.now()
// Anchor buckets to the bucket grid so bars march instead of jittering.
const gridNow = Math.floor(now / BUCKET_MS) * BUCKET_MS
const windowStart = gridNow - (BUCKETS - 1) * BUCKET_MS

type Bucket = { t: number; claude: number; codex: number }
const buckets: Bucket[] = Array.from({ length: BUCKETS }, (_, i) => ({
  t: windowStart + i * BUCKET_MS,
  claude: 0,
  codex: 0,
}))

function bucketFor(ts: number): Bucket | null {
  if (!Number.isFinite(ts) || ts < windowStart) return null
  const idx = Math.floor((ts - windowStart) / BUCKET_MS)
  return idx >= 0 && idx < BUCKETS ? buckets[idx]! : null
}

// ── incremental scan cache ────────────────────────────────────────────────────
// Transcripts are append-only, so a file whose size and mtime are unchanged
// contributes exactly what it contributed last run. Cache that contribution
// keyed by bucket start so it survives the window sliding forward.
type CacheEntry = { size: number; mtime: number; points: [number, number][] }
type Cache = Record<string, CacheEntry>

let cache: Cache = {}
try {
  if (existsSync(CACHE_FILE)) cache = JSON.parse(readFileSync(CACHE_FILE, "utf8")) as Cache
} catch {
  cache = {}
}
const nextCache: Cache = {}

function walk(dir: string, match: (name: string) => boolean, out: string[] = []): string[] {
  let entries
  try {
    entries = readdirSync(dir, { withFileTypes: true })
  } catch {
    return out
  }
  for (const e of entries) {
    const p = join(dir, e.name)
    if (e.isDirectory()) walk(p, match, out)
    else if (e.isFile() && match(e.name)) out.push(p)
  }
  return out
}

function scanFile(path: string, extract: (line: string) => [number, number][]): [number, number][] {
  let st
  try {
    st = statSync(path)
  } catch {
    return []
  }
  // A file untouched since the window opened cannot hold points inside it.
  if (st.mtimeMs < windowStart) return []

  const key = path
  const hit = cache[key]
  if (hit && hit.size === st.size && hit.mtime === st.mtimeMs) {
    nextCache[key] = hit
    return hit.points
  }

  const points: [number, number][] = []
  let text = ""
  try {
    text = readFileSync(path, "utf8")
  } catch {
    return []
  }
  for (const line of text.split("\n")) {
    if (!line) continue
    for (const p of extract(line)) points.push(p)
  }
  nextCache[key] = { size: st.size, mtime: st.mtimeMs, points }
  return points
}

// ── Claude ───────────────────────────────────────────────────────────────────
const claudeByModel: Record<string, number> = {}
const claudeSeen = new Set<string>()
let claudeSessions = 0

function claudeExtract(line: string): [number, number][] {
  if (!line.includes("usage")) return []
  let d: any
  try {
    d = JSON.parse(line)
  } catch {
    return []
  }
  const m = d?.message
  const u = m?.usage
  if (!u) return []
  const id = String(m?.id || "")
  const ts = Date.parse(String(d?.timestamp || ""))
  if (!Number.isFinite(ts)) return []
  // Billable work: fresh input + what we paid to write cache + output.
  // Cache reads are deliberately excluded — they are the cheap path and would
  // swamp the graph (939M read vs 24M written on this machine).
  const tokens =
    Number(u.input_tokens || 0) +
    Number(u.cache_creation_input_tokens || 0) +
    Number(u.output_tokens || 0)
  if (!(tokens > 0)) return []
  const model = String(m?.model || "unknown")
  // Dedupe key travels with the point so the cache replays it correctly.
  return [[ts, tokens, id, model] as any]
}

// ── Codex ────────────────────────────────────────────────────────────────────
const codexByModel: Record<string, number> = {}
let codexSessions = 0

function codexExtract(line: string): [number, number][] {
  if (!line.includes("token_count")) return []
  let d: any
  try {
    d = JSON.parse(line)
  } catch {
    return []
  }
  const p = d?.payload
  if (p?.type !== "token_count") return []
  const last = p?.info?.last_token_usage
  if (!last) return []
  const ts = Date.parse(String(d?.timestamp || ""))
  if (!Number.isFinite(ts)) return []
  const tokens =
    Number(last.input_tokens || 0) -
    Number(last.cached_input_tokens || 0) +
    Number(last.cache_write_input_tokens || 0) +
    Number(last.output_tokens || 0)
  if (!(tokens > 0)) return []
  return [[ts, Math.max(0, tokens), "", "codex"] as any]
}

// Claude transcripts
for (const f of walk(CLAUDE_ROOT, (n) => n.endsWith(".jsonl"))) {
  const pts = scanFile(f, claudeExtract)
  if (!pts.length) continue
  let touched = false
  for (const pt of pts as any[]) {
    const [ts, tokens, id, model] = pt
    if (id && claudeSeen.has(id)) continue
    if (id) claudeSeen.add(id)
    const b = bucketFor(ts)
    if (!b) continue
    b.claude += tokens
    claudeByModel[model] = (claudeByModel[model] || 0) + tokens
    touched = true
  }
  if (touched) claudeSessions++
}

// Codex rollouts
for (const f of walk(CODEX_ROOT, (n) => n.startsWith("rollout-") && n.endsWith(".jsonl"))) {
  const pts = scanFile(f, codexExtract)
  if (!pts.length) continue
  let touched = false
  for (const pt of pts as any[]) {
    const [ts, tokens] = pt
    const b = bucketFor(ts)
    if (!b) continue
    b.codex += tokens
    codexByModel["codex"] = (codexByModel["codex"] || 0) + tokens
    touched = true
  }
  if (touched) codexSessions++
}

// ── limits, straight off the records omarchy-agent-usage-update maintains ────
function limitsFor(agent: string): any[] {
  try {
    const raw = JSON.parse(readFileSync(join(USAGE_DIR, agent + ".json"), "utf8"))
    const out = Array.isArray(raw?.limits) ? raw.limits : []
    return out.map((l: any) => ({
      label: String(l?.label || ""),
      percent: Number(l?.percent || 0),
      resetsAt: String(l?.resetsAt || ""),
    }))
  } catch {
    return []
  }
}

const claudeTotal = buckets.reduce((a, b) => a + b.claude, 0)
const codexTotal = buckets.reduce((a, b) => a + b.codex, 0)

const payload = {
  generatedAt: now,
  windowMinutes: WINDOW_MIN,
  bucketMinutes: BUCKET_MS / 60_000,
  bucketCount: BUCKETS,
  buckets,
  claude: {
    total: claudeTotal,
    peak: buckets.reduce((a, b) => Math.max(a, b.claude), 0),
    sessions: claudeSessions,
    byModel: claudeByModel,
    limits: limitsFor("claude"),
  },
  codex: {
    total: codexTotal,
    peak: buckets.reduce((a, b) => Math.max(a, b.codex), 0),
    sessions: codexSessions,
    byModel: codexByModel,
    limits: limitsFor("codex"),
  },
}

mkdirSync(OUT_DIR, { recursive: true })
// Write-then-rename so the watching FileView never sees a half file.
const tmp = OUT_FILE + ".tmp"
writeFileSync(tmp, JSON.stringify(payload))
require("node:fs").renameSync(tmp, OUT_FILE)

try {
  writeFileSync(CACHE_FILE, JSON.stringify(nextCache))
} catch {
  /* cache is an optimisation; losing it only costs a slow run */
}

if (process.argv.includes("--print")) {
  console.log(JSON.stringify(payload, null, 2))
}
