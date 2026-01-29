#!/bin/bash
set -e

# ============================================================
# Ralph Entrypoint (Docker)
# Runs inside containers to execute AI agent tasks
# Reads configuration from /workspace/.ralph/config.json
# ============================================================

CONFIG_FILE="/workspace/.ralph/config.json"
PROJECT_PROMPT_FILE="/ralph/prompt.md"
DEFAULT_TEMPLATE="/usr/local/share/ralph/prompt-template.md"

normalize_repo() {
    echo "$1" | sed -E 's|^https?://||; s|.*github\.com[:/]||; s|\.git$||; s|/$||'
}

# ============================================================
# Read Configuration
# ============================================================
if [ -f "$CONFIG_FILE" ]; then
    echo "Using config: $CONFIG_FILE"
else
    echo "Error: Configuration file not found: /workspace/.ralph/config.json"
    exit 1
fi

MODE=$(jq -r '.mode // ""' "$CONFIG_FILE")
PRD_FILE=$(jq -r '.prdFile // ""' "$CONFIG_FILE")
COMMIT_MODE=$(jq -r '.commitMode // ""' "$CONFIG_FILE")
AGENT_CLI=$(jq -r 'if (.agent|type) == "string" then .agent elif (.agent.cli|type) == "string" then .agent.cli else "" end' "$CONFIG_FILE")
AGENT_REVIEW=$(jq -r 'if (.agentReview|type) == "string" then .agentReview elif (.agent.review|type) == "string" then .agent.review else "" end' "$CONFIG_FILE")
GIT_USER=$(jq -r '.git.user // "Ralph Bot"' "$CONFIG_FILE")
GIT_EMAIL=$(jq -r '.git.email // "ralph@example.com"' "$CONFIG_FILE")
MODEL=$(jq -r '.agent.model // "anthropic/claude-sonnet-4-20250514"' "$CONFIG_FILE")

REPO_RAW=$(jq -r 'if (.repo|type) == "string" then .repo elif (.repo.owner and .repo.name) then "\(.repo.owner)/\(.repo.name)" elif (.repo.url and (.repo.url|type) == "string") then .repo.url else "" end' "$CONFIG_FILE")
REPO=""
if [ -n "$REPO_RAW" ]; then
    REPO=$(normalize_repo "$REPO_RAW")
fi

# Notification settings
NOTIFY_WEBHOOK=$(jq -r '.notifications.webhook // ""' "$CONFIG_FILE")
NOTIFY_NTFY=$(jq -r '.notifications.ntfy // ""' "$CONFIG_FILE")
NOTIFY_ON_SUCCESS=$(jq -r '.notifications.onSuccess // true' "$CONFIG_FILE")
NOTIFY_ON_FAILURE=$(jq -r '.notifications.onFailure // true' "$CONFIG_FILE")

MODE=${MODE:-github}
PRD_FILE=${PRD_FILE:-./prd.json}
COMMIT_MODE=${COMMIT_MODE:-pr}
AGENT_CLI=${AGENT_CLI:-opencode}

TASK_ID="${RALPH_TASK_ID:-}"

# ============================================================
# Argument Parsing
# ============================================================
SPECIFIC_TASK=""
CUSTOM_PROMPT=""
OVERRIDE_MODE=""
OVERRIDE_PRD_FILE=""

show_usage() {
    cat << 'EOF'
Usage: entrypoint.sh [OPTIONS]

Options:
  --issue <number>     Work on a specific GitHub issue
  --task <number>      Alias for --issue
  --prd <file>         Use PRD mode with the given PRD file
  --prompt <text>      Use a custom prompt instead of auto task selection
  -h, --help           Show this help message

Environment variables:
  GITHUB_TOKEN         Required for gh CLI and pushing
  ANTHROPIC_API_KEY    Required for opencode with Anthropic models

If no options are provided, Ralph will choose its own task based on config.json.
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --issue|--task)
            OVERRIDE_MODE="github"
            SPECIFIC_TASK="$2"
            shift 2
            ;;
        --prd)
            OVERRIDE_MODE="prd"
            OVERRIDE_PRD_FILE="$2"
            shift 2
            ;;
        --prompt)
            OVERRIDE_MODE="prompt"
            CUSTOM_PROMPT="$2"
            shift 2
            ;;
        -h|--help)
            show_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            exit 1
            ;;
    esac
done

if [ -n "$OVERRIDE_MODE" ]; then
    MODE="$OVERRIDE_MODE"
fi

if [ -n "$OVERRIDE_PRD_FILE" ]; then
    PRD_FILE="$OVERRIDE_PRD_FILE"
fi

# ============================================================
# Validation
# ============================================================
case "$MODE" in
    github|prd|prompt) ;;
    *)
        echo "Error: Unknown mode '$MODE'"
        exit 1
        ;;
esac

case "$COMMIT_MODE" in
    pr|main|commit|branch|none) ;;
    *)
        echo "Error: Unknown commit mode '$COMMIT_MODE'"
        exit 1
        ;;
esac

if [ "$MODE" = "prompt" ] && [ -z "$CUSTOM_PROMPT" ]; then
    echo "Error: --prompt requires text"
    exit 1
fi

if [ "$MODE" = "github" ] && [ -z "$REPO" ]; then
    echo "Error: repo must be set in .ralph/config.json for GitHub mode"
    exit 1
fi

# ============================================================
# Environment Validation
# ============================================================
check_dependency() {
    command -v "$1" > /dev/null 2>&1 || { echo "Error: '$1' is required but not installed."; exit 1; }
}

check_dependency git
check_dependency jq

# ============================================================
# Notification Functions
# ============================================================
send_notification() {
    local status="$1"    # success or failure
    local title="$2"
    local message="$3"
    
    # Check if we should send based on status
    if [ "$status" = "success" ] && [ "$NOTIFY_ON_SUCCESS" != "true" ]; then
        return 0
    fi
    if [ "$status" = "failure" ] && [ "$NOTIFY_ON_FAILURE" != "true" ]; then
        return 0
    fi
    
    # Send to custom webhook (generic JSON POST)
    if [ -n "$NOTIFY_WEBHOOK" ]; then
        echo "Sending webhook notification..."
        curl -s -X POST "$NOTIFY_WEBHOOK" \
            -H "Content-Type: application/json" \
            -d "{\"status\":\"$status\",\"title\":\"$title\",\"message\":\"$message\",\"task\":\"$TASK_ID\",\"repo\":\"$REPO\"}" \
            || echo "Warning: Webhook notification failed"
    fi
    
    # Send to ntfy.sh (or self-hosted ntfy)
    if [ -n "$NOTIFY_NTFY" ]; then
        echo "Sending ntfy notification..."
        local priority="default"
        local tags="robot"
        if [ "$status" = "success" ]; then
            tags="white_check_mark,robot"
        else
            tags="x,robot"
            priority="high"
        fi
        
        curl -s -X POST "$NOTIFY_NTFY" \
            -H "Title: $title" \
            -H "Priority: $priority" \
            -H "Tags: $tags" \
            -d "$message" \
            || echo "Warning: ntfy notification failed"
    fi
}

if [ "$MODE" = "github" ]; then
    check_dependency gh
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "Error: GITHUB_TOKEN environment variable is required for GitHub mode"
        exit 1
    fi

    echo "Verifying GitHub CLI authentication..."
    if ! gh auth status &>/dev/null; then
        echo "Error: GitHub CLI authentication failed"
        exit 1
    fi
    echo "GitHub CLI authenticated successfully"
else
    if [ -z "$GITHUB_TOKEN" ]; then
        echo "Warning: GITHUB_TOKEN not set. Pushing or PR creation may fail."
    else
        gh auth status &>/dev/null || echo "Warning: GitHub CLI authentication failed"
    fi
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "Warning: No ANTHROPIC_API_KEY set"
    echo "opencode may fail to authenticate with Anthropic"
fi

# ============================================================
# Setup opencode config
# ============================================================
echo "Setting up opencode configuration..."
mkdir -p "$HOME/.config/opencode"

# Copy host's global opencode config file only (not plugins - they may not work in container)
HOST_OPENCODE_DIR="/home/ralph/.config/opencode-host"
if [ -f "$HOST_OPENCODE_DIR/opencode.json" ]; then
    cp "$HOST_OPENCODE_DIR/opencode.json" "$HOME/.config/opencode/" || true
fi

# If no global config exists, create a minimal default
if [ ! -f "$HOME/.config/opencode/opencode.json" ]; then
    cat > "$HOME/.config/opencode/opencode.json" << EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$MODEL"
}
EOF
fi

# ============================================================
# Update Repository
# ============================================================
cd /workspace

git config user.name "$GIT_USER"
git config user.email "$GIT_EMAIL"

if [ -n "$GITHUB_TOKEN" ]; then
    git config url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"
fi

echo "Fetching latest changes..."
git fetch origin

DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
echo "Checking out $DEFAULT_BRANCH and pulling latest..."
git checkout "$DEFAULT_BRANCH"
git pull origin "$DEFAULT_BRANCH"

# ============================================================
# Progress Context
# ============================================================
if [ "$MODE" = "prd" ]; then
    touch progress.txt
    PROGRESS=$(cat progress.txt)
else
    PROGRESS=$(git log --oneline -10 2>/dev/null || echo "No commits yet")
fi

# ============================================================
# Build Prompt Sections
# ============================================================
fetch_prd_tasks() {
    [ -f "$PRD_FILE" ] || { echo "Error: PRD file not found: $PRD_FILE"; exit 1; }

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

    PRE_COMMIT_EXTRA="Also update the PRD file ($PRD_FILE): set \"passes\": true and add \"completionNotes\" for the task you completed."
    TASK_ITEM="task"
}

fetch_github_tasks() {
    echo "Working on repo: $REPO"

    IS_EPIC=""

    if [ -n "$SPECIFIC_TASK" ]; then
        PARENT_ISSUE=$(gh issue view "$SPECIFIC_TASK" --repo "$REPO" --json number,title,body,labels 2>/dev/null) || {
            echo "Error: Failed to fetch issue #$SPECIFIC_TASK from $REPO"; exit 1
        }

        PARENT_BODY=$(echo "$PARENT_ISSUE" | jq -r '.body // ""')
        SUB_ISSUE_NUMBERS=$(echo "$PARENT_BODY" | grep -oE '\- \[ \] (#[0-9]+|https://github\.com/[^/]+/[^/]+/issues/[0-9]+)' | grep -oE '[0-9]+$' | head -20)

        if [ -n "$SUB_ISSUE_NUMBERS" ]; then
            echo "Issue #$SPECIFIC_TASK is an epic, fetching sub-issues..."
            ISSUES="["
            FIRST=true
            for NUM in $SUB_ISSUE_NUMBERS; do
                SUB_ISSUE=$(gh issue view "$NUM" --repo "$REPO" --json number,title,body,labels,state 2>/dev/null)
                if [ -n "$SUB_ISSUE" ]; then
                    STATE=$(echo "$SUB_ISSUE" | jq -r '.state')
                    if [ "$STATE" = "OPEN" ]; then
                        [ "$FIRST" = true ] && FIRST=false || ISSUES="$ISSUES,"
                        ISSUES="$ISSUES$SUB_ISSUE"
                    fi
                fi
            done
            ISSUES="$ISSUES]"

            PARENT_TITLE=$(echo "$PARENT_ISSUE" | jq -r '.title')
            IS_EPIC=true
        fi
    fi

    if [ -z "$IS_EPIC" ]; then
        ISSUES=$(gh issue list --repo "$REPO" --state open --limit 20 --json number,title,body,labels) || {
            echo "Error: Failed to fetch issues from $REPO"; exit 1
        }
        ISSUES=$(echo "$ISSUES" | jq '[.[] | select(.title | contains("Dependency Dashboard") | not)]')
    fi

    [ -z "$ISSUES" ] || [ "$ISSUES" = "[]" ] && { echo "No open issues found in $REPO"; exit 0; }

    if [ "$IS_EPIC" = true ]; then
        TASK_CONTEXT="You are working on epic #$SPECIFIC_TASK: $PARENT_TITLE

Here are the open sub-issues for this epic:

$ISSUES"
        SPECIFIC_TASK=""
    else
        TASK_CONTEXT="Here are the open GitHub issues for $REPO:

$ISSUES"
    fi

    PRE_COMMIT_EXTRA=""
    TASK_ITEM="issue"
}

fetch_prompt_task() {
    TASK_CONTEXT="You are working on a custom task:

$CUSTOM_PROMPT"
    PRE_COMMIT_EXTRA=""
    TASK_ITEM="task"
}

case "$MODE" in
    prd)    fetch_prd_tasks ;;
    github) fetch_github_tasks ;;
    prompt) fetch_prompt_task ;;
esac

echo "Commit mode: $COMMIT_MODE"
echo "Agent: $AGENT_CLI"

# ============================================================
# Build Dynamic Prompt Sections (shared with ralph-once.sh)
# ============================================================

# --- Task selection instruction (only when --task is specified) ---
if [ "$MODE" = "prompt" ]; then
    SPECIFIC_TASK_INSTRUCTION="**Work on the custom task described above. Do NOT pick a different task.**

"
elif [ -n "$SPECIFIC_TASK" ]; then
    SPECIFIC_TASK_INSTRUCTION="**Work on $TASK_ITEM #$SPECIFIC_TASK specifically. Do NOT pick a different $TASK_ITEM.**

"
    echo "Targeting specific $TASK_ITEM: #$SPECIFIC_TASK"
else
    SPECIFIC_TASK_INSTRUCTION=""
fi

# --- Progress header (PRD vs GitHub) ---
if [ "$MODE" = "prd" ]; then
    PROGRESS_HEADER="## Progress So Far"
    PROGRESS_CHECKLIST_ITEM="- [ ] progress.txt is updated with what you did"
    PRE_COMMIT_EXTRA_ITEM="- [ ] Update the PRD file ($PRD_FILE): set \"passes\": true and add \"completionNotes\" for the task you completed"
    STAGE_INSTRUCTION="Stage ALL modified files (including progress.txt and any PRD files)"
else
    PROGRESS_HEADER="## Recent Commits"
    PROGRESS_CHECKLIST_ITEM="- [ ] Your commit message clearly describes what was done and why"
    PRE_COMMIT_EXTRA_ITEM=""
    STAGE_INSTRUCTION="Stage all modified files"
fi

# --- Delivery steps (based on commit mode) ---
if [ "$COMMIT_MODE" = "pr" ]; then
    DELIVER_STEPS="1. Create a feature branch (e.g., feature/123-short-description)
2. $STAGE_INSTRUCTION
3. Commit with a clear message following AGENTS.md guidance
4. Push and open a pull request referencing the $TASK_ITEM
5. Wait for CI/status checks to pass - if they fail, fix and push again"
else
    case "$COMMIT_MODE" in
        main)
            DELIVER_STEPS="1. $STAGE_INSTRUCTION
2. Commit to main with a clear message following AGENTS.md guidance
3. Push to origin"
            ;;
        commit)
            DELIVER_STEPS="1. $STAGE_INSTRUCTION
2. Commit to main with a clear message following AGENTS.md guidance
3. Do NOT push - leave the commit local for review"
            ;;
        branch)
            if [ "$MODE" = "prd" ] && [ -n "$PRD_BRANCH" ]; then
                DELIVER_STEPS="1. Create or switch to branch '$PRD_BRANCH'
2. $STAGE_INSTRUCTION
3. Commit with a clear message following AGENTS.md guidance
4. Do NOT push - leave the branch local for review"
            else
                DELIVER_STEPS="1. Create a branch (e.g., feature/123-$TASK_ITEM-title)
2. $STAGE_INSTRUCTION
3. Commit with a clear message following AGENTS.md guidance
4. Do NOT push - leave the branch local for review"
            fi
            ;;
        none)
            DELIVER_STEPS="1. Do NOT commit or push anything
2. Report what files were changed so they can be reviewed"
            ;;
    esac
fi

# --- Code review section (only for PR mode with copilot) ---
SECTION_REVIEW=""
if [ "$COMMIT_MODE" = "pr" ] && [ "$AGENT_REVIEW" = "copilot" ]; then
    SECTION_REVIEW="## 5. Code Review

After opening the PR, you must get approval from GitHub Copilot code review.

### Review Loop

1. **Wait for Copilot review** - Copilot will automatically review your PR
2. **Address ALL comments** - For each comment:
   - Use your judgement to assess whether to fix the issue or not
   - Reply directly to the comment explaining the fix or reason for not fixing
   - Mark the comment as resolved
3. **Request re-review** - After addressing all comments, request a new review:
   \`\`\`bash
   gh api -X POST repos/{owner}/{repo}/pulls/{PR_NUMBER}/requested_reviewers \\
     -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
   \`\`\`
   Note: \`gh pr edit --add-reviewer Copilot\` does not reliably trigger re-review. Use the API call.
4. **Iterate** - Repeat this loop until:
   - Copilot marks the review as **APPROVED**, or
   - Copilot comments with \"no further comments\"

**Do not stop early. Keep going until fully approved.**

---

"
fi

# --- Project instructions (Docker only, from ralph/prompt.md) ---
PROJECT_INSTRUCTIONS=""
if [ -s "$PROJECT_PROMPT_FILE" ]; then
    PROJECT_INSTRUCTIONS="## Project Instructions

$(cat "$PROJECT_PROMPT_FILE")

---

"
fi

# ============================================================
# Assemble Final Prompt from Template
# ============================================================

# Template lookup: project override > default
if [ -f "/workspace/.ralph/prompt-once.md" ]; then
    TEMPLATE_PATH="/workspace/.ralph/prompt-once.md"
elif [ -f "$DEFAULT_TEMPLATE" ]; then
    TEMPLATE_PATH="$DEFAULT_TEMPLATE"
else
    echo "Error: No prompt template found"
    exit 1
fi

# Read template and strip documentation block
PROMPT_TEMPLATE=$(sed '/<!-- TEMPLATE_DOCS_START -->/,/<!-- TEMPLATE_DOCS_END -->/d' "$TEMPLATE_PATH")

# Replace placeholders
PROMPT="$PROMPT_TEMPLATE"
PROMPT="${PROMPT//\{\{TASK_CONTEXT\}\}/$TASK_CONTEXT}"
PROMPT="${PROMPT//\{\{TASK_ITEM\}\}/$TASK_ITEM}"
PROMPT="${PROMPT//\{\{PROGRESS_HEADER\}\}/$PROGRESS_HEADER}"
PROMPT="${PROMPT//\{\{PROGRESS\}\}/$PROGRESS}"
PROMPT="${PROMPT//\{\{SPECIFIC_TASK_INSTRUCTION\}\}/$SPECIFIC_TASK_INSTRUCTION}"
PROMPT="${PROMPT//\{\{PROGRESS_CHECKLIST_ITEM\}\}/$PROGRESS_CHECKLIST_ITEM}"
PROMPT="${PROMPT//\{\{PRE_COMMIT_EXTRA_ITEM\}\}/$PRE_COMMIT_EXTRA_ITEM}"
PROMPT="${PROMPT//\{\{DELIVER_STEPS\}\}/$DELIVER_STEPS}"
PROMPT="${PROMPT//\{\{SECTION_REVIEW\}\}/$SECTION_REVIEW}"
PROMPT="${PROMPT//\{\{PROJECT_INSTRUCTIONS\}\}/$PROJECT_INSTRUCTIONS}"

check_dependency "$AGENT_CLI"

# ============================================================
# Run Agent and Capture Result
# ============================================================
AGENT_EXIT_CODE=0
case "$AGENT_CLI" in
    opencode) opencode run "$PROMPT" || AGENT_EXIT_CODE=$? ;;
    claude)   claude "$PROMPT" || AGENT_EXIT_CODE=$? ;;
    *)        echo "Error: Unknown agent '$AGENT_CLI'"; exit 1 ;;
esac

# ============================================================
# Send Completion Notification
# ============================================================
PROJECT_NAME=$(basename "$REPO" 2>/dev/null || echo "project")
TASK_DISPLAY="${TASK_ID:-auto}"

if [ "$AGENT_EXIT_CODE" -eq 0 ]; then
    echo ""
    echo "Agent completed successfully"
    send_notification "success" \
        "Ralph: $PROJECT_NAME done" \
        "Task $TASK_DISPLAY completed successfully"
else
    echo ""
    echo "Agent exited with code $AGENT_EXIT_CODE"
    send_notification "failure" \
        "Ralph: $PROJECT_NAME failed" \
        "Task $TASK_DISPLAY failed (exit code $AGENT_EXIT_CODE)"
fi

# ============================================================
# Keep Container Alive for Interactive Follow-up
# ============================================================
echo ""
echo "=============================================="
echo "Container staying alive for follow-up work"
echo "=============================================="
echo ""
echo "To continue working with this agent:"
if [ -n "$TASK_ID" ]; then
    echo "  ralph.sh attach $TASK_ID"
else
    echo "  ralph.sh list"
fi
echo ""
echo "To stop this container:"
if [ -n "$TASK_ID" ]; then
    echo "  ralph.sh stop $TASK_ID"
else
    echo "  ralph.sh stop --all"
fi
echo ""
echo "Waiting for attach or stop signal..."

exec tail -f /dev/null
