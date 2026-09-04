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
   keeps **only numbers**: a timestamp, a token count, a model name, and — for
   Claude — the opaque `message.id` used to deduplicate streamed records.
2. No prompt text, reply text, file content, file path from inside a
   conversation, or project name is extracted, stored, or displayed.
3. Results are bucketed by time and written to
   `~/.local/state/omarchy/burnbar/history.json`.
4. `Service.qml` watches that file; `BarWidget.qml` renders it.

## What leaves your machine

Nothing. Burn Bar makes no network requests of any kind. It has no telemetry,
no update check, and no remote endpoint. Everything it reads and everything it
writes stays on the local filesystem.

## Files it writes

| Path | Contents |
|---|---|
| `~/.local/state/omarchy/burnbar/history.json` | Bucketed token totals and plan-limit percentages |
| `~/.local/state/omarchy/burnbar/scan-cache.json` | Per-file size/mtime/offset plus the extracted numeric points, so unchanged files are not re-read |

`scan-cache.json` keys on absolute transcript paths, which include your project
directory names. It is written with your account's default permissions under
your own state directory and is never transmitted.

Burn Bar writes nothing inside its own plugin directory, and modifies no
Omarchy, Hyprland, or application configuration.

## Processes it runs

Exactly one: `python3 <plugin dir>/bin/burnbar-collect`, as your user, on a
timer. It takes no input from the network and no input from the widget beyond
two integers (window length and bucket count) that are clamped to fixed ranges
before use. A run that exceeds 30 seconds is killed by a watchdog.

## Reporting

Open an issue at https://github.com/nixfred/burnbar/issues. For anything you
believe is sensitive, say so in the issue without including the sensitive
detail and a private channel will be arranged.
