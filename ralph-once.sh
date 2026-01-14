#!/bin/bash
set -e

CONFIG_DIR=".ralph"
CONFIG_FILE="$CONFIG_DIR/config.json"

MODE=""
REPO=""
PRD_FILE=""
COMMIT_MODE=""

# ============================================================
# HELPER FUNCTIONS
# ============================================================
load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        MODE=$(jq -r '.mode // ""' "$CONFIG_FILE")
        COMMIT_MODE=$(jq -r '.commitMode // ""' "$CONFIG_FILE")
        REPO=$(jq -r '.repo // ""' "$CONFIG_FILE")
        PRD_FILE=$(jq -r '.prdFile // ""' "$CONFIG_FILE")
        
        # Handle null values from jq
        [ "$MODE" = "null" ] && MODE=""
        [ "$COMMIT_MODE" = "null" ] && COMMIT_MODE=""
        [ "$REPO" = "null" ] && REPO=""
        [ "$PRD_FILE" = "null" ] && PRD_FILE=""
        return 0
    fi
    return 1
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
{
  "mode": "$MODE",
  "commitMode": "$COMMIT_MODE",
  "repo": "$REPO",
  "prdFile": "$PRD_FILE"
}
EOF
    echo "Configuration saved to $CONFIG_FILE"
}

interactive_setup() {
    echo "Welcome to Ralph! Let's set up your project."
    echo ""
    
    # Ask for task source
    echo "Where should Ralph get tasks from?"
    echo "  1) GitHub issues"
    echo "  2) PRD file (prd.json)"
    echo ""
    read -p "Choose [1/2]: " task_choice
    
    case $task_choice in
        1)
            MODE="github"
            # Try to detect repo from git remote
            DETECTED_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]([^/]+/[^/]+)(\.git)?$|\1|' || echo "")
            if [ -n "$DETECTED_REPO" ]; then
                read -p "GitHub repo [$DETECTED_REPO]: " REPO
                [ -z "$REPO" ] && REPO="$DETECTED_REPO"
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
            echo "Invalid choice"
            exit 1
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
        *)
            echo "Invalid choice"
            exit 1
            ;;
    esac
    
    echo ""
    save_config
    echo ""
}

show_usage() {
    echo "Usage: ralph-once.sh [options] [<owner/repo> | --prd <file>]"
    echo ""
    echo "If no arguments are provided and no config exists, Ralph will"
    echo "interactively ask for your preferences and save them."
    echo ""
    echo "Options:"
    echo "  --pr       Raise a PR and wait for checks"
    echo "  --main     Commit directly to main branch and push"
    echo "  --commit   Commit to main but don't push"
    echo "  --branch   Create a branch and commit (no push)"
    echo "  --none     Don't commit, leave files unstaged"
    echo "  --setup    Force interactive setup (overwrites existing config)"
    echo ""
    echo "Examples:"
    echo "  ralph-once.sh                          # Use saved config or run setup"
    echo "  ralph-once.sh myorg/myproject          # GitHub issues mode"
    echo "  ralph-once.sh --prd ./tasks/prd.json   # PRD file mode"
    echo "  ralph-once.sh --setup                  # Re-run interactive setup"
}

# ============================================================
# ARGUMENT PARSING
# ============================================================
FORCE_SETUP=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --prd)
            MODE="prd"
            PRD_FILE="$2"
            shift 2
            ;;
        --main)
            COMMIT_MODE="main"
            shift
            ;;
        --pr)
            COMMIT_MODE="pr"
            shift
            ;;
        --commit)
            COMMIT_MODE="commit"
            shift
            ;;
        --branch)
            COMMIT_MODE="branch"
            shift
            ;;
        --none)
            COMMIT_MODE="none"
            shift
            ;;
        --setup)
            FORCE_SETUP=true
            shift
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
        *)
            if [ -z "$REPO" ]; then
                MODE="github"
                REPO="$1"
            fi
            shift
            ;;
    esac
done

# Verify we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

# ============================================================
# CONFIG LOADING / INTERACTIVE SETUP
# ============================================================
if [ "$FORCE_SETUP" = true ]; then
    interactive_setup
elif [ -z "$MODE" ]; then
    # No mode specified via args, try to load config
    if load_config && [ -n "$MODE" ]; then
        echo "Loaded config from $CONFIG_FILE"
    else
        # No config exists, run interactive setup
        interactive_setup
    fi
fi

# Apply defaults if still missing
[ -z "$COMMIT_MODE" ] && COMMIT_MODE="pr"

# ============================================================
# VALIDATION
# ============================================================
# GitHub mode: verify repo matches
if [ "$MODE" = "github" ]; then
    if [ -z "$REPO" ]; then
        echo "Error: No repository specified"
        exit 1
    fi
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ ! "$REMOTE_URL" =~ "$REPO" ]]; then
        echo "Error: Current directory doesn't appear to be a clone of $REPO"
        echo "Remote URL: $REMOTE_URL"
        exit 1
    fi
fi

# PRD mode: verify file exists
if [ "$MODE" = "prd" ]; then
    if [ -z "$PRD_FILE" ]; then
        echo "Error: No PRD file specified"
        exit 1
    fi
    if [ ! -f "$PRD_FILE" ]; then
        echo "Error: PRD file not found: $PRD_FILE"
        exit 1
    fi
fi

# Get the default branch and ensure we're on latest
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
echo "Checking out $DEFAULT_BRANCH and pulling latest..."
git checkout "$DEFAULT_BRANCH"
git pull origin "$DEFAULT_BRANCH"

# Ensure progress.txt exists
touch progress.txt
PROGRESS=$(cat progress.txt)

# ============================================================
# BUILD PROMPT SECTIONS
# ============================================================

# --- TASK CONTEXT: What tasks are available ---
if [ "$MODE" = "prd" ]; then
    PRD_CONTENT=$(cat "$PRD_FILE")
    PRD_NAME=$(echo "$PRD_CONTENT" | jq -r '.name // "Unknown Project"')
    PRD_BRANCH=$(echo "$PRD_CONTENT" | jq -r '.branchName // ""')
    [ "$PRD_BRANCH" = "null" ] && PRD_BRANCH=""
    
    echo "Working on PRD: $PRD_NAME"
    echo "PRD file: $PRD_FILE"
    
    TASK_CONTEXT="You are working on: $PRD_NAME

Here is the PRD file ($PRD_FILE):

$PRD_CONTENT"
    TASK_ITEM="task"
else
    echo "Working on repo: $REPO"
    
    # Fetch open issues from the repo
    if ! ISSUES=$(gh issue list --repo "$REPO" --state open --limit 20 --json number,title,body,labels); then
        echo "Error: Failed to fetch issues from $REPO"
        exit 1
    fi
    
    if [ -z "$ISSUES" ] || [ "$ISSUES" = "[]" ]; then
        echo "No open issues found in $REPO"
        exit 0
    fi
    
    TASK_CONTEXT="Here are the open GitHub issues for $REPO:

$ISSUES"
    TASK_ITEM="issue"
fi

echo "Commit mode: $COMMIT_MODE"

# --- SELECTION: How to choose the next task ---
if [ "$MODE" = "prd" ]; then
    SELECTION_INSTRUCTIONS="1. Review the userStories in the PRD. Tasks with \"passes\": false are incomplete.
2. Find the next task to work on:
   - Pick an incomplete task (passes: false) whose dependencies (dependsOn) are all complete
   - Prefer lower priority numbers (priority 1 before priority 2)
   - If multiple tasks qualify, pick the one with the lowest ID"
else
    SELECTION_INSTRUCTIONS="1. Review the issues and progress file.
2. Find the next issue to work on (pick the lowest numbered issue not marked as done in progress.txt)."
fi

# --- IMPLEMENTATION: Core work steps (same for both modes) ---
IMPLEMENTATION_INSTRUCTIONS="3. Implement the changes needed to complete the $TASK_ITEM.
4. Run the test suite and linter. Fix any failures or quality issues before proceeding."

# --- GAPS: How to record missing items ---
if [ "$MODE" = "prd" ]; then
    GAPS_INSTRUCTIONS="5. If you discover anything critically missing, note it in progress.txt (max 2 items)."
else
    GAPS_INSTRUCTIONS="5. If you discover anything critically missing, raise an issue for it (max 2 issues)."
fi

# --- COMMIT: How to save work ---
case "$COMMIT_MODE" in
    pr)
        COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, commit your changes with a well-written commit message following guidance in AGENTS.md
7. Raise a pull request with a title and description referencing the $TASK_ITEM, and share the link.
8. Wait for PR status checks to pass. If they fail, fix the issues and push again."
        ;;
    main)
        COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, commit your changes to main with a well-written commit message following guidance in AGENTS.md
7. Push your commit to origin."
        ;;
    commit)
        COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, commit your changes to main with a well-written commit message following guidance in AGENTS.md
7. Do NOT push - leave the commit local for review."
        ;;
    branch)
        if [ "$MODE" = "prd" ] && [ -n "$PRD_BRANCH" ]; then
            COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, create or switch to branch '$PRD_BRANCH' and commit your changes with a well-written commit message following guidance in AGENTS.md
7. Do NOT push - leave the branch local for review."
        else
            COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, create a new branch with a sensible name based on the $TASK_ITEM (e.g., feature/123-$TASK_ITEM-title) and commit your changes with a well-written commit message following guidance in AGENTS.md
7. Do NOT push - leave the branch local for review."
        fi
        ;;
    none)
        COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, leave all files unstaged. Do NOT commit or push anything.
7. Report what files were changed so they can be reviewed."
        ;;
esac

# --- COMPLETION: How to finish up ---
if [ "$MODE" = "prd" ]; then
    COMPLETION_INSTRUCTIONS="9. Update progress.txt with what you did, including the task ID.
10. Update the PRD file ($PRD_FILE): set \"passes\": true and add \"completionNotes\" for the task you completed.
11. Output: <promise>COMPLETE</promise>
ONLY DO ONE TASK AT A TIME."
else
    COMPLETION_INSTRUCTIONS="9. Update progress.txt with what you did, including the issue number.
10. Output: <promise>COMPLETE</promise>
ONLY DO ONE ISSUE AT A TIME."
fi

# ============================================================
# RUN OPENCODE WITH ASSEMBLED PROMPT
# ============================================================
opencode --prompt "
$TASK_CONTEXT

And here is the progress file (progress.txt):

$PROGRESS

$SELECTION_INSTRUCTIONS
$IMPLEMENTATION_INSTRUCTIONS
$GAPS_INSTRUCTIONS
$COMMIT_INSTRUCTIONS
$COMPLETION_INSTRUCTIONS"
