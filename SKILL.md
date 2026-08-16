---
name: dream
description: "Model-agnostic memory consolidation skill for VS Code native chat. Scans all past sessions across models (Copilot, Claude, GPT, etc.) via the cloud session store, extracts corrections, decisions, preferences, and recurring patterns, then merges findings into persistent VS Code memory files (/memories/). Auto-triggers via a 24-hour timer. Inspired by Claude's Dreams feature and how sleep consolidates human memory."
tags: [memory, maintenance, consolidation, autonomous, cross-model]
---

# Dream — Memory Consolidation for VS Code Native Chat

> Your AI agent dreams like you do. Consolidates memory while you sleep.
> **Model-agnostic:** works with Copilot, Claude, GPT, or any model running in VS Code chat.

---

## What This Does

Across many chat sessions — possibly with different models — your memory accumulates noise: stale facts, contradictions, relative dates that lose meaning, outdated project references. Dream fixes this by running a **4-phase consolidation pass** over your memory files, the same way your brain consolidates memories during sleep.

The key difference from Claude's Dreams API: this version is **completely model-agnostic**. It uses VS Code's built-in infrastructure:

| Concern | Claude Dreams (original) | VSDream (this skill) |
|---------|--------------------------|----------------------|
| Model | Claude only | Any model in VS Code chat |
| Session history | Claude's Managed Agent sessions | VS Code cloud session store (all models) |
| Memory store | Claude memory stores (`/mnt/memory/`) | VS Code `/memories/` (user, session, repo scopes) |
| Trigger | Dreams API (async job) | Manual or 24h auto-timer |
| Query method | `client.beta.dreams.create()` | `session_store_sql` (DuckDB queries) |
| Output | New separate memory store | Updated `/memories/` files in-place |

Because it relies on VS Code's tooling — not any model's API — the same dream works whether you ran yesterday's session with Copilot, last week's with Claude, or last month's with GPT.

---

## How It Works

Dream runs in **4 sequential phases**. Execute them in order. Do not skip phases.

```
ORIENT → GATHER SIGNAL → CONSOLIDATE → PRUNE & INDEX
```

### Flags — targeting scopes and workspaces

The dream accepts flags that control **what memory to consolidate** and **which sessions to scan**. These can be passed in the user's message or set in `.dream-config`.

| Flag | Values | Description |
|------|--------|-------------|
| `--scope` | `user` (default), `repo`, `session` | Which memory scope to write to |
| `--workspace` | `<repo-path>` or `<repo-name>` | Target a specific repository's memory (implies `--scope repo`). Can be repeated for multiple repos. |
| `--all` | (no value) | Consolidate across ALL known repositories. With `--scope repo`, iterates every repo that has memory or recent sessions. |
| `--window` | `1 day`, `7 days`, `30 days`, `90 days`, `all` | How far back to scan sessions (overrides config) |
| `--dry-run` | (no value) | Preview changes without writing to memory |
| `--force` | (no value) | Skip the time-since-last-dream check |

#### Scope details

- **`--scope user`** (default) — Consolidates `/memories/` (persistent, cross-workspace). Scans sessions from ALL repositories. This is for your global preferences, workflow patterns, and tool preferences.

- **`--scope repo`** — Consolidates `/memories/repo/` for one or more repositories. By default targets the **current workspace**. Use `--workspace` to target a different repo, or `--all` to iterate every known repo. This is for project-specific conventions, build commands, and architecture facts.

- **`--scope session`** — Consolidates `/memories/session/` for the current conversation only. Rarely useful — session memory is ephemeral.

#### Workspace targeting

When `--scope repo` is active:

- **No `--workspace` flag**: targets the current workspace (the repo you're in now)
- **`--workspace /Users/jp/Documents/GitHub/jp-kelly`**: targets that specific repo
- **`--workspace jp-kelly --workspace VSDream`**: targets multiple named repos in one dream
- **`--all`**: discovers all repositories from the session store and iterates each, consolidating its repo memory independently

#### Per-repo last-dream tracking

Each repository tracks its own `.last-dream` timestamp so that `--all` doesn't re-consolidate a repo that was just dreamed. The timestamp is stored at `/memories/repo/<repo-slug>/.last-dream`.

### Auto-trigger flow

```
Session ends or you run /dream
  → should-dream.sh checks: 24hrs passed since last dream?
  → If NO: exits silently, zero overhead
  → If YES (or manual run): dream begins
  → Phase 1: Orient — read current /memories/ state
  → Phase 2: Gather — query session store for recent signal
  → Phase 3: Consolidate — merge findings into memory files
  → Phase 4: Prune & Index — rebuild lean index, enforce size limits
  → Write .last-dream timestamp
  → Timer resets for next 24hrs
```

---

## Phase 1: ORIENT

**Goal:** Understand the current state of memory before changing anything.

### Step 0: Parse flags and config

First, parse the flags from the user's invocation message. Look for:

- `--scope <user|repo|session>` — overrides `DREAM_MEMORY_SCOPE` config
- `--workspace <path-or-name>` — target a specific repo (can appear multiple times). Implies `--scope repo`.
- `--all` — consolidate across all known repositories
- `--window <interval>` — overrides `DREAM_WINDOW` config
- `--dry-run` — overrides `DREAM_DRY_RUN` config
- `--force` — skip the last-dream time check

Then read the config file for defaults:

```bash
cat ~/.vscode/skills/dream/.dream-config 2>/dev/null || echo "DREAM_MEMORY_SCOPE=user"
```

**Determine the target scope and path:**

| Flag combo | Scope | Memory path | Sessions scanned |
|------------|-------|-------------|------------------|
| `--scope user` or no flag | `user` | `/memories/` | All repositories |
| `--scope repo` (no `--workspace`) | `repo` | `/memories/repo/` (current workspace) | Current workspace only |
| `--scope repo --workspace /path/to/repo` | `repo` | `/memories/repo/<repo-slug>/` | That repo only |
| `--scope repo --workspace A --workspace B` | `repo` | Two paths, dreamed sequentially | Each repo independently |
| `--scope repo --all` | `repo` | All repos that have memory or recent sessions | Each repo independently |
| `--scope session` | `session` | `/memories/session/` | Current session only |

**Repo slug derivation:** Convert a repo path or name to a slug by taking the last path component and lowercasing. E.g. `/Users/jp/Documents/GitHub/jp-kelly` → `jp-kelly`. If two repos have the same name, use the full path as the slug instead.

**If `--all` is set**, discover all known repositories from the session store:

```sql
SELECT DISTINCT repository, cwd
FROM sessions
WHERE repository IS NOT NULL
ORDER BY repository;
```

Then iterate Phase 1–4 for each repo that has memory or recent sessions, skipping repos whose `.last-dream` is within `DREAM_INTERVAL_HOURS` (unless `--force`).

### Step 1: Read current memory state

Based on the determined scope, read the appropriate memory directory:

**For `--scope user`:**

```
memory(view, "/memories/")
```

Then view each file:

```
memory(view, "/memories/debugging.md")
memory(view, "/memories/patterns.md")
memory(view, "/memories/workflow-jp-kelly.md")
```

**For `--scope repo` (single workspace):**

```
memory(view, "/memories/repo/")
```

If targeting a specific workspace, use its slug path:

```
memory(view, "/memories/repo/<repo-slug>/")
```

**For `--scope repo --all`:**

List the repo memory directory to see which repos already have memory:

```
memory(view, "/memories/repo/")
```

Then for each repo discovered in Step 0, read its memory files.

**For `--scope session`:**

```
memory(view, "/memories/session/")
```

Note for whichever scope you're reading:
- How many memory files exist and what topics they cover
- Total size — are any files bloated?
- Last modified dates (if visible)
- Any entries that look stale (relative dates like "yesterday", "last week" with no anchor)
- Any contradictions between files
- Any references to files/projects that may no longer exist

### Output of this phase

You should now have a mental map of:
- What topics are covered in memory
- How large the memory files are
- What's potentially stale or contradictory
- What scope you're consolidating (`user`, `repo`, or `session`)
- If `--all`: the full list of repos to iterate

---

## Phase 2: GATHER SIGNAL

**Goal:** Extract important information from recent sessions without reading everything. This is the model-agnostic phase — it queries the cloud session store that captures ALL past sessions regardless of which model ran them.

### Source: Cloud Session Store

VS Code's session store is a DuckDB database with tables: `sessions`, `turns`, `session_files`, `session_refs`, `checkpoints`, `events`, `tool_requests`. Use `session_store_sql` (read-only SELECT/WITH queries only).

### Step 1: Get the lay of the land

```sql
-- How many recent sessions exist?
SELECT COUNT(*) as total_sessions,
       MIN(created_at) as earliest,
       MAX(created_at) as latest
FROM sessions;
```

```sql
-- What agents/models have been used?
SELECT agent_name, COUNT(*) as session_count
FROM sessions
GROUP BY agent_name
ORDER BY session_count DESC;
```

### Step 2: Scan recent turns for signal patterns

**If `--scope repo` or `--workspace` is set**, filter all queries to the target repository:

```sql
-- Find the repo_id or repository name for the target workspace
SELECT DISTINCT repository, cwd, repo_id
FROM sessions
WHERE repository = '<repo-name>'
   OR cwd = '<repo-path>'
LIMIT 1;
```

Then add `AND s.repository = '<repo-name>'` (or `AND s.repo_id = <id>`) to every signal query below.

**If `--scope user` (default)**, scan across ALL repositories — no repo filter.

Use targeted SQL — not full reads. Each query targets a specific signal type.

**User corrections** (highest priority):

```sql
SELECT s.created_at, s.repository, t.user_message
FROM turns t
JOIN sessions s ON t.session_id = s.id
WHERE t.user_message ILIKE '%actually%'
   OR t.user_message ILIKE '%no,%'
   OR t.user_message ILIKE '%wrong%'
   OR t.user_message ILIKE '%incorrect%'
   OR t.user_message ILIKE '%not right%'
   OR t.user_message ILIKE '%stop doing%'
   OR t.user_message ILIKE '%don''t do%'
   OR t.user_message ILIKE '%I meant%'
   OR t.user_message ILIKE '%that''s not%'
   OR t.user_message ILIKE '%correction%'
ORDER BY s.created_at DESC
LIMIT 50;
```

**Preferences and configuration:**

```sql
SELECT s.created_at, s.repository, t.user_message
FROM turns t
JOIN sessions s ON t.session_id = s.id
WHERE t.user_message ILIKE '%I prefer%'
   OR t.user_message ILIKE '%always use%'
   OR t.user_message ILIKE '%never use%'
   OR t.user_message ILIKE '%I like%'
   OR t.user_message ILIKE '%I don''t like%'
   OR t.user_message ILIKE '%from now on%'
   OR t.user_message ILIKE '%going forward%'
   OR t.user_message ILIKE '%remember that%'
   OR t.user_message ILIKE '%keep in mind%'
   OR t.user_message ILIKE '%make sure to%'
   OR t.user_message ILIKE '%default to%'
ORDER BY s.created_at DESC
LIMIT 50;
```

**Important decisions:**

```sql
SELECT s.created_at, s.repository, t.user_message
FROM turns t
JOIN sessions s ON t.session_id = s.id
WHERE t.user_message ILIKE '%let''s go with%'
   OR t.user_message ILIKE '%I decided%'
   OR t.user_message ILIKE '%we''re using%'
   OR t.user_message ILIKE '%the plan is%'
   OR t.user_message ILIKE '%switch to%'
   OR t.user_message ILIKE '%move to%'
   OR t.user_message ILIKE '%chosen%'
   OR t.user_message ILIKE '%we agreed%'
ORDER BY s.created_at DESC
LIMIT 50;
```

**Recurring patterns (frustration signals):**

```sql
SELECT s.created_at, s.repository, t.user_message
FROM turns t
JOIN sessions s ON t.session_id = s.id
WHERE t.user_message ILIKE '%again%'
   OR t.user_message ILIKE '%every time%'
   OR t.user_message ILIKE '%keep forgetting%'
   OR t.user_message ILIKE '%as usual%'
   OR t.user_message ILIKE '%same as before%'
   OR t.user_message ILIKE '%we always%'
   OR t.user_message ILIKE '%the usual%'
ORDER BY s.created_at DESC
LIMIT 50;
```

### Step 3: Check session files for context

```sql
-- What files were touched in recent sessions?
SELECT s.created_at, s.repository, sf.file_path, sf.event_type
FROM session_files sf
JOIN sessions s ON sf.session_id = s.session_id
WHERE s.created_at > now() - INTERVAL '7 days'
ORDER BY s.created_at DESC
LIMIT 50;
```

### Step 4: Check checkpoints for work summaries

```sql
-- Recent checkpoint summaries show what was accomplished
SELECT s.created_at, s.repository, c.title, c.work_done, c.next_steps
FROM checkpoints c
JOIN sessions s ON c.session_id = s.session_id
WHERE s.created_at > now() - INTERVAL '7 days'
ORDER BY s.created_at DESC
LIMIT 20;
```

### Step 5: Gather git activity (repo-scoped dreams only)

When consolidating repo memory (`DREAM_MEMORY_SCOPE=repo`), also mine git for durable signals — architecture decisions, dependency changes, and patterns that are evident in the codebase but may not have been explicitly stated in any session.

```bash
# Recent commit messages show decisions and direction
git log --oneline --since="$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)" 2>/dev/null | head -30

# Files changed recently show where work is happening
git diff --stat HEAD~20 HEAD 2>/dev/null | tail -20

# Check for dependency changes
git log --oneline --all -- package.json requirements.txt Cargo.toml go.mod pom.xml 2>/dev/null | head -10
```

Look for:
- **Decisions encoded in commits** — "switch to pnpm", "migrate to PostgreSQL", "refactor auth to JWT"
- **Patterns** — consistent commit message style, testing conventions, branching strategy
- **Active areas** — which files/directories are being actively worked on
- **Drift detection** — does the codebase contradict anything in current memory?

Only extract things that are **durable and evidence-backed**. A single WIP commit is not evidence; a merged pattern across multiple commits is.

### What to extract

For each finding, note:
- **The fact** — What was said or decided
- **The date** — Use the `created_at` timestamp from the session (ISO 8601: YYYY-MM-DD)
- **The repository** — Which project this applies to (from `s.repository`)
- **Confidence** — Was it an explicit instruction (high) or implied preference (medium)?
- **Contradictions** — Does this conflict with anything currently in memory?
- **Evidence** — What backs this up? (session turn, git commit, checkpoint summary)

### Report open questions — never invent facts

If something looks important but you can't confirm it from the evidence, **do not guess**. Instead, collect it as an open question for Phase 3:

```
OPEN QUESTIONS:
- Is the user still using pnpm, or have they switched? (saw a reference to yarn in a 30-day-old session)
- What is the deploy target for the new project? (no sessions mention it yet)
```

Open questions are reported in the final summary but never written to memory as facts.

### Adjustable time window

All queries above use the full history. To focus on recent signal, add:

```sql
WHERE s.created_at > now() - INTERVAL '7 days'
```

Adjust the interval (`'1 day'`, `'30 days'`, etc.) based on dream frequency. The default should match your `DREAM_WINDOW` config (default: `7 days`).

---

## Phase 3: CONSOLIDATE

**Goal:** Merge new findings into existing memory. This is the most delicate phase.

### Rules

1. **Never duplicate.** Before adding anything, check if it already exists in memory. If it does, update the existing entry rather than creating a new one.

2. **Convert relative dates to absolute (ISO 8601).** If a session from 2026-08-10 says "yesterday I changed the API key", write "2026-08-09: Changed API key" in memory. Never store "yesterday" or "last week" — they lose meaning immediately. All dates in memory must be absolute, parseable dates.

3. **Delete contradicted facts.** If memory says "Prefers tabs" but a recent session has the user saying "Use spaces", remove the old entry and write the new one. Add a note: `(Updated YYYY-MM-DD, previously: tabs)`. Retain the newer, better-supported fact; remove the outdated claim.

4. **Preserve source attribution.** When adding a new memory entry, note where it came from: `(source: session YYYY-MM-DD, repo: <name>)`.

5. **Report open questions, don't invent.** If you suspect something is worth remembering but can't confirm it from evidence, add it to the open-questions list in the final report. Never write an unconfirmed guess to memory as if it were a fact.

6. **Scope awareness.** Write to the appropriate memory scope:
   - **User memory** (`/memories/`) — Cross-workspace preferences, workflow patterns, tool preferences
   - **Repo memory** (`/memories/repo/`) — Project-specific conventions, build commands, architecture facts
   - **Session memory** (`/memories/session/`) — Never consolidate here (session memory is ephemeral)

7. **Topic file organization.** Group related memories into topic files:
   - `preferences.md` — How the user likes things done
   - `decisions.md` — Choices and their rationale
   - `corrections.md` — Past mistakes to avoid repeating
   - `patterns.md` — Recurring workflows, common tasks
   - `facts.md` — Project-specific knowledge, architecture notes
   - Create new topic files only when existing ones don't fit

8. **Entry format.** Each memory entry should be concise:
   ```markdown
   - [YYYY-MM-DD] The fact or preference. (source: session, repo: <name>, confidence: high/medium)
   ```

9. **Brevity.** Memory files are loaded into context automatically. Keep entries to single lines where possible. Use bullet points, not paragraphs.

### How to write

Use the `memory` tool:
- `memory(create, "/memories/<topic>.md", file_text)` — to create a new topic file
- `memory(str_replace, "/memories/<topic>.md", old_str, new_str)` — to update existing entries
- `memory(view, "/memories/<topic>.md")` — always read before editing

**Always read a file before editing it.**

### Keep INDEX short and navigational

If an index file exists (e.g., `/memories/INDEX.md`), keep it as a **navigational** pointer — one line per topic file with a brief hook. Never write memory content into the index. The index exists so future sessions can orient quickly; the topic files hold the actual knowledge.

```markdown
# Memory Index
Last consolidated: 2026-08-15

| File | Summary | Updated |
|------|---------|---------|
| preferences.md | Editor, formatting, communication style | 2026-08-14 |
| decisions.md | Architecture choices, tool selections | 2026-08-13 |
| corrections.md | Past mistakes to avoid repeating | 2026-08-12 |
| patterns.md | Common workflows, recurring tasks | 2026-08-10 |
| facts.md | Project knowledge, architecture notes | 2026-08-08 |
```

### Safety: backup before first run

On the very first dream against a scope, back up existing memory:

```
memory(view, "/memories/")
```

Then manually copy the content of each file to a backup location before proceeding. Alternatively, use the `--dry-run` flag (see Safety section below) on first use.

---

## Phase 4: PRUNE & INDEX

**Goal:** Keep memory lean and well-organized. Remove stale content. Enforce size limits.

### Prune stale entries

Remove or archive entries that are:
- More than 90 days old with no references in recent sessions
- Contradicted by newer entries (should have been caught in Phase 3)
- About projects/repos that no longer exist in the session store

To check if a repo is still active:

```sql
SELECT MAX(created_at) as last_active
FROM sessions
WHERE repository = '<repo-name>';
```

If `last_active` is more than 90 days ago, demote its memory entries to an `archive.md` topic file rather than deleting them outright.

### Size limits

- Each memory file should be under **200 lines**
- The first 200 lines of `/memories/` files are loaded into context automatically — keep the most important facts near the top
- If a file exceeds 200 lines:
  1. Move older/less-critical entries to a sub-topic or archive file
  2. Compress verbose entries into one-liners
  3. Split oversized files by sub-topic if needed

### Organize by priority

Within each file, order entries:
1. **Always-relevant facts** (preferences, core patterns) — top
2. **Project-specific facts** — middle
3. **Historical/once-relevant facts** — bottom or archive

### Record the dream timestamp

After completing all 4 phases, write the timestamp so the auto-trigger knows when you last dreamed. The location depends on scope:

**For `--scope user`:**

```bash
date +%s > ~/.vscode/skills/dream/.last-dream
```

**For `--scope repo` (single workspace):**

Write to the repo's own memory directory so `--all` can skip repos that were recently dreamed:

```
memory(create, "/memories/repo/<repo-slug>/.last-dream", "$(date +%s)")
```

If the file already exists, use `str_replace` to update it. If `--all`, write a timestamp for each repo after dreaming it.

**For `--scope session`:**

Session memory is ephemeral — no timestamp needed.

Also write a global dream log entry (always, for all scopes):

```bash
mkdir -p ~/.vscode/skills/dream/logs
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | scope: <scope> | workspace: <repo-or-all> | sessions_scanned: <N> | entries_added: <N> | entries_updated: <N> | entries_archived: <N> | contradictions_resolved: <N>" >> ~/.vscode/skills/dream/logs/dream.log
```

---

## Safety

### Hard constraints (never violate)

- **Never retain secrets.** No API keys, passwords, tokens, `.env` content, customer data, or raw production logs. If a session discusses credentials, note only that "credentials were configured" — never the values.

- **Never edit outside memory.** Do not modify code, infrastructure, dependencies, configuration, or any file outside the `/memories/` scope you're consolidating. The dream touches memory files only.

- **Never invent facts.** If you can't confirm something from evidence, report it as an open question in the summary — do not write it to memory as a fact.

- **Never delete memory without replacement.** If removing an entry, either it was contradicted (replaced by a newer entry) or it was moved (to a topic file or archive). Never just delete.

### Soft guidelines

- **Dry run option.** On first use or when uncertain, run Phases 1–2 and only **print** what you WOULD change in Phase 3, without writing. Confirm with the user before applying. Use the `--dry-run` argument to enable this mode.

- **Cross-model safety.** The session store contains turns from all models. When consolidating, note which model was used if it's relevant (some models may have different conventions or capabilities that affected the conversation).

- **Evidence-backed only.** Extract only durable, evidence-backed knowledge useful in future work. A one-off comment in a debug session is not durable. A repeated correction across three sessions is.

- **Prefer updating over creating.** Update existing memory files rather than duplicating information into new files.

---

## Verification & Output

After running, verify the consolidation:

1. Use `memory(view, "/memories/")` to list all files
2. Check that no topic file has duplicate entries
3. Confirm no relative dates remain ("yesterday", "last week", etc.)
4. Verify all entries have absolute (ISO 8601) dates
5. Produce a structured change report

### Change report format

Return a **unified-diff-style** summary of what you consolidated, followed by a concise change report. This makes the dream reviewable — you can see exactly what was added, updated, and removed.

```text
=== Dream Change Report ===
Date: 2026-08-15T14:32:00Z
Scope: user
Window: 7 days
Sessions scanned: 37
Models: copilot (22), claude (15)

--- /memories/preferences.md
+++ /memories/preferences.md
@@ -12,3 +12,4 @@
 - [2026-08-10] Prefers tabs for indentation
+- [2026-08-14] Prefers 2-space indentation (Updated, previously: tabs) (source: session, repo: VSDream)
 - [2026-08-08] Always use semicolons in JavaScript

--- /memories/decisions.md
+++ /memories/decisions.md
@@ -5,3 +5,1 @@
-- [2026-07-30] Default branch is "develop"
+- [2026-08-13] Default branch is "main" (Updated, previously: develop) (source: session, repo: jp-kelly)

--- /memories/corrections.md  (NEW FILE)
+++ /memories/corrections.md
@@ -0,0 +1,3 @@
+# Corrections
+- [2026-08-12] User's name is Jordan, not Alex (source: session, confidence: high)

=== Summary ===
Entries added:      2
Entries updated:    2
Entries archived:    0
Contradictions:     2 resolved
Stale entries:      0 removed
Open questions:     1 (Is the deploy target still AWS us-east-1?)
Duration:           45s
```

If nothing changed (memories are already tight), say so explicitly:

```text
=== Dream Change Report ===
No changes needed. Memory is already consolidated and current.
```

---

## Execution

### Manual run

Tell VS Code chat:

> Run the dream skill. Read the SKILL.md and execute all 4 phases.

With flags (examples):

> Run the dream skill with --scope user --window 30 days
> Run the dream skill with --scope repo --workspace jp-kelly
> Run the dream skill with --scope repo --all
> Run the dream skill with --scope repo --workspace jp-kelly --workspace VSDream
> Run the dream skill with --dry-run --scope repo --workspace jp-kelly

### Automatic run

After installing with `--auto` (see install.sh), the `should-dream.sh` script checks on a timer whether 24+ hours have passed since the last dream. If so, it flags the next session to run a dream automatically.

You can also schedule it via a cron job or VS Code task (see README.md for details).

---

## Configuration

Config file: `~/.vscode/skills/dream/.dream-config`

```ini
# Memory scope to consolidate: user, repo, or session
# Flags --scope, --workspace, --all override these at runtime
DREAM_MEMORY_SCOPE=user

# Default workspace(s) for --scope repo (comma-separated repo paths or names)
# Leave empty to use the current workspace
DREAM_WORKSPACES=

# If true, --scope repo dreams iterate all known repositories
DREAM_ALL=false

# How far back to scan sessions: 1 day, 7 days, 30 days, 90 days, all
DREAM_WINDOW=7 days

# Minimum hours between automatic dreams
DREAM_INTERVAL_HOURS=24

# Dry run mode (preview only, no writes)
DREAM_DRY_RUN=false

# Maximum lines per memory file before archiving
DREAM_MAX_LINES=200
```

### Flag precedence

Runtime flags always override config file values:

| Source | Priority |
|--------|----------|
| Flags in the user's message (e.g. `--scope repo`) | Highest |
| `.dream-config` file values | Default |
| Built-in defaults (`--scope user`, `--window 7 days`, etc.) | Fallback |