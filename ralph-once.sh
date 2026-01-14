#!/bin/bash
set -e

VERSION="1.0.0"
CONFIG_DIR=".ralph"
CONFIG_FILE="$CONFIG_DIR/config.json"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

# Read a value from JSON config, returning empty string for missing/null
json_value() {
    local value
    value=$(jq -r "$1 // \"\"" "$CONFIG_FILE" 2>/dev/null)
    [ "$value" = "null" ] && value=""
    echo "$value"
}

load_config() {
    [ -f "$CONFIG_FILE" ] || return 1
    MODE=$(json_value '.mode')
    COMMIT_MODE=$(json_value '.commitMode')
    REPO=$(json_value '.repo')
    PRD_FILE=$(json_value '.prdFile')
    AGENT=$(json_value '.agent')
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
{
  "mode": "$MODE",
  "commitMode": "$COMMIT_MODE",
  "repo": "$REPO",
  "prdFile": "$PRD_FILE",
  "agent": "$AGENT"
}
EOF
    echo "Configuration saved to $CONFIG_FILE"
}

detect_github_repo() {
    git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||' || echo ""
}

# Normalize repo to owner/repo format, handling URLs, .git suffix, etc.
normalize_repo() {
    echo "$1" | sed -E 's|^https?://||; s|.*github\.com[:/]||; s|\.git$||; s|/$||'
}

interactive_setup() {
    echo "Welcome to Ralph! Let's set up your project."
    echo ""
    
    echo "Where should Ralph get tasks from?"
    echo "  1) GitHub issues"
    echo "  2) PRD file (prd.json)"
    echo ""
    read -p "Choose [1/2]: " task_choice
    
    case $task_choice in
        1)
            MODE="github"
            local detected=$(detect_github_repo)
            if [ -n "$detected" ]; then
                read -p "GitHub repo [$detected]: " REPO
                [ -z "$REPO" ] && REPO="$detected"
            else
                read -p "GitHub repo (owner/repo): " REPO
            fi
            ;;
        2)
            MODE="prd"
            read -p "Path to PRD file [./prd.json]: " PRD_FILE
            [ -z "$PRD_FILE" ] && PRD_FILE="./prd.json"
            ;;
        *)
            echo "Invalid choice"; exit 1
            ;;
    esac
    
    echo ""
    echo "How should Ralph handle completed work?"
    echo "  1) Raise a PR and wait for checks"
    echo "  2) Commit to main and push"
    echo "  3) Commit to main only (no push)"
    echo "  4) Branch and commit (no push)"
    echo "  5) Don't commit (leave files unstaged)"
    echo ""
    read -p "Choose [1/2/3/4/5]: " commit_choice
    
    case $commit_choice in
        1) COMMIT_MODE="pr" ;;
        2) COMMIT_MODE="main" ;;
        3) COMMIT_MODE="commit" ;;
        4) COMMIT_MODE="branch" ;;
        5) COMMIT_MODE="none" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
    
    echo ""
    echo "Which AI agent should Ralph use?"
    echo "  1) opencode (default)"
    echo "  2) claude"
    echo ""
    read -p "Choose [1/2]: " agent_choice
    
    case $agent_choice in
        1|"") AGENT="opencode" ;;
        2)    AGENT="claude" ;;
        *)    echo "Invalid choice"; exit 1 ;;
    esac
    
    echo ""
    save_config
    echo ""
}

show_usage() {
    cat << 'EOF'
Usage: ralph-once.sh [options] [<owner/repo> | --prd <file>]

If no arguments are provided and no config exists, Ralph will
interactively ask for your preferences and save them.

Options:
  --pr        Raise a PR and wait for checks
  --main      Commit directly to main branch and push
  --commit    Commit to main but don't push
  --branch    Create a branch and commit (no push)
  --none      Don't commit, leave files unstaged
  --opencode  Use opencode as the AI agent (default)
  --claude    Use claude as the AI agent
  --setup     Force interactive setup (overwrites existing config)

Examples:
  ralph-once.sh                          # Use saved config or run setup
  ralph-once.sh myorg/myproject          # GitHub issues mode
  ralph-once.sh --prd ./tasks/prd.json   # PRD file mode
  ralph-once.sh --claude --prd ./prd.json # Use claude with PRD
  ralph-once.sh --setup                  # Re-run interactive setup
EOF
}

# ============================================================
# ARGUMENT PARSING
# ============================================================
MODE=""
REPO=""
PRD_FILE=""
COMMIT_MODE=""
AGENT=""
FORCE_SETUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --prd)         MODE="prd"; PRD_FILE="$2"; shift 2 ;;
        --pr)          COMMIT_MODE="pr"; shift ;;
        --main)        COMMIT_MODE="main"; shift ;;
        --commit)      COMMIT_MODE="commit"; shift ;;
        --branch)      COMMIT_MODE="branch"; shift ;;
        --none)        COMMIT_MODE="none"; shift ;;
        --opencode)    AGENT="opencode"; shift ;;
        --claude)      AGENT="claude"; shift ;;
        --setup)       FORCE_SETUP=true; shift ;;
        -h|--help)     show_usage; exit 0 ;;
        -v|--version)  echo "ralph-once $VERSION"; exit 0 ;;
        -*)            echo "Unknown option: $1"; show_usage; exit 1 ;;
        *)             [ -z "$REPO" ] && MODE="github" && REPO="$1"; shift ;;
    esac
done

# ============================================================
# INITIALIZATION
# ============================================================

# Check dependencies
check_dependency() {
    command -v "$1" > /dev/null 2>&1 || { echo "Error: '$1' is required but not installed."; exit 1; }
}

check_dependency git
check_dependency jq

# Must be in a git repo
git rev-parse --git-dir > /dev/null 2>&1 || { echo "Error: Not in a git repository"; exit 1; }

# Save flag values (flags should override config)
FLAG_MODE="$MODE"
FLAG_REPO="$REPO"
FLAG_PRD_FILE="$PRD_FILE"
FLAG_COMMIT_MODE="$COMMIT_MODE"
FLAG_AGENT="$AGENT"

# Load or create config
if [ "$FORCE_SETUP" = true ]; then
    interactive_setup
elif [ -z "$FLAG_MODE" ]; then
    if load_config && [ -n "$MODE" ]; then
        echo "Loaded config from $CONFIG_FILE"
    else
        interactive_setup
    fi
fi

# Flags override config
[ -n "$FLAG_MODE" ] && MODE="$FLAG_MODE"
[ -n "$FLAG_REPO" ] && REPO="$FLAG_REPO"
[ -n "$FLAG_PRD_FILE" ] && PRD_FILE="$FLAG_PRD_FILE"
[ -n "$FLAG_COMMIT_MODE" ] && COMMIT_MODE="$FLAG_COMMIT_MODE"
[ -n "$FLAG_AGENT" ] && AGENT="$FLAG_AGENT"

# Defaults
[ -z "$COMMIT_MODE" ] && COMMIT_MODE="pr"
[ -z "$AGENT" ] && AGENT="opencode"

# Normalize repo (handles URLs, .git suffix, typos)
[ -n "$REPO" ] && REPO=$(normalize_repo "$REPO")

# ============================================================
# VALIDATION
# ============================================================
validate_github_mode() {
    [ -z "$REPO" ] && { echo "Error: No repository specified"; exit 1; }
    local remote=$(normalize_repo "$(git remote get-url origin 2>/dev/null || echo "")")
    [[ "$remote" =~ "$REPO" ]] || { echo "Error: Current directory doesn't appear to be a clone of $REPO"; echo "Remote URL: $remote"; exit 1; }
}

validate_prd_mode() {
    [ -z "$PRD_FILE" ] && { echo "Error: No PRD file specified"; exit 1; }
    [ -f "$PRD_FILE" ] || { echo "Error: PRD file not found: $PRD_FILE"; exit 1; }
}

case "$MODE" in
    github) validate_github_mode ;;
    prd)    validate_prd_mode ;;
esac

# ============================================================
# PREPARE WORKSPACE
# ============================================================
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
echo "Checking out $DEFAULT_BRANCH and pulling latest..."
git checkout "$DEFAULT_BRANCH"
git pull origin "$DEFAULT_BRANCH"

touch progress.txt
PROGRESS=$(cat progress.txt)

# ============================================================
# BUILD PROMPT SECTIONS
# ============================================================

# --- TASK CONTEXT: Mode-specific task fetching ---
fetch_prd_tasks() {
    PRD_CONTENT=$(cat "$PRD_FILE")
    PRD_NAME=$(jq -r '.name // "Unknown Project"' "$PRD_FILE")
    PRD_BRANCH=$(jq -r '.branchName // ""' "$PRD_FILE")
    [ "$PRD_BRANCH" = "null" ] && PRD_BRANCH=""
    
    echo "Working on PRD: $PRD_NAME"
    echo "PRD file: $PRD_FILE"
    
    TASK_CONTEXT="You are working on: $PRD_NAME

Here is the PRD file ($PRD_FILE):

$PRD_CONTENT

Tasks with \"passes\": false are incomplete. A task can only be worked on if all its dependencies (dependsOn) are complete."

    GAPS_INSTRUCTIONS="5. If you discover anything critically missing, note it in progress.txt (max 2 items)."

    COMPLETION_INSTRUCTIONS="9. Update progress.txt with what you did, including the task ID.
10. Update the PRD file ($PRD_FILE): set \"passes\": true and add \"completionNotes\" for the task you completed.
11. Output: <promise>COMPLETE</promise>
ONLY DO ONE TASK AT A TIME."

    TASK_ITEM="task"
}

fetch_github_tasks() {
    echo "Working on repo: $REPO"
    
    ISSUES=$(gh issue list --repo "$REPO" --state open --limit 20 --json number,title,body,labels) || {
        echo "Error: Failed to fetch issues from $REPO"; exit 1
    }
    
    [ -z "$ISSUES" ] || [ "$ISSUES" = "[]" ] && { echo "No open issues found in $REPO"; exit 0; }
    
    TASK_CONTEXT="Here are the open GitHub issues for $REPO:

$ISSUES

Issues marked as done in progress.txt should not be worked on again."

    GAPS_INSTRUCTIONS="5. If you discover anything critically missing, raise an issue for it (max 2 issues)."

    COMPLETION_INSTRUCTIONS="9. Update progress.txt with what you did, including the issue number.
10. Output: <promise>COMPLETE</promise>
ONLY DO ONE ISSUE AT A TIME."

    TASK_ITEM="issue"
}

case "$MODE" in
    prd)    fetch_prd_tasks ;;
    github) fetch_github_tasks ;;
esac

echo "Commit mode: $COMMIT_MODE"
echo "Agent: $AGENT"

# --- SELECTION: How to choose the next task (same for all modes) ---
SELECTION_INSTRUCTIONS="1. Review the available ${TASK_ITEM}s and the progress file.
2. Find the next $TASK_ITEM to work on:
   - Pick the lowest-numbered $TASK_ITEM that is available to be worked on
   - Use your judgment if one seems more urgent or foundational than others"

# --- IMPLEMENTATION: Core work steps (same for all modes) ---
IMPLEMENTATION_INSTRUCTIONS="3. Implement the changes needed to complete the $TASK_ITEM.
4. Run the test suite and linter. Fix any failures or quality issues before proceeding."

# --- COMMIT: How to save work ---
build_commit_instructions() {
    local base="6. ONLY when all checks are passing,"
    
    case "$COMMIT_MODE" in
        pr)
            echo "$base commit your changes with a well-written commit message following guidance in AGENTS.md
7. Raise a pull request with a title and description referencing the $TASK_ITEM, and share the link.
8. Wait for PR status checks to pass. If they fail, fix the issues and push again."
            ;;
        main)
            echo "$base commit your changes to main with a well-written commit message following guidance in AGENTS.md
7. Push your commit to origin."
            ;;
        commit)
            echo "$base commit your changes to main with a well-written commit message following guidance in AGENTS.md
7. Do NOT push - leave the commit local for review."
            ;;
        branch)
            if [ "$MODE" = "prd" ] && [ -n "$PRD_BRANCH" ]; then
                echo "$base create or switch to branch '$PRD_BRANCH' and commit your changes with a well-written commit message following guidance in AGENTS.md
7. Do NOT push - leave the branch local for review."
            else
                echo "$base create a new branch with a sensible name based on the $TASK_ITEM (e.g., feature/123-$TASK_ITEM-title) and commit your changes with a well-written commit message following guidance in AGENTS.md
7. Do NOT push - leave the branch local for review."
            fi
            ;;
        none)
            echo "$base leave all files unstaged. Do NOT commit or push anything.
7. Report what files were changed so they can be reviewed."
            ;;
    esac
}

COMMIT_INSTRUCTIONS=$(build_commit_instructions)

# ============================================================
# RUN AGENT
# ============================================================
PROMPT="
$TASK_CONTEXT

And here is the progress file (progress.txt):

$PROGRESS

$SELECTION_INSTRUCTIONS
$IMPLEMENTATION_INSTRUCTIONS
$GAPS_INSTRUCTIONS
$COMMIT_INSTRUCTIONS
$COMPLETION_INSTRUCTIONS"

check_dependency "$AGENT"

case "$AGENT" in
    opencode) opencode --prompt "$PROMPT" ;;
    claude)   claude "$PROMPT" ;;
    *)        echo "Error: Unknown agent '$AGENT'"; exit 1 ;;
esac
