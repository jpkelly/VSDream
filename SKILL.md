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
| `--exclude` | `<repo-path>` or `<repo-name>` | Exclude a repo's sessions from scanning. Can be repeated for multiple. Useful for avoiding self-referential noise (e.g. `--exclude VSDream`). |
| `--window` | `1 day`, `7 days`, `30 days`, `90 days`, `all` | How far back to scan sessions (overrides config) |
| `--apply` | (no value) | Write the changes to memory. **Without this flag, every dream is a preview only** — this mirrors the original dream prompt's caution: a dream reports what it found and proposes changes, it does not silently rewrite your memory. |
| `--force` | (no value) | Skip the time-since-last-dream check |

#### Scope details

- **`--scope user`** (default) — Consolidates `/memories/` (persistent, cross-workspace). Scans sessions from ALL repositories. This is for your global preferences, workflow patterns, and tool preferences.

- **`--scope repo`** — Consolidates `/memories/repo/` for one or more repositories. By default targets the **current workspace**. Use `--workspace` to target a different repo, or `--all` to iterate every known repo. This is for project-specific conventions, build commands, and architecture facts.

- **`--scope session`** — Consolidates `/memories/session/` for the current conversation only. Rarely useful — session memory is ephemeral.

#### Excluding repositories (`--exclude`)

The `--exclude` flag prevents sessions from specific repositories from being scanned. This avoids **self-referential noise**: if you run the dream from the VSDream workspace, the session store contains the very conversations where you built the skill. Without `--exclude`, those sessions might pollute global user memory with VSDream-specific details ("JP uses `session_store_sql`", "JP likes `--scope` flags") that aren't actually global preferences.

- `--exclude VSDream` — skip all sessions from the VSDream repo
- `--exclude VSDream --exclude jp-kelly` — skip multiple repos
- Can be combined with any scope. With `--scope user`, excluded repos' sessions are filtered out of the global scan. With `--scope repo --all`, excluded repos are skipped entirely.

**VSDream dreaming about itself:** There's a delightful meta case — if you *don't* exclude VSDream and run `--scope repo --workspace VSDream`, the dream will consolidate facts about its own development into `/memories/repo/vsdream/`. This is legitimate repo memory (the skill's design decisions, flag conventions, safety rules) and harmless. The dream learning about itself is a feature, not a bug. Just don't let those self-referential sessions leak into `--scope user` where they'd pollute your global preferences.

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
- `--exclude <path-or-name>` — exclude a repo's sessions from scanning (can appear multiple times)
- `--all` — consolidate across all known repositories
- `--window <interval>` — overrides `DREAM_WINDOW` config
- `--apply` — overrides `DREAM_APPLY` config; without it, the dream never writes
- `--force` — skip the last-dream time check

Then read the config file for defaults:

```bash
cat ~/.copilot/skills/dream/.dream-config 2>/dev/null || echo "DREAM_MEMORY_SCOPE=user"
```

**Determine the target scope and path:**

| Flag combo | Scope | Memory path | Sessions scanned |
|------------|-------|-------------|------------------|
| `--scope user` or no flag | `user` | `/memories/` | All repositories |
| `--scope repo` (no `--workspace`) | `repo` | `/memories/repo/` (current workspace) | Current workspace only |
| `--scope repo --workspace /path/to/repo` | `repo` | `/memories/repo/<repo-slug>/` | That repo only |
| `--scope repo --workspace A --workspace B` | `repo` | Two paths, dreamed sequentially | Each repo independently |
| `--scope repo --all` | `repo` | All repos that have memory or recent sessions | Each repo independently (minus `--exclude`d repos) |
| `--scope user --exclude VSDream` | `user` | `/memories/` | All repos except VSDream |
| `--scope session` | `session` | `/memories/session/` | Current session only |

**Repo slug derivation:** Convert a repo path or name to a slug by taking the last path component and lowercasing. E.g. `/Users/jp/Documents/GitHub/jp-kelly` → `jp-kelly`. If two repos have the same name, use the full path as the slug instead.

**If `--exclude` is set**, record the excluded repo names/slugs. These will be filtered out of every session query in Phase 2. Derive slugs the same way as `--workspace` (last path component, lowercased).

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

### Step 2: Reconcile against project instructions

Before gathering new signal, check what's **already** captured in instructions files — these are read automatically every session, so duplicating them into memory is wasted context. Look for, if present:

- `.github/copilot-instructions.md`
- `AGENTS.md` / `CLAUDE.md`
- `*.instructions.md` under the user prompts folder or `.github/instructions/`

For each, note the facts and preferences it already states. Two rules follow from this:

- **Don't duplicate.** If a fact already lives in an instructions file, don't write it to memory — it's already loaded every session.
- **Flag, don't silently fix, contradictions.** If memory disagrees with an instructions file, that's drift — report it in Phase 4's output. Never overwrite an instructions file; only memory is in scope for a dream.

### Output of this phase

You should now have a mental map of:
- What topics are covered in memory
- How large the memory files are
- What's potentially stale or contradictory
- What's already covered by instructions files (so Phase 2 doesn't re-capture it)
- What scope you're consolidating (`user`, `repo`, or `session`)
- If `--all`: the full list of repos to iterate

---

## Phase 2: GATHER SIGNAL

**Goal:** Extract important information recently learned — like a reflective pass over what happened, not an exhaustive audit. This is the model-agnostic phase: it reads the cloud session store that captures ALL past sessions regardless of which model ran them.

Sources in priority order — **read narrative first, grep second**:

1. **Session digest** (primary) — a chronological read of recent sessions: what each was about, what was done, what came next. This is the model-agnostic equivalent of reading a session log.
2. **Existing memory that drifted** — facts that contradict what the digest or codebase shows now.
3. **Targeted grep** (secondary, confirmatory only) — if the digest surfaces a theme you want to confirm or quote precisely (e.g. "was that phrased as a hard rule?"), run one narrow keyword query. Don't run a battery of queries by default.

**Don't exhaustively read.** Look only for things you already suspect matter from the digest. A query that returns 50 rows is a sign to skim for a repeated theme, not to catalog every row.

### Source: Cloud Session Store

VS Code's session store is a DuckDB database with tables: `sessions`, `turns`, `session_files`, `session_refs`, `checkpoints`, `events`, `tool_requests`. Use `session_store_sql` (read-only SELECT/WITH queries only).

### Step 1: Get the lay of the land

```sql
SELECT COUNT(*) as total_sessions, MIN(created_at) as earliest, MAX(created_at) as latest
FROM sessions;
```

```sql
SELECT agent_name, COUNT(*) as session_count
FROM sessions GROUP BY agent_name ORDER BY session_count DESC;
```

**Scope filtering** applies to every query below:
- `--scope repo` / `--workspace` → add `AND s.repository = '<repo-name>'`
- `--scope user` (default) → no repo filter
- `--exclude <repo>` (any scope) → add `AND s.repository NOT ILIKE '%<repo>%'` (chain for multiple)
- `--window <interval>` → add `AND s.created_at > now() - INTERVAL '<interval>'` (default `7 days`)

### Step 2: Read the session digest (primary source)

This is a narrative read, not a keyword scan. Pull one row per recent session — title, what was done, what's next — and read it chronologically, the same way you'd read a daily log:

```sql
SELECT s.created_at, s.repository, s.agent_name,
       c.title, c.work_done, c.next_steps
FROM checkpoints c
JOIN sessions s ON c.session_id = s.session_id
-- add scope/exclude/window filters here
ORDER BY s.created_at ASC
LIMIT 30;
```

If a session has no checkpoint, fall back to its first and last user turn for the same chronological read:

```sql
SELECT s.created_at, s.repository, s.agent_name, LEFT(t.user_message, 200) as msg
FROM turns t
JOIN sessions s ON t.session_id = s.id
-- add scope/exclude/window filters here
ORDER BY s.created_at ASC
LIMIT 60;
```

Read this like a log: what happened, in what order, in which repo. Note anything that looks like a correction, a stated preference, a recurring frustration, or a decision — the same things a keyword search would look for, but found by understanding rather than pattern-matching.

### Step 3: Targeted grep (secondary, confirmatory only)

Only run this if Step 2 surfaced something you want to confirm or quote exactly. Pick the narrowest query for the specific thing you suspect — don't run a fixed battery of categories. Example: if the digest suggests a correction about test-running, confirm it narrowly:

```sql
SELECT s.created_at, s.repository, LEFT(t.user_message, 300) as msg
FROM turns t
JOIN sessions s ON t.session_id = s.id
WHERE t.user_message ILIKE '%run the test%'
   OR t.user_message ILIKE '%run it myself%'
ORDER BY s.created_at DESC
LIMIT 10;
```

### Drift detection

Compare what the digest shows against existing memory. Flag (don't silently fix):

- **Server/infrastructure changes** — e.g., memory says "aws1" but recent sessions mention "aws2"
- **Tool/dependency changes** — e.g., "yarn" → "pnpm"
- **Naming changes** — e.g., branch "develop" → "main"
- **Workflow changes** — e.g., a stated goal that's since been completed or superseded

For each drift found, note: the old memory entry, the new evidence, and whether it should be updated or just flagged as an open question.

### Step 4: Session files (only if needed for context)

```sql
SELECT s.created_at, s.repository, sf.file_path, sf.event_type
FROM session_files sf
JOIN sessions s ON sf.session_id = s.session_id
-- add scope/exclude/window filters here
ORDER BY s.created_at DESC
LIMIT 50;
```

### Step 5: Git activity (repo-scoped dreams only)

When consolidating repo memory, also check git for durable signals not necessarily stated in any session:

```bash
git log --oneline --since="$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)" 2>/dev/null | head -30
git log --oneline --all -- package.json requirements.txt Cargo.toml go.mod pom.xml 2>/dev/null | head -10
```

Only extract things that are **durable and evidence-backed** — a single WIP commit is not evidence; a pattern across multiple commits is.

### Distinguishing global vs. project-specific

The most important judgment call in a `--scope user` dream:

- **Repeats across multiple repos** → global user preference → `/memories/`
- **Appears in one repo only** → project-specific → `/memories/repo/<repo-slug>/`
- **A one-off comment** → likely not durable — skip unless explicit and emphatic

### Report open questions — never invent facts

If something looks important but unconfirmed, collect it as an open question for the final report instead of guessing:

```
OPEN QUESTIONS:
- Is the user still using pnpm, or have they switched?
```

Open questions are reported but never written to memory as facts.

---

## Phase 3: CONSOLIDATE

**Goal:** Merge new findings into existing memory. This is the most delicate phase.

### Rules

1. **Never duplicate.** Before adding anything, check if it already exists in memory. If it does, update the existing entry rather than creating a new one.

2. **Convert relative dates to absolute (ISO 8601).** If a session from 2026-08-10 says "yesterday I changed the API key", write "2026-08-09: Changed API key" in memory. Never store "yesterday" or "last week" — they lose meaning immediately. All dates in memory must be absolute, parseable dates.

3. **Delete contradicted facts.** If memory says "Prefers tabs" but a recent session has the user saying "Use spaces", remove the old entry and write the new one. Add a note: `(Updated YYYY-MM-DD, previously: tabs)`. Retain the newer, better-supported fact; remove the outdated claim.

4. **Cite the date, not a metadata block.** The entry's own date is its provenance. Don't append `(source: ..., repo: ..., confidence: ...)` to every line — that's report detail, not something worth loading into context on every session.

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

8. **Entry format.** Each memory entry is one line, date first:
   ```markdown
   - [YYYY-MM-DD] The fact or preference.
   ```

9. **Brevity.** Memory files are loaded into context automatically. Keep entries to single lines where possible. Use bullet points, not paragraphs.

10. **Frontmatter is the index.** Every topic file starts with:
    ```markdown
    ---
    name: preferences
    description: How the user likes things done — one line, under 150 chars
    ---
    ```
    Keep `description` accurate and current — it's what future sessions see before opening the file, so a stale description is a stale index.

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

### Safety: dry run is the default

A dream never writes unless `--apply` was passed (see Safety section below). Phase 3 always produces its findings; whether they're written depends entirely on that flag.

---

## Phase 4: PRUNE & INDEX

**Goal:** Keep memory lean and well-organized. Remove stale content. Enforce size limits.

### Prune stale entries

Pruning is **contradiction-based, not age-based**. A preference stated once six months ago is still true until something contradicts it. Remove or archive an entry only when:
- It's **contradicted** by a newer, better-supported fact (should have been resolved in Phase 3 already)
- It **points at something that no longer exists** — a repo, a referenced repo-memory file, a deprecated tool
- It's **superseded** — the goal it described has been completed and replaced by a new one (note this, don't just delete: `(Superseded YYYY-MM-DD — <what replaced it>)`)

To check if a repo still exists in the session store (useful for "points at something that no longer exists"):

```sql
SELECT MAX(created_at) as last_active
FROM sessions
WHERE repository = '<repo-name>';
```

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

**Only if `--apply` was passed.** A preview run (the default) never writes a timestamp, a log entry, or anything else — it produced a report and nothing more. When `--apply` was passed, write the timestamp so the auto-trigger knows when you last dreamed. The location depends on scope:

**For `--scope user`:**

```bash
date +%s > ~/.copilot/skills/dream/.last-dream
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
mkdir -p ~/.copilot/skills/dream/logs
echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | scope: <scope> | workspace: <repo-or-all> | sessions_scanned: <N> | entries_added: <N> | entries_updated: <N> | entries_archived: <N> | contradictions_resolved: <N>" >> ~/.copilot/skills/dream/logs/dream.log
```

---

## Safety

### Hard constraints (never violate)

- **Never retain secrets.** No API keys, passwords, tokens, `.env` content, customer data, or raw production logs. If a session discusses credentials, note only that "credentials were configured" — never the values.

- **Never edit outside memory.** Do not modify code, infrastructure, dependencies, configuration, or any file outside the `/memories/` scope you're consolidating. The dream touches memory files only.

- **Never invent facts.** If you can't confirm something from evidence, report it as an open question in the summary — do not write it to memory as a fact.

- **Never delete memory without replacement.** If removing an entry, either it was contradicted (replaced by a newer entry) or it was moved (to a topic file or archive). Never just delete.

- **Preview is the default, not an option.** Every dream runs Phases 1–4 and produces a report. **Only write to `/memories/` if `--apply` was explicitly passed.** Without it, no `memory(create)`, `memory(str_replace)`, `memory(insert)`, or `memory(delete)` call may be made — report the findings and stop.

### Soft guidelines

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
5. Produce a concise change report

### Change report format

The report must be **concise and scannable** — a table for the at-a-glance view, plus a **unified diff** underneath for anyone who wants the precise before/after. No prose paragraphs.

```text
═══ DREAM REPORT ═══
Date:    2026-08-15 14:32 UTC
Scope:   user
Window:  7 days · 37 sessions · 20 models

─── CHANGES (3) ───
ACTION   FILE                    ENTRY
ADD      preferences.md          Prefers to run tests himself, not agent
UPDATE   workflow-jp-kelly.md    Server: aws1 → aws2 (decommissioned)
CREATE   corrections.md          New file — 1 entry

─── DIFF ───
--- workflow-jp-kelly.md
+++ workflow-jp-kelly.md
@@ -5 +5 @@
-- Server work (SSH to aws1.smallgod.net): ...
+- Server work (SSH to aws2.smallgod.net): ... (aws1 decommissioned 2026-08-13)

─── DRIFT (1) ───
FILE                    ISSUE                          EVIDENCE
workflow-jp-kelly.md    Says "aws1" but aws1 is dead   Session 2026-08-13

─── OPEN QUESTIONS (1) ───
- Is AWS2 fully primary, or is AWS1 still needed for some services?

─── SUMMARY ───
Added 1 · Updated 1 · Created 1 · Drift 1 · Questions 1
Status: PREVIEW — no files modified (pass --apply to write)
```

**Rules for the report:**
- **CHANGES table** — one line per change: `ADD`/`UPDATE`/`REMOVE`/`CREATE`, filename only, short entry description (max ~60 chars)
- **DIFF** — a real unified diff for each changed file, so the exact before/after is visible
- **DRIFT** — separate from changes; shows what's stale and the evidence
- **OPEN QUESTIONS** — things that look important but unconfirmed
- **SUMMARY** — one line: counts + status
- If nothing changed, say so and stop — don't emit an empty table:

```text
═══ DREAM REPORT ═══
No changes needed. Memory is already current.
Status: PREVIEW — no files modified
```

**Without `--apply` (the default):** the report is produced and nothing is written. Status line: `PREVIEW — no files modified (pass --apply to write)`.

**With `--apply`:** the report is produced AND the changes in it are written. Status line: `APPLIED — N files modified`.

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
> Run the dream skill with --scope repo --workspace jp-kelly --apply

Every run above is a **preview only** unless `--apply` is included — add it once you've reviewed the report and want the changes written.

### Automatic run

After installing with `--auto` (see install.sh), the `should-dream.sh` script checks on a timer whether 24+ hours have passed since the last dream. If so, it flags the next session to run a dream automatically.

You can also schedule it via a cron job or VS Code task (see README.md for details).

---

## Configuration

Config file: `~/.copilot/skills/dream/.dream-config`

```ini
# Memory scope to consolidate: user, repo, or session
# Flags --scope, --workspace, --all override these at runtime
DREAM_MEMORY_SCOPE=user

# Default workspace(s) for --scope repo (comma-separated repo paths or names)
# Leave empty to use the current workspace
DREAM_WORKSPACES=

# Repositories to exclude from session scanning (comma-separated repo paths or names)
# Prevents self-referential noise — e.g. exclude VSDream so its own dev sessions
# don't pollute global user memory with project-specific details
# Runtime flag: --exclude VSDream (can be repeated)
DREAM_EXCLUDE=

# If true, --scope repo dreams iterate all known repositories
DREAM_ALL=false

# How far back to scan sessions: 1 day, 7 days, 30 days, 90 days, all
DREAM_WINDOW=7 days

# Minimum hours between automatic dreams
DREAM_INTERVAL_HOURS=24

# Whether a dream is allowed to write to memory. false = always preview only.
# Runtime flag: --apply (overrides this to true for a single run)
DREAM_APPLY=false

# Maximum lines per memory file before splitting
DREAM_MAX_LINES=200
```

### Flag precedence

Runtime flags always override config file values:

| Source | Priority |
|--------|----------|
| Flags in the user's message (e.g. `--scope repo`) | Highest |
| `.dream-config` file values | Default |
| Built-in defaults (`--scope user`, `--window 7 days`, etc.) | Fallback |