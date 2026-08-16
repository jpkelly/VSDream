#!/usr/bin/env bash
#
# should-dream.sh - Check if dream consolidation should run
#
# Returns exit code 0 if dream should run, 1 if not.
# Condition: DREAM_INTERVAL_HOURS (default 24) since last consolidation.
#
# Usage:
#   ./should-dream.sh                          # Check user-scope conditions
#   ./should-dream.sh --scope repo              # Check current workspace repo conditions
#   ./should-dream.sh --scope repo --workspace /path/to/repo
#   ./should-dream.sh --scope repo --workspace jp-kelly
#   ./should-dream.sh --scope repo --all        # Check all known repos
#   ./should-dream.sh --force                   # Always exit 0
#
# Reads config from ~/.vscode/skills/dream/.dream-config

set -euo pipefail

SKILL_DIR="$HOME/.vscode/skills/dream"
CONFIG="$SKILL_DIR/.dream-config"

# Defaults
FORCE=0
SCOPE="user"
WORKSPACES=()
ALL=0

# Read config defaults first
if [[ -f "$CONFIG" ]]; then
    CFG_SCOPE=$(grep '^DREAM_MEMORY_SCOPE=' "$CONFIG" 2>/dev/null | cut -d= -f2 || echo "")
    [[ -n "$CFG_SCOPE" ]] && SCOPE="$CFG_SCOPE"
fi

# Parse flags (override config)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --force)     FORCE=1; shift ;;
        --scope)     SCOPE="$2"; shift 2 ;;
        --workspace) WORKSPACES+=("$2"); shift 2 ;;
        --all)       ALL=1; shift ;;
        *)           shift ;;
    esac
done

if [[ $FORCE -eq 1 ]]; then
    echo "Dream forced (--force flag set)"
    exit 0
fi

# Read interval from config
DREAM_INTERVAL_HOURS=24
if [[ -f "$CONFIG" ]]; then
    CONFIG_VAL=$(grep '^DREAM_INTERVAL_HOURS=' "$CONFIG" 2>/dev/null | cut -d= -f2 || echo "")
    if [[ -n "$CONFIG_VAL" ]]; then
        DREAM_INTERVAL_HOURS="$CONFIG_VAL"
    fi
fi

NOW=$(date +%s)

# --- Determine the last-dream file(s) to check based on scope ---

check_last_dream() {
    local last_file="$1"
    if [[ ! -f "$last_file" ]]; then
        echo "  $2: first-run (no .last-dream)"
        return 0
    fi
    local last_dream
    last_dream=$(cat "$last_file" 2>/dev/null || echo "0")
    local elapsed=$(( NOW - last_dream ))
    local hours=$(( elapsed / 3600 ))
    if (( hours < DREAM_INTERVAL_HOURS )); then
        echo "  $2: too soon (${hours}h < ${DREAM_INTERVAL_HOURS}h)" >&2
        return 1
    fi
    echo "  $2: ready (${hours}h >= ${DREAM_INTERVAL_HOURS}h)"
    return 0
}

echo "Dream check — scope: $SCOPE"

case "$SCOPE" in
    user)
        # Single global timestamp for user memory
        if check_last_dream "$SKILL_DIR/.last-dream" "user"; then
            exit 0
        else
            exit 1
        fi
        ;;
    session)
        # Session memory is ephemeral — always allow (no timestamp needed)
        echo "Dream conditions met: session scope (no timestamp needed)"
        exit 0
        ;;
    repo)
        if [[ $ALL -eq 1 ]]; then
            # Check all repos that have memory directories
            echo "Checking all repos with memory..."
            local_ready=0
            local_any_ready=0
            for repo_mem_dir in "$HOME/.vscode/skills/dream/repos"/*/; do
                [[ -d "$repo_mem_dir" ]] || continue
                repo_slug=$(basename "$repo_mem_dir")
                if check_last_dream "${repo_mem_dir}.last-dream" "repo:$repo_slug"; then
                    local_any_ready=1
                fi
            done
            if (( local_any_ready == 1 )); then
                echo "At least one repo is ready to dream"
                exit 0
            else
                echo "No repos are ready to dream" >&2
                exit 1
            fi
        elif [[ ${#WORKSPACES[@]} -gt 0 ]]; then
            # Check specific workspace(s)
            local_any_ready=0
            for ws in "${WORKSPACES[@]}"; do
                # Derive slug from path or name
                repo_slug=$(basename "$ws" | tr '[:upper:]' '[:lower:]')
                last_file="$SKILL_DIR/repos/$repo_slug/.last-dream"
                if check_last_dream "$last_file" "repo:$repo_slug"; then
                    local_any_ready=1
                fi
            done
            if (( local_any_ready == 1 )); then
                exit 0
            else
                exit 1
            fi
        else
            # Current workspace — derive slug from cwd
            repo_slug=$(basename "$PWD" | tr '[:upper:]' '[:lower:]')
            last_file="$SKILL_DIR/repos/$repo_slug/.last-dream"
            if check_last_dream "$last_file" "repo:$repo_slug (current)"; then
                exit 0
            else
                exit 1
            fi
        fi
        ;;
    *)
        echo "Unknown scope: $SCOPE" >&2
        exit 1
        ;;
esac