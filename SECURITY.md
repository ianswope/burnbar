# Security and privacy

Burn Bar is an unsandboxed Omarchy shell plugin. Installing it means trusting
the QML and Python in this repository with the permissions of your graphical
desktop session. Review the source and the commit you intend to install.

## Read this part

**Burn Bar reads your AI coding transcripts.** To count tokens it opens every
file under:

- `~/.claude/projects/**/*.jsonl` — your complete Claude Code conversations
- `~/.codex/sessions/**/rollout-*.jsonl` — your complete Codex sessions

These files contain your prompts, the assistant's replies, and the contents of
files you worked on. There is no way to count per-turn tokens without reading
them, because the token counts are interleaved with the conversation. If you
are not comfortable with a bar widget opening those files, do not install this.

## What it does with them

1. `bin/burnbar-collect` (Python 3, standard library only) reads each line and
   keeps **only numbers**: a timestamp, token counts split into input, cache
   write, output and cache read, a model name, and — for Claude — the opaque
   `message.id` used to deduplicate streamed records.
2. No prompt text, reply text, file content, file path from inside a
   conversation, or project name is extracted, stored, or displayed.
3. Results are bucketed by time and written to
   `~/.local/state/omarchy/burnbar/history.json`.
4. `Service.qml` watches that file; `BarWidget.qml` and `BurnPanel.qml` render it.

## What leaves your machine

Nothing leaves your machine. Burn Bar has no telemetry, no update check, and
no remote endpoint.

The only network traffic it generates is HTTP to **your own Ollama server**,
for the local lane and the model-control buttons. The endpoint is `OLLAMA_HOST`
if set, otherwise `http://127.0.0.1:11434`. The calls are:

| Script | Endpoint | Purpose |
|---|---|---|
| `bin/burnbar-local-status` | `GET /api/ps` | Which models are resident, their size and `expires_at` |
| `bin/burnbar-local-status` | `GET /api/version` | Ollama version for the cockpit header |
| `bin/burnbar-local-control` | `GET /api/tags`, `GET /api/ps` | Installed and resident model lists |
| `bin/burnbar-local-control` | `POST /api/generate` | Warm (`keep_alive: -1`) or evict (`keep_alive: 0`) a model you picked; no prompt is sent |

The URL is validated (http/https with a host) before use, responses are capped
at 1 MiB, model counts and string fields are bounded, and non-finite JSON
numbers are rejected. If Ollama is unreachable the lane reads OFFLINE and the
next poll simply runs on the next timer tick.

## Files it writes

| Path | Contents |
|---|---|
| `~/.local/state/omarchy/burnbar/history.json` | Bucketed token totals, per-agent splits and plan-limit percentages |
| `~/.local/state/omarchy/burnbar/scan-cache.json` | Per-file size/mtime/offset plus the extracted numeric points, so unchanged files are not re-read |

`scan-cache.json` keys on absolute transcript paths, which include your project
directory names. It is written with your account's default permissions under
your own state directory and is never transmitted.

Burn Bar writes nothing inside its own plugin directory, and modifies no
Omarchy, Hyprland, or application configuration.

## Processes it runs

Three scripts, all `python3`, all as your user, all from the plugin's own
`bin/` directory:

- `burnbar-collect` on the refresh timer. It takes no input from the network
  and no input from the widget beyond two integers (window length and bucket
  count) that are clamped to fixed ranges before use. A run that exceeds 30
  seconds is killed by a watchdog.
- `burnbar-local-status` on the local poll timer. It also invokes `nvidia-smi`
  or `rocm-smi` with fixed query arguments, if present, to read GPU telemetry.
- `burnbar-local-control` only when you press **Load & keep warm** or
  **Unload** in the cockpit, with the model name you chose from the list it
  returned.

## Reporting

Open an issue at https://github.com/nixfred/burnbar/issues. For anything you
believe is sensitive, say so in the issue without including the sensitive
detail and a private channel will be arranged.
