# VSDream — Memory Consolidation for VS Code Native Chat

Your AI agent dreams like you do. Consolidates memory while you sleep — **model-agnostic**.

Claude has its [Dreams feature](https://platform.claude.com/docs/en/managed-agents/dreams) for memory consolidation. VSDream brings the same idea to VS Code's native chat, but works with **any model** — Copilot, Claude, GPT, or whatever's next — because it builds on VS Code's own infrastructure, not any model's API.

## Why Model-Agnostic?

Claude's Dreams API is Claude-only: it reads Claude's Managed Agent sessions and writes to Claude's memory stores. If you switch between models in VS Code chat (Copilot for one task, Claude for another), your memories from the Claude session are invisible to Copilot and vice versa.

VSDream solves this by using two **model-agnostic** VS Code features:

| Feature | What it does | Why it matters |
|---------|-------------|----------------|
| **Cloud session store** (`session_store_sql`) | A DuckDB database storing ALL past sessions across every model — `sessions`, `turns`, `session_files`, `checkpoints`, `events` | The dream can mine turns from Copilot, Claude, and GPT sessions alike |
| **Memory tool** (`/memories/`) | Three-scope persistent memory: user (`/memories/`), repo (`/memories/repo/`), session (`/memories/session/`) | Consolidated memory is available to every model in future sessions |

The same dream works whether yesterday's session was Copilot, last week's was Claude, or last month's was GPT.

## What It Does

Memory accumulates noise across sessions: stale facts, contradictions, relative dates that lose meaning, outdated project references. Dream runs a **4-phase consolidation pass** — the same way your brain consolidates memories during sleep.

- **Phase 1 — Orient:** Reads your current `/memories/` files to understand what exists.
- **Phase 2 — Gather Signal:** Queries the cloud session store for user corrections, preference changes, important decisions, and recurring patterns across all models. Also mines `git log` for repo-scoped dreams.
- **Phase 3 — Consolidate:** Merges new findings into existing memory. Converts relative dates to absolute (ISO 8601). Resolves contradictions. Reports open questions instead of inventing facts. No duplicates.
- **Phase 4 — Prune & Index:** Enforces size limits (200 lines/file). Removes stale pointers. Demotes verbose entries to topic files. Writes a unified-diff change report.

## Quick Start

**30 seconds to your first dream.**

### 1. Install

```bash
git clone https://github.com/jp/VSDream.git /tmp/vsdream
bash /tmp/vsdream/install.sh
```

This copies `SKILL.md` and `should-dream.sh` to `~/.vscode/skills/dream/` and creates a default `.dream-config`.

### 2. Run your first dream

Open VS Code chat (any model) and say:

> Run the dream skill. Read SKILL.md and execute all 4 phases.

That's it. The dream will:
1. Read your current `/memories/` files
2. Query the cloud session store for recent corrections, preferences, and decisions
3. Merge findings into memory, resolving contradictions
4. Print a unified-diff change report

### 3. Try a dry run first (optional)

Not sure what it'll change? Preview without writing:

> Run the dream skill with --dry-run

### 4. Target a specific repo (optional)

By default the dream consolidates **user memory** (cross-workspace preferences). To consolidate a specific repo's memory instead:

> Run the dream skill with --scope repo --workspace jp-kelly

Or dream **all** known repositories at once:

> Run the dream skill with --scope repo --all

See [Usage](#usage) below for the full flag reference.

---

### Other install options

<details>
<summary>Manual install</summary>

1. Copy `SKILL.md` and `should-dream.sh` to `~/.vscode/skills/dream/`
2. Run `chmod +x ~/.vscode/skills/dream/should-dream.sh`
3. Copy `.dream-config.template` to `~/.vscode/skills/dream/.dream-config`
4. Start a VS Code chat session and say: "Run the dream skill."

</details>

<details>
<summary>Install with auto-trigger</summary>

```bash
bash /tmp/vsdream/install.sh --auto    # Install + auto-trigger guidance
bash /tmp/vsdream/install.sh --force   # Overwrite existing install
```

</details>

## Usage

### Manual

Tell VS Code chat:

> Run the dream skill. Read SKILL.md and execute all 4 phases.

### Targeting scopes and workspaces

VSDream supports flags that control which memory to consolidate and which sessions to scan:

| Flag | Values | Description |
|------|--------|-------------|
| `--scope` | `user` (default), `repo`, `session` | Which memory scope to write to |
| `--workspace` | `<repo-path>` or `<repo-name>` | Target a specific repo's memory (implies `--scope repo`). Can be repeated. |
| `--all` | — | With `--scope repo`, iterate every known repository |
| `--exclude` | `<repo-path>` or `<repo-name>` | Exclude a repo's sessions from scanning. Can be repeated. Avoids self-referential noise. |
| `--window` | `1 day`, `7 days`, `30 days`, `90 days`, `all` | How far back to scan |
| `--dry-run` | — | Preview changes without writing |
| `--force` | — | Skip the time-since-last-dream check |

Examples:

```text
# Consolidate global user memory (default — all repos, cross-workspace)
> Run the dream skill with --scope user

# Consolidate the current workspace's repo memory
> Run the dream skill with --scope repo

# Consolidate a specific repo's memory by name
> Run the dream skill with --scope repo --workspace jp-kelly

# Consolidate multiple repos in one dream
> Run the dream skill with --scope repo --workspace jp-kelly --workspace VSDream

# Dream all known repositories (each gets its own consolidation pass)
> Run the dream skill with --scope repo --all

# Preview without writing
> Run the dream skill with --dry-run --scope repo --workspace jp-kelly

# Scan a wider window of session history
> Run the dream skill with --scope user --window 90 days

# Exclude self-referential sessions (run from VSDream workspace)
> Run the dream skill with --scope user --exclude VSDream

# Dream all repos except VSDream (skip the meta-noise)
> Run the dream skill with --scope repo --all --exclude VSDream
```

**Self-referential dreaming:** If you run `--scope repo --workspace VSDream` *without* `--exclude`, the dream will consolidate facts about its own development into `/memories/repo/vsdream/` — its design decisions, flag conventions, safety rules. This is legitimate repo memory and harmless. The dream learning about itself is a feature, not a bug. Just use `--exclude VSDream` when running `--scope user` so those dev sessions don't leak into your global preferences.

**Per-repo tracking:** Each repository tracks its own `.last-dream` timestamp, so `--all` won't re-consolidate a repo that was just dreamed (unless `--force`).

### Automatic

VS Code native chat doesn't have a session-end hook like Claude Code's `Stop` hook. Auto-trigger requires one of:

**Option A — VS Code Task** (recommended, runs inside VS Code):

Create a `.vscode/tasks.json` entry:

```json
{
  "label": "VSDream: Check & Consolidate",
  "type": "shell",
  "command": "bash $HOME/.vscode/skills/dream/should-dream.sh && echo 'Dream conditions met — run the dream skill in chat' || echo 'Not yet time to dream'",
  "group": "none",
  "isBackground": false
}
```

Run it periodically or bind it to a keyboard shortcut.

**Option B — Cron** (background, no VS Code needed):

```bash
# Check every 6 hours; should-dream.sh enforces the 24h minimum
crontab -e
# Add: 0 */6 * * * bash ~/.vscode/skills/dream/should-dream.sh && touch ~/.vscode/.dream-pending
```

Then add to your global instructions (`.instructions.md`):

```markdown
## Auto Dream
If the file `~/.vscode/.dream-pending` exists at session start, run the dream skill, then delete the flag file.
```

**Option C — Shell alias:**

```bash
alias dream='bash ~/.vscode/skills/dream/should-dream.sh --force && echo "Flagged for dream — start a chat and say: run the dream skill"'
```

## What's Included

| File | Purpose |
|------|---------|
| `SKILL.md` | The 4-phase consolidation skill prompt (loaded by any model) |
| `should-dream.sh` | Condition checker (24h timer) |
| `install.sh` | One-command installer with `--auto` and `--force` flags |
| `.dream-config.template` | Configuration template |
| `test-dream.sh` | Test harness: creates fixtures, verifies consolidation |
| `agent-prompt-dream-memory-consolidation.md` | The original Claude Dreams prompt (reference) |

## How It Compares

| Feature | Claude Dreams (API) | dream-skill (Claude Code) | **VSDream** |
|---------|---------------------|--------------------------|-------------|
| Models | Claude only | Claude only | **Any model** |
| Session source | Claude Managed Agents | Claude Code JSONL files | **VS Code cloud session store (all models)** |
| Memory target | Claude memory stores | `~/.claude/` memory | **VS Code `/memories/` (user/repo/session)** |
| Per-repo targeting | No | No | **Yes (`--workspace`, `--all`)** |
| Auto-trigger | Dreams API (async) | Stop hook + flag file | **Timer + VS Code task / cron / alias** |
| Git activity | No | No | **Yes (repo-scoped dreams)** |
| Change report | No | Summary only | **Unified diff + change report** |
| Open questions | No | No | **Reported, never invented** |
| Available now | Behind feature flag | Yes | **Yes** |

## Configuration

Edit `~/.vscode/skills/dream/.dream-config`:

```ini
DREAM_MEMORY_SCOPE=user      # user, repo, or session
DREAM_WORKSPACES=            # comma-separated repo paths/names for --scope repo
DREAM_EXCLUDE=               # comma-separated repos to exclude from scanning
DREAM_ALL=false              # true = iterate all known repos for --scope repo
DREAM_WINDOW=7 days          # 1 day, 7 days, 30 days, 90 days, all
DREAM_INTERVAL_HOURS=24      # min hours between auto-dreams
DREAM_DRY_RUN=false          # true = preview only, no writes
DREAM_MAX_LINES=200          # max lines per memory file
```

Runtime flags (`--scope`, `--workspace`, `--exclude`, `--all`, `--window`, `--dry-run`, `--force`) always override config file values.

## Requirements

- VS Code with Copilot Chat (native chat)
- Cloud session store enabled (used by the `chronicle` skill — same backend)
- The `memory` tool available in chat (standard VS Code feature)
- No model-specific dependencies — works with whatever model you're using

## Safety

- **Never retains secrets** — no API keys, tokens, `.env` content, or production logs
- **Never edits outside memory** — only `/memories/` files are touched
- **Never invents facts** — unconfirmed signals become open questions, not memory entries
- **Never deletes without replacement** — contradicted entries are replaced, not erased
- **Dry run available** — `--dry-run` previews all changes before writing
- **Backup before first run** — read all memory files before the first consolidation

## License

MIT