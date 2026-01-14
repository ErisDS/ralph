#!/bin/bash
set -e

MODE=""
REPO=""
PRD_FILE=""
COMMIT_MODE="pr"  # Default to PR mode

# Parse arguments
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
        -*)
            echo "Unknown option: $1"
            echo "Usage: ralph-once.sh [options] <owner/repo>"
            echo "       ralph-once.sh [options] --prd <path/to/prd.json>"
            echo ""
            echo "Options:"
            echo "  --pr     Raise a PR and wait for checks (default)"
            echo "  --main   Commit directly to main branch"
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

if [ -z "$MODE" ]; then
    echo "Usage: ralph-once.sh [options] <owner/repo>"
    echo "       ralph-once.sh [options] --prd <path/to/prd.json>"
    echo ""
    echo "Options:"
    echo "  --pr     Raise a PR and wait for checks (default)"
    echo "  --main   Commit directly to main branch"
    echo ""
    echo "Examples:"
    echo "  ralph-once.sh myorg/myproject"
    echo "  ralph-once.sh --main myorg/myproject"
    echo "  ralph-once.sh --prd ./tasks/prd.json"
    echo "  ralph-once.sh --main --prd ./tasks/prd.json"
    exit 1
fi

# Verify we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

# GitHub mode: verify repo matches
if [ "$MODE" = "github" ]; then
    REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ ! "$REMOTE_URL" =~ "$REPO" ]]; then
        echo "Error: Current directory doesn't appear to be a clone of $REPO"
        echo "Remote URL: $REMOTE_URL"
        exit 1
    fi
fi

# PRD mode: verify file exists
if [ "$MODE" = "prd" ]; then
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
# PRD MODE
# ============================================================
if [ "$MODE" = "prd" ]; then
    PRD_CONTENT=$(cat "$PRD_FILE")
    PRD_NAME=$(echo "$PRD_CONTENT" | jq -r '.name // "Unknown Project"')
    
    echo "Working on PRD: $PRD_NAME"
    echo "PRD file: $PRD_FILE"
    echo "Commit mode: $COMMIT_MODE"
    
    if [ "$COMMIT_MODE" = "main" ]; then
        COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, commit your changes to main with a well-written commit message following guidance in AGENTS.md
7. Push your commit to origin."
    else
        COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, commit your changes with a well-written commit message following guidance in AGENTS.md
7. Raise a pull request with a title and description referencing the task, and share the link.
8. Wait for PR status checks to pass. If they fail, fix the issues and push again."
    fi
    
    opencode --prompt "
You are working on: $PRD_NAME

Here is the PRD file ($PRD_FILE):

$PRD_CONTENT

And here is the progress file (progress.txt):

$PROGRESS

1. Review the userStories in the PRD. Tasks with \"passes\": false are incomplete.
2. Find the next task to work on:
   - Pick an incomplete task (passes: false) whose dependencies (dependsOn) are all complete
   - Prefer lower priority numbers (priority 1 before priority 2)
   - If multiple tasks qualify, pick the one with the lowest ID
3. Implement the changes needed to satisfy the acceptance criteria.
4. Run the test suite and linter. Fix any failures or quality issues before proceeding.
5. If you discover anything critically missing, note it in progress.txt (max 2 items).
$COMMIT_INSTRUCTIONS
9. Update progress.txt with what you did, including the task ID.
10. Update the PRD file ($PRD_FILE): set \"passes\": true and add \"completionNotes\" for the task you completed.
11. Output: <promise>COMPLETE</promise>
ONLY DO ONE TASK AT A TIME."
    exit 0
fi

# ============================================================
# GITHUB MODE
# ============================================================
echo "Working on repo: $REPO"
echo "Commit mode: $COMMIT_MODE"

# Fetch open issues from the repo
if ! ISSUES=$(gh issue list --repo "$REPO" --state open --limit 20 --json number,title,body,labels); then
    echo "Error: Failed to fetch issues from $REPO"
    exit 1
fi

if [ -z "$ISSUES" ] || [ "$ISSUES" = "[]" ]; then
    echo "No open issues found in $REPO"
    exit 0
fi

if [ "$COMMIT_MODE" = "main" ]; then
    COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, commit your changes to main with a well-written commit message following guidance in AGENTS.md
7. Push your commit to origin."
else
    COMMIT_INSTRUCTIONS="6. ONLY when all checks are passing, commit your changes with a well-written commit message following guidance in AGENTS.md
7. Raise a pull request with a title and description referencing the issue, and share the link.
8. Wait for PR status checks to pass. If they fail, fix the issues and push again."
fi

opencode --prompt "
Here are the open GitHub issues for $REPO:

$ISSUES

And here is the progress file (progress.txt):

$PROGRESS

1. Review the issues and progress file.
2. Find the next issue to work on (pick the lowest numbered issue not marked as done in progress.txt).
3. Implement the changes needed to resolve the issue.
4. Run the test suite and linter. Fix any failures or quality issues before proceeding.
5. If you discover anything critically missing, raise an issue for it (max 2 issues).
$COMMIT_INSTRUCTIONS
9. Update progress.txt with what you did, including the issue number.
10. Output: <promise>COMPLETE</promise>
ONLY DO ONE ISSUE AT A TIME."
