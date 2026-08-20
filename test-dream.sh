#!/usr/bin/env bash
#
# test-dream.sh - Test harness for VSDream memory consolidation
#
# Creates realistic test fixtures with known issues, then verifies
# that the dream skill fixes them correctly.
#
# Usage:
#   ./test-dream.sh setup     Create test fixtures with known issues
#   ./test-dream.sh verify    Check consolidation results after running /dream
#   ./test-dream.sh scan      Run scan-local-sessions.py fixture self-test
#   ./test-dream.sh skill     Check SKILL.md requires native vscode_askQuestions
#   ./test-dream.sh teardown  Remove test fixtures
#
# Workflow:
#   1. ./test-dream.sh setup
#   2. Run the dream skill in VS Code chat (scoped to the test memory)
#   3. ./test-dream.sh verify
#   4. ./test-dream.sh teardown

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$HOME/.vscode/skills/dream/test-fixtures"
MEMORY_DIR="$TEST_DIR/memories"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

pass() { echo -e "${GREEN}[PASS]${NC} $1"; }
fail() { echo -e "${RED}[FAIL]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

# ============================================================================
# SETUP - Create test fixtures with deliberate problems
# ============================================================================
do_setup() {
    info "=== step: Creating test environment at $TEST_DIR ==="

    if [[ -d "$TEST_DIR" ]]; then
        warn "Test directory already exists. Run '$0 teardown' first."
        exit 1
    fi

    mkdir -p "$MEMORY_DIR"

    # --- Create existing preferences.md with stale entries ---
    cat > "$MEMORY_DIR/preferences.md" << 'PREFEOF'
# Preferences

- [2025-01-10] Prefers tabs for indentation (source: session, confidence: high)
- [2025-01-08] Always use semicolons in JavaScript (source: session, confidence: high)
- [2025-01-05] Use yarn for package management (source: session, confidence: high)
- [2024-06-15] Likes to use Sublime Text for quick edits (source: session, confidence: medium)
PREFEOF

    # --- Create existing decisions.md ---
    cat > "$MEMORY_DIR/decisions.md" << 'DECEOF'
# Decisions

- [2025-01-10] Using PostgreSQL for the database (source: session, confidence: high)
- [2025-01-08] Default branch is "develop" (source: session, confidence: high)
- [2025-01-05] Deploy target is AWS us-east-1 (source: session, confidence: high)
- [2025-01-03] API hosted at https://api.oldservice.com/v1 (source: session, confidence: high)
DECEOF

    # --- Create a MEMORY.md (index) with deliberate problems ---
    cat > "$MEMORY_DIR/MEMORY.md" << 'MEMEOF'
# Memory Index

Last consolidated: 2025-01-15

## Topic Files

| File | Summary | Updated |
|------|---------|---------|
| preferences.md | Code style and tool preferences | 2025-01-15 |
| decisions.md | Project architecture decisions | 2025-01-10 |
| nonexistent.md | This file does not actually exist | 2025-01-05 |

## Quick Reference

- User prefers tabs for indentation
- Default branch is "develop"
- API base URL is https://api.oldservice.com/v1
- Yesterday the user mentioned they like dark themes
- The project uses React 17
- Last week we decided to use PostgreSQL
- User's timezone is PST
- Always use semicolons in JavaScript
- The user hates verbose commit messages
- Keep PRs under 200 lines
- User prefers vim keybindings
- Never auto-format on save
- The deploy target is AWS us-east-1
- Use yarn, not npm
- The user's name is probably Alex
MEMEOF

    echo ""
    echo "=== KNOWN ISSUES THE DREAM SKILL SHOULD FIX ==="
    echo ""
    echo "  1. MEMORY.md references nonexistent.md (does not exist)"
    echo "  2. MEMORY.md has relative dates ('Yesterday', 'Last week')"
    echo "  3. MEMORY.md Quick Reference has 15 items (should be <=10)"
    echo "  4. preferences.md says 'tabs' but should be '2 spaces' (contradiction)"
    echo "  5. preferences.md says 'yarn' but should be 'pnpm' (contradiction)"
    echo "  6. decisions.md says branch is 'develop' but should be 'main' (contradiction)"
    echo "  7. decisions.md has old API URL, should be newplatform.io (contradiction)"
    echo "  8. MEMORY.md says user's name is 'probably Alex' but it's Jordan (wrong)"
    echo "  9. New preference: prettier before commits (not in memory yet)"
    echo " 10. New preference: Result types / neverthrow (not in memory yet)"
    echo ""
    echo "=== NEXT STEPS ==="
    echo ""
    echo "  1. Open VS Code chat"
    echo "  2. Tell the agent: 'Run the dream skill, targeting $MEMORY_DIR'"
    echo "     (The agent should read SKILL.md and execute all 4 phases,"
    echo "      using $MEMORY_DIR as the memory directory instead of /memories/)"
    echo "  3. After it completes, run: $0 verify"
    echo ""
}

# ============================================================================
# SCANNER - Flavor-agnostic local session helper
# ============================================================================
do_scan_test() {
    local scanner="$SCRIPT_DIR/scan-local-sessions.py"
    if [[ ! -f "$scanner" ]]; then
        fail "scan-local-sessions.py not found next to test-dream.sh"
        exit 1
    fi
    info "=== step: Running scan-local-sessions.py --self-test ==="
    python3 "$scanner" --self-test
}

# ============================================================================
# SKILL TEXT - Static checks that the skill still requires native Q&A
# ============================================================================
do_skill_text_test() {
    local skill="$SCRIPT_DIR/SKILL.md"
    if [[ ! -f "$skill" ]]; then
        fail "SKILL.md not found next to test-dream.sh"
        exit 1
    fi

    info "=== step: Checking SKILL.md requires vscode_askQuestions ==="
    echo ""

    local total=0
    local passed=0
    run_check() {
        total=$((total + 1))
        if eval "$1"; then
            pass "$2"
            passed=$((passed + 1))
        else
            fail "$2"
        fi
    }

    run_check "grep -q 'vscode_askQuestions' \"$skill\"" \
        "SKILL.md mentions vscode_askQuestions"
    run_check "grep -q 'Ask open questions with the native picker' \"$skill\"" \
        "SKILL.md has the required native-picker section"
    run_check "grep -q 'Do not dump questions as chat prose' \"$skill\"" \
        "SKILL.md forbids chat-prose questions"
    run_check "! grep -q 'GoaAsk' \"$skill\"" \
        "Phase 3 header is not corrupted"
    run_check "grep -q 'Ask open questions with \`vscode_askQuestions\`, don.t invent' \"$skill\"" \
        "Phase 3 rule 5 requires the native picker"

    echo ""
    echo "=============================="
    echo -e "  Results: ${passed}/${total} checks passed"
    echo "=============================="
    echo ""

    if [[ $passed -ne $total ]]; then
        exit 1
    fi
}

# ============================================================================
# VERIFY - Check consolidation results
# ============================================================================
do_verify() {
    if [[ ! -d "$TEST_DIR" ]]; then
        fail "Test directory does not exist. Run '$0 setup' first."
        exit 1
    fi

    echo ""
    info "=== step: Verifying dream consolidation results ==="
    echo ""

    local total=0
    local passed=0

    run_check() {
        total=$((total + 1))
        if eval "$1"; then
            pass "$2"
            passed=$((passed + 1))
        else
            fail "$2"
        fi
    }

    # --- MEMORY.md checks ---
    local memfile="$MEMORY_DIR/MEMORY.md"

    if [[ -f "$memfile" ]]; then
        run_check "[[ \$(wc -l < "$memfile") -le 200 ]]" \
            "MEMORY.md is under 200 lines ($(wc -l < "$memfile" 2>/dev/null || echo '?') lines)"

        run_check "! grep -qi 'nonexistent.md' "$memfile" 2>/dev/null" \
            "Stale reference to nonexistent.md removed"

        run_check "! grep -qi 'yesterday' "$memfile" 2>/dev/null" \
            "No relative date 'yesterday' in MEMORY.md"

        run_check "! grep -qi 'last week' "$memfile" 2>/dev/null" \
            "No relative date 'last week' in MEMORY.md"

        run_check "! grep -qi 'probably Alex' "$memfile" 2>/dev/null" \
            "Incorrect name 'probably Alex' removed from MEMORY.md"
    else
        fail "MEMORY.md not found"
        total=$((total + 5))
    fi

    # --- Contradiction resolution ---
    local preffile="$MEMORY_DIR/preferences.md"

    if [[ -f "$preffile" ]]; then
        run_check "grep -qi 'spaces\|2.space' "$preffile" 2>/dev/null" \
            "Indentation updated to spaces in preferences"

        run_check "grep -qi 'pnpm' "$preffile" 2>/dev/null" \
            "Package manager updated to pnpm"

        run_check "grep -qi 'prettier' "$preffile" 2>/dev/null" \
            "Prettier preference added"
    else
        fail "preferences.md not found"
        total=$((total + 3))
    fi

    # --- Decision updates ---
    local decfile="$MEMORY_DIR/decisions.md"

    if [[ -f "$decfile" ]]; then
        run_check "grep -qi 'main' "$decfile" 2>/dev/null" \
            "Default branch updated to 'main'"

        run_check "grep -qi 'newplatform' "$decfile" 2>/dev/null" \
            "API URL updated to newplatform.io"
    else
        fail "decisions.md not found"
        total=$((total + 2))
    fi

    # --- New entries that should have been created ---
    local all_memory
    all_memory=$(cat "$MEMORY_DIR"/*.md 2>/dev/null || echo "")

    run_check "grep -qi 'neverthrow\|Result.type' \"$MEMORY_DIR\"/*.md 2>/dev/null" \
        "neverthrow / Result types preference captured somewhere in memory"

    run_check "grep -qi 'jordan' \"$MEMORY_DIR\"/*.md 2>/dev/null" \
        "User's name (Jordan) captured in memory"

    # --- Date format checks ---
    run_check "! grep -rEi '(yesterday|last week|last month|today|tomorrow)' \"$MEMORY_DIR\"/*.md 2>/dev/null | grep -v 'previously\|was\|changed from\|Updated.*previously' > /dev/null 2>&1" \
        "No unresolved relative dates in any memory file"

    # --- No duplicates check ---
    if [[ -f "$preffile" ]]; then
        local dup_count
        dup_count=$(sort "$preffile" | uniq -d | wc -l | tr -d ' ')
        run_check "[[ '$dup_count' -eq 0 ]]" \
            "No exact duplicate lines in preferences.md"
    else
        fail "preferences.md not found for duplicate check"
        total=$((total + 1))
    fi

    # --- Summary ---
    echo ""
    echo "=============================="
    echo -e "  Results: ${passed}/${total} checks passed"
    echo "=============================="
    echo ""

    if [[ $passed -eq $total ]]; then
        echo -e "${GREEN}All checks passed! Dream consolidation looks correct.${NC}"
    elif [[ $passed -ge $((total * 3 / 4)) ]]; then
        echo -e "${YELLOW}Most checks passed. Review the failures above.${NC}"
    else
        echo -e "${RED}Several checks failed. The dream skill needs work.${NC}"
    fi

    echo ""
    echo "Manual review recommended. Check these files:"
    echo "  $MEMORY_DIR/MEMORY.md"
    find "$MEMORY_DIR" -name "*.md" ! -name "MEMORY.md" | sort | while read -r f; do
        echo "  $f"
    done
    echo ""
}

# ============================================================================
# TEARDOWN - Clean up test fixtures
# ============================================================================
do_teardown() {
    if [[ ! -d "$TEST_DIR" ]]; then
        warn "Test directory does not exist. Nothing to clean up."
        exit 0
    fi

    info "=== step: Removing test environment at $TEST_DIR ==="
    rm -rf "$TEST_DIR"
    pass "Test environment removed."
    echo ""
}

# ============================================================================
# Main
# ============================================================================
case "${1:-}" in
    setup)
        do_setup
        ;;
    verify)
        do_verify
        ;;
    scan)
        do_scan_test
        ;;
    skill)
        do_skill_text_test
        ;;
    teardown)
        do_teardown
        ;;
    *)
        echo "Usage: $0 {setup|verify|scan|skill|teardown}"
        echo ""
        echo "  setup     - Create test fixtures with known issues"
        echo "  verify    - Check if dream skill fixed the issues"
        echo "  scan      - Run scan-local-sessions.py fixture self-test"
        echo "  skill     - Check SKILL.md requires native vscode_askQuestions"
        echo "  teardown  - Remove test fixtures"
        exit 1
        ;;
esac