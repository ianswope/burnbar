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
   keeps: a timestamp, token counts split into input, cache write, output and
   cache read, the model name, and — for Claude — the opaque `message.id`
   used to deduplicate streamed records.
2. No prompt text, reply text, or file content from inside a conversation is
   extracted, stored, or displayed. The scan cache does key on the absolute
   transcript path, and Claude's transcript paths include the project
   directory name (see "Files it writes").
3. Results are bucketed by time and written to
   `~/.local/state/omarchy/burnbar/history.json`.
4. `Service.qml` watches that file; `BarWidget.qml` and `BurnPanel.qml` render it.

## What leaves your machine

Burn Bar has no telemetry, no update check, and no remote endpoint of its
own. One thing generates network traffic, and you should know about it:

**Omarchy's usage collectors, which Burn Bar triggers.** Every
`limitsRefreshSec` seconds (default 300), on panel open and on refresh,
Burn Bar runs `omarchy-agent-usage-update --limits-only claude codex`.
That is Omarchy's own command, the same one the stock agents panel runs.
Its Claude collector contacts **Anthropic's OAuth usage endpoint** with the
sign-in Claude Code already saved on this machine; its Codex collector asks
the Codex app-server over a local pipe (which may itself talk to OpenAI).
Burn Bar never reads, holds or sends either credential. If you do not want
this traffic, do not install Burn Bar — there is no setting that disables
it, because without it the plan limits it shows would be hours stale.

Nothing else.

## Files it writes

| Path | Contents |
|---|---|
| `~/.local/state/omarchy/burnbar/history.json` | Bucketed token totals, per-agent splits, model names, and plan-limit percentages |
| `~/.local/state/omarchy/burnbar/scan-cache.json` | Per transcript file: size, mtime, byte offset, a 48-byte fingerprint of the bytes before that offset, the extracted numeric points (timestamp, counts, model name, Claude `message.id`), and for Codex the last cumulative counter |
| `~/.local/state/omarchy/burnbar/collect.lock` | Empty; held while a collector runs so two never race |

`scan-cache.json` keys on absolute transcript paths, which include your project
directory names. It is written with your account's default permissions under
your own state directory and is never transmitted.

Burn Bar writes nothing inside its own plugin directory, and modifies no
Omarchy, Hyprland, or application configuration.

## Processes it runs

One script of its own, `python3`, as your user, from the plugin's own `bin/`
directory — plus one Omarchy command:

- `omarchy-agent-usage-update --limits-only claude codex`, every
  `limitsRefreshSec` seconds (default 300), on panel open, and on refresh.
  This is Omarchy's own collector, not Burn Bar's. It is what the stock agents
  panel runs, and it is the only thing that produces the plan-limit records
  Burn Bar reads. Its Claude collector contacts Anthropic's OAuth usage
  endpoint with the sign-in Claude Code already saved, and its Codex collector
  asks the Codex app-server over a local pipe. Burn Bar never reads, holds or
  sends either credential itself; if the command is not present the limits
  simply show their age. It is launched through `bash -c` under `setsid` so
  that the 60-second watchdog can terminate the whole process group, not just
  the wrapper. Burn Bar also reads (never writes) the collector's probe cache
  at `~/.cache/omarchy/agent-usage/claude-limits.json` for the time of the
  last successful measurement.

Burn Bar's own script:

- `burnbar-collect` on the refresh timer. It takes no input from the network
  and no input from the widget beyond two integers — window length and bucket
  count — clamped to fixed ranges. It starts no other process. A run that
  exceeds 30 seconds is killed by a watchdog.

## Reporting

Open an issue at https://github.com/nixfred/burnbar/issues. For anything you
believe is sensitive, say so in the issue without including the sensitive
detail and a private channel will be arranged.
