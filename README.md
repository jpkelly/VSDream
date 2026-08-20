# VSDream — Memory Consolidation for VS Code Native Chat

Your AI agent dreams like you do. Consolidates memory while you sleep — **model-agnostic**.

## Table of Contents

- [Why Model-Agnostic?](#why-model-agnostic)
- [What It Does](#what-it-does)
- [Quick Start](#quick-start)
- [Usage](#usage)
- [How It Compares](#how-it-compares)
- [Configuration](#configuration)
- [Safety](#safety)
- [What's Included](#whats-included)
- [Requirements](#requirements)
- [License](#license)

---

Claude's [Dreams feature](https://platform.claude.com/docs/en/managed-agents/dreams) consolidates memory across sessions — but it's Claude-only. VSDream brings the same idea to VS Code's native chat and works with **any model**: Copilot, Claude, GPT, or whatever's next. It builds on VS Code's own infrastructure, not any model's API.

## Why Model-Agnostic?

Two model-agnostic VS Code features make this possible:

| Feature | What it does | Why it matters |
|---------|-------------|----------------|
| **Cloud session store** (`session_store_sql`) | DuckDB database storing recent sessions across every model — `sessions`, `turns`, `session_files`, `checkpoints`, `events` | Mines turns from Copilot, Claude, and GPT sessions alike |
| **Local session files** (`scan-local-sessions.py`) | Reads `chatSessions` JSONL from every VS Code flavor on disk (Stable, Insiders, Exploration, VSCodium) | A dream started in Insiders still sees Stable's older / unsynced history, and vice versa |
| **Memory tool** (`/memories/`) | Three-scope persistent memory: user (`/memories/`), repo (`/memories/repo/`), session (`/memories/session/`) | Consolidated memory is available to every model in every flavor |

## What It Does

Memory accumulates noise: stale facts, contradictions, relative dates that lose meaning, outdated project references. Dream runs a **4-phase consolidation pass**:

1. **Orient** — Reads current `/memories/` files to understand what exists.
2. **Gather Signal** — Queries the cloud session store **and** local chat JSONL from every VS Code flavor for corrections, preferences, decisions, and recurring patterns. Mines `git log` for repo-scoped dreams.
3. **Consolidate** — Merges findings into memory. Converts relative dates to ISO 8601. Resolves contradictions. Asks every open question with VS Code's native `vscode_askQuestions` picker — never as chat prose. No invented facts. No duplicates.
4. **Prune & Index** — Enforces size limits (200 lines/file). Removes stale pointers. Writes a unified-diff change report.

## Quick Start

**30 seconds to your first dream.**

```bash
git clone https://github.com/jpkelly/VSDream.git /tmp/vsdream
bash /tmp/vsdream/install.sh
```

Then open VS Code chat (any model) and say:

> Run the dream skill. Read SKILL.md and execute all 4 phases.

The dream reads your `/memories/` files, gathers recent signal, and prints a change report. **Every dream is a preview by default — nothing is written until you say so.**

**Review the report, then apply it**: `> Run the dream skill with --apply`

**Target a repo** (optional): `> Run the dream skill with --scope repo --workspace jp-kelly`

Re-running `install.sh` updates in place — skill files overwritten, `.dream-config` preserved. Use `--force` to also reset config to defaults. Use `--uninstall` to remove.

## Usage

### Flags

| Flag | Values | Description |
|------|--------|-------------|
| `--scope` | `user` (default), `repo`, `session` | Which memory scope to write to |
| `--workspace` | `<repo-path>` or `<repo-name>` | Target a specific repo (implies `--scope repo`). Repeatable. |
| `--all` | — | With `--scope repo`, iterate every known repository |
| `--exclude` | `<repo-path>` or `<repo-name>` | Exclude a repo's sessions from scanning. Repeatable. Avoids self-referential noise. |
| `--window` | `1 day`, `7 days`, `30 days`, `90 days`, `1 year`, `all` | How far back to scan |
| `--flavors` | `all` (default), `current`, `stable`, `insiders`, `none` | Which local VS Code installs to scan. Cloud store is always queried. |
| `--apply` | — | Write the changes to memory. **Without this flag every dream is a preview** — dry run is the default, not an option. |
| `--force` | — | Skip the time-since-last-dream check |

### Examples

```text
# Global user memory (default — all repos, cross-workspace)
> Run the dream skill with --scope user

# Current workspace's repo memory
> Run the dream skill with --scope repo

# Specific repo by name; multiple repos in one pass
> Run the dream skill with --scope repo --workspace jp-kelly --workspace VSDream

# All known repositories (each dreamed independently)
> Run the dream skill with --scope repo --all

# Exclude self-referential sessions (run from VSDream workspace)
> Run the dream skill with --scope user --exclude VSDream

# All repos except VSDream
> Run the dream skill with --scope repo --all --exclude VSDream

# Preview (default) with a wider window

# Only scan the currently open VS Code flavor's local chats
> Run the dream skill with --flavors current

# Cloud store only — skip on-disk JSONL
> Run the dream skill with --flavors none
> Run the dream skill with --scope user --window 90 days

# Apply the changes after reviewing the preview
> Run the dream skill with --scope user --apply
```

**Self-referential dreaming:** Running `--scope repo --workspace VSDream` *without* `--exclude` lets the dream consolidate facts about its own development into `/memories/repo/vsdream/`. This is legitimate repo memory — the dream learning about itself is a feature. Use `--exclude VSDream` with `--scope user` so dev sessions don't leak into global preferences.

**Per-repo tracking:** Each repo tracks its own `.last-dream` timestamp, so `--all` skips repos recently dreamed (unless `--force`).

### Automatic trigger

VS Code native chat has no session-end hook. Auto-trigger options:

**VS Code Task** (recommended):

```json
{
  "label": "VSDream: Check & Consolidate",
  "type": "shell",
  "command": "bash $HOME/.copilot/skills/dream/should-dream.sh && echo 'Dream conditions met — run the dream skill in chat' || echo 'Not yet time to dream'"
}
```

**Cron** (background):

```bash
# Check every 6h; should-dream.sh enforces the 24h minimum
0 */6 * * * bash ~/.copilot/skills/dream/should-dream.sh && touch ~/.copilot/.dream-pending
```

Then add to your global instructions (`.instructions.md`):

```markdown
## Auto Dream
If `~/.copilot/.dream-pending` exists at session start, run the dream skill, then delete the flag file.
```

**Shell alias:** `alias dream='bash ~/.copilot/skills/dream/should-dream.sh --force'`

## How It Compares

| Feature | Claude Dreams | dream-skill | **VSDream** |
|---------|--------------|-------------|-------------|
| Models | Claude only | Claude only | **Any model** |
| Session source | Managed Agents | Claude Code JSONL | **Cloud store + local JSONL from every VS Code flavor** |
| Memory target | Claude stores | `~/.claude/` | **`/memories/` (user/repo/session)** |
| Per-repo targeting | No | No | **`--workspace`, `--all`, `--exclude`** |
| Auto-trigger | Dreams API | Stop hook | **Timer / task / cron** |
| Git activity | No | No | **Yes** |
| Change report | No | Summary | **Unified diff** |
| Open questions | No | No | **Native `vscode_askQuestions` picker, never invented** |
| Available now | Behind flag | Yes | **Yes** |

## Configuration

Edit `~/.copilot/skills/dream/.dream-config`:

```ini
DREAM_MEMORY_SCOPE=user      # user, repo, or session
DREAM_WORKSPACES=            # comma-separated repo paths/names (--scope repo)
DREAM_EXCLUDE=               # comma-separated repos to exclude from scanning
DREAM_ALL=false              # true = iterate all known repos (--scope repo)
DREAM_WINDOW=7 days          # 1 day, 7 days, 30 days, 90 days, 1 year, all
DREAM_LOCAL_FLAVORS=all      # all, current, stable, insiders, none
DREAM_INTERVAL_HOURS=24      # min hours between auto-dreams
DREAM_APPLY=false            # true = allow writes; false = always preview
DREAM_MAX_LINES=200          # max lines per memory file
```

Runtime flags always override config values.

## Safety

- **No secrets** — never retains API keys, tokens, `.env` content, or production logs
- **No edits outside memory** — only `/memories/` files are touched
- **No invented facts** — unconfirmed signals are asked with `vscode_askQuestions`, not written as memory. Chat-prose questions are not allowed.
- **No deletion without replacement** — contradicted entries are replaced, not erased
- **Preview by default** — a dream only writes when `--apply` is explicitly passed

## What's Included

| File | Purpose |
|------|---------|
| `SKILL.md` | The 4-phase consolidation skill (loaded by any model / any flavor) |
| `scan-local-sessions.py` | Flavor-agnostic local chat JSONL scanner (Stable + Insiders + Exploration + VSCodium; Cursor opt-in) |
| `should-dream.sh` | Condition checker (24h timer, per-repo timestamps) |
| `install.sh` | Installer — updates in place; `--auto`/`--force`/`--uninstall` |
| `.dream-config.template` | Configuration template |
| `test-dream.sh` | Test harness: fixtures, scanner self-test, skill-text checks |
| `agent-prompt-dream-memory-consolidation.md` | Original Claude Dreams prompt (reference) |

## Requirements

- VS Code or VS Code Insiders with Copilot Chat (native chat)
- Cloud session store enabled (same backend as the `chronicle` skill) — used for recent synced sessions
- Local `chatSessions` JSONL under each flavor's user-data dir — used for older / other-app history
- The `memory` tool available in chat (standard VS Code feature; `/memories/` is shared across flavors)
- The `vscode_askQuestions` tool available in chat — required for every open question (falls back to the report list if missing)
- Python 3 (stdlib only) for `scan-local-sessions.py`
- No model-specific dependencies. Skill lives at `~/.copilot/skills/dream/`, which both Stable and Insiders load.

## License

MIT