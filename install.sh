#!/usr/bin/env bash
#
# install.sh - Install the VSDream skill for VS Code native chat
#
# Copies the skill to your ~/.vscode/skills/dream/ directory and optionally
# sets up auto-trigger configuration.
#
# Usage:
#   bash install.sh              # Install or update (overwrites skill files, preserves .dream-config)
#   bash install.sh --auto       # Install/update + set up auto-trigger guidance
#   bash install.sh --uninstall   # Remove skill (preserves /memories/)
#   bash install.sh --force      # Update + overwrite .dream-config with defaults (resets config)#
# Skills are installed to ~/.copilot/skills/dream/ — the path VS Code and
# VS Code Insiders both load custom Copilot skills from.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$HOME/.copilot/skills/dream"
CONFIG_DIR="$HOME/.copilot/skills/dream"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
err()  { echo -e "${RED}[ERR]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# --- Parse args ---
AUTO=0
FORCE=0
UNINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --auto)      AUTO=1 ;;
        --force)     FORCE=1 ;;
        --uninstall) UNINSTALL=1 ;;
    esac
done

# --- Uninstall ---
if [[ $UNINSTALL -eq 1 ]]; then
    info "Removing VSDream skill from $SKILL_DIR"
    rm -rf "$SKILL_DIR"
    ok "VSDream skill removed."
    echo ""
    info "Your /memories/ files are NOT touched — only the skill was removed."
    exit 0
fi

# --- Check for existing install ---
INSTALLED_BEFORE=0
if [[ -d "$SKILL_DIR" && -f "$SKILL_DIR/SKILL.md" ]]; then
    INSTALLED_BEFORE=1
    if [[ $FORCE -eq 1 ]]; then
        info "VSDream is already installed — force-updating (including .dream-config)..."
    else
        info "VSDream is already installed at $SKILL_DIR — updating files..."
    fi
    # Fall through to copy step (overwrites existing files)
else
    info "Installing VSDream for the first time..."
fi

# --- Install skill ---
echo ""
info "=== step: Installing VSDream to $SKILL_DIR ==="
mkdir -p "$SKILL_DIR"

cp "$SCRIPT_DIR/SKILL.md"           "$SKILL_DIR/SKILL.md"
cp "$SCRIPT_DIR/should-dream.sh"   "$SKILL_DIR/should-dream.sh"
chmod +x "$SKILL_DIR/should-dream.sh"

# Copy config template — only if missing, unless --force (then overwrite)
if [[ $FORCE -eq 1 ]] || [[ ! -f "$SKILL_DIR/.dream-config" ]]; then
    if [[ -f "$SCRIPT_DIR/.dream-config.template" ]]; then
        cp "$SCRIPT_DIR/.dream-config.template" "$SKILL_DIR/.dream-config"
        if [[ $FORCE -eq 1 && $INSTALLED_BEFORE -eq 1 ]]; then
            info ".dream-config overwritten with template defaults (--force)"
        fi
    else
        cat > "$SKILL_DIR/.dream-config" << 'EOF'
DREAM_MEMORY_SCOPE=user
DREAM_WINDOW=7 days
DREAM_INTERVAL_HOURS=24
DREAM_DRY_RUN=false
DREAM_MAX_LINES=200
EOF
    fi
fi

ok "Skill files installed."
echo ""

# --- Report install location ---
info "=== step: Installation complete ==="
echo ""
ok "VSDream is installed to $SKILL_DIR"
if [[ $INSTALLED_BEFORE -eq 1 ]]; then
    echo ""
    if [[ $FORCE -eq 1 ]]; then
        info "Updated existing install — skill files + .dream-config overwritten with defaults."
    else
        info "Updated existing install — skill files overwritten, .dream-config preserved."
    fi
fi
echo ""
info "To run manually, tell VS Code chat:"
info "  \"Run the dream skill. Read SKILL.md and execute all 4 phases.\""
echo ""
if [[ $AUTO -eq 1 ]]; then
    info "=== step: Setting up auto-trigger ==="
    echo ""
    info "Auto-trigger uses a 24-hour timer checked by should-dream.sh."
    echo ""
    info "Option A — VS Code Task (recommended):"
    info "  A tasks.json entry has been created that you can run periodically."
    info "  See ~/.vscode/skills/dream/auto-dream-task.json"
    echo ""
    info "Option B — Cron job (background, no VS Code needed):"
    info "  Add to crontab: 0 */6 * * * bash $SKILL_DIR/should-dream.sh --force && echo 'Dream flagged'"
    echo ""
    info "Option C — Shell alias:"
    info "  alias dream='bash $SKILL_DIR/should-dream.sh --force'"
    echo ""
    warn "Note: VS Code native chat doesn't have a session-end hook like Claude Code's Stop hook."
    warn "Auto-trigger requires one of the above methods. See README.md for details."
else
    info "For auto-trigger, re-run: bash install.sh --auto"
fi
echo ""
info "Your /memories/ files are the target — no memory is modified during install."