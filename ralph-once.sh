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
    PR_RULES=$(json_value '.prRules')
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    # Build JSON, omitting empty optional fields
    local json="{"
    json="$json\n  \"mode\": \"$MODE\","
    json="$json\n  \"commitMode\": \"$COMMIT_MODE\","
    [ -n "$REPO" ] && json="$json\n  \"repo\": \"$REPO\","
    [ -n "$PRD_FILE" ] && json="$json\n  \"prdFile\": \"$PRD_FILE\","
    [ -n "$PR_RULES" ] && json="$json\n  \"prRules\": \"$PR_RULES\","
    json="$json\n  \"agent\": \"$AGENT\""
    json="$json\n}"
    echo -e "$json" > "$CONFIG_FILE"
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
    
    if [ "$COMMIT_MODE" = "pr" ]; then
        echo ""
        echo "Any extra rules for PR review? (e.g., 'Wait for review from @alice', 'Ensure deploy preview is green')"
        read -p "PR rules (leave blank for none): " PR_RULES
    fi
    
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
  --task <n>      Work on a specific task/issue number
  --issue <n>     Alias for --task
  --pr            Raise a PR and wait for checks
  --pr-rules <s>  Extra rules for PR mode (e.g., "Wait for review from @alice")
  --main          Commit directly to main branch and push
  --commit        Commit to main but don't push
  --branch        Create a branch and commit (no push)
  --none          Don't commit, leave files unstaged
  --opencode      Use opencode as the AI agent (default)
  --claude        Use claude as the AI agent
  --setup         Force interactive setup (overwrites existing config)

Examples:
  ralph-once.sh                          # Use saved config or run setup
  ralph-once.sh myorg/myproject          # GitHub issues mode
  ralph-once.sh --prd ./tasks/prd.json   # PRD file mode
  ralph-once.sh --claude --prd ./prd.json # Use claude with PRD
  ralph-once.sh --setup                  # Re-run interactive setup
  ralph-once.sh --task 42                # Work on task/issue #42
  ralph-once.sh --issue 15 myorg/repo    # Work on issue #15 from repo
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
PR_RULES=""
FORCE_SETUP=false
SPECIFIC_TASK=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --prd)         MODE="prd"; PRD_FILE="$2"; shift 2 ;;
        --task|--issue) SPECIFIC_TASK="$2"; shift 2 ;;
        --pr)          COMMIT_MODE="pr"; shift ;;
        --pr-rules)    PR_RULES="$2"; shift 2 ;;
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
FLAG_PR_RULES="$PR_RULES"

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
[ -n "$FLAG_PR_RULES" ] && PR_RULES="$FLAG_PR_RULES"

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

    # Used to build pre-commit instructions - includes PRD-specific updates
    PRE_COMMIT_EXTRA="Also update the PRD file ($PRD_FILE): set \"passes\": true and add \"completionNotes\" for the task you completed."

    COMPLETION_INSTRUCTIONS="Output: <promise>COMPLETE</promise>
ONLY DO ONE TASK AT A TIME."

    TASK_ITEM="task"
}

fetch_github_tasks() {
    echo "Working on repo: $REPO"
    
    # Check if a specific issue was requested and if it's an epic (has sub-issues)
    if [ -n "$SPECIFIC_TASK" ]; then
        PARENT_ISSUE=$(gh issue view "$SPECIFIC_TASK" --repo "$REPO" --json number,title,body,labels 2>/dev/null) || {
            echo "Error: Failed to fetch issue #$SPECIFIC_TASK from $REPO"; exit 1
        }
        
        # Check if this issue has sub-issues (tasklist items like "- [ ] #123" or "- [ ] https://github.com/.../issues/123")
        PARENT_BODY=$(echo "$PARENT_ISSUE" | jq -r '.body // ""')
        SUB_ISSUE_NUMBERS=$(echo "$PARENT_BODY" | grep -oE '\- \[ \] (#[0-9]+|https://github\.com/[^/]+/[^/]+/issues/[0-9]+)' | grep -oE '[0-9]+$' | head -20)
        
        if [ -n "$SUB_ISSUE_NUMBERS" ]; then
            # This is an epic - fetch the sub-issues
            echo "Issue #$SPECIFIC_TASK is an epic, fetching sub-issues..."
            ISSUES="["
            FIRST=true
            for NUM in $SUB_ISSUE_NUMBERS; do
                SUB_ISSUE=$(gh issue view "$NUM" --repo "$REPO" --json number,title,body,labels,state 2>/dev/null)
                if [ -n "$SUB_ISSUE" ]; then
                    # Only include open issues
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
    
    # If not an epic or no specific task, fetch regular issues
    if [ -z "$IS_EPIC" ]; then
        ISSUES=$(gh issue list --repo "$REPO" --state open --limit 20 --json number,title,body,labels) || {
            echo "Error: Failed to fetch issues from $REPO"; exit 1
        }
        
        # Filter out Renovate's Dependency Dashboard issue
        ISSUES=$(echo "$ISSUES" | jq '[.[] | select(.title | contains("Dependency Dashboard") | not)]')
    fi
    
    [ -z "$ISSUES" ] || [ "$ISSUES" = "[]" ] && { echo "No open issues found in $REPO"; exit 0; }
    
    if [ "$IS_EPIC" = true ]; then
        TASK_CONTEXT="You are working on epic #$SPECIFIC_TASK: $PARENT_TITLE

Here are the open sub-issues for this epic:

$ISSUES

Issues marked as done in progress.txt should not be worked on again."
        # Clear SPECIFIC_TASK so the agent picks from sub-issues
        SPECIFIC_TASK=""
    else
        TASK_CONTEXT="Here are the open GitHub issues for $REPO:

$ISSUES

Issues marked as done in progress.txt should not be worked on again."
    fi

    # No extra pre-commit instructions for GitHub mode
    PRE_COMMIT_EXTRA=""

    COMPLETION_INSTRUCTIONS="Output: <promise>COMPLETE</promise>
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
if [ -n "$SPECIFIC_TASK" ]; then
    SELECTION_INSTRUCTIONS="1. Work on $TASK_ITEM #$SPECIFIC_TASK specifically.
2. Do NOT pick a different $TASK_ITEM - you must work on #$SPECIFIC_TASK."
    echo "Targeting specific $TASK_ITEM: #$SPECIFIC_TASK"
else
    SELECTION_INSTRUCTIONS="1. Review the available ${TASK_ITEM}s and the progress file.
2. Find the next $TASK_ITEM to work on:
   - Pick the lowest-numbered $TASK_ITEM that is available to be worked on
   - Use your judgment if one seems more urgent or foundational than others"
fi

# --- BUILD NUMBERED INSTRUCTIONS based on commit mode ---
# PR mode adds a branching step, shifting all subsequent numbers by 1
if [ "$COMMIT_MODE" = "pr" ]; then
    # PR mode: 1-2 select, 3 branch, 4 implement, 5-6 pre-commit, 7 PR, 8 wait, 9+ custom
    BRANCH_INSTRUCTIONS="3. Create a feature branch with a sensible name based on the $TASK_ITEM (e.g., feature/123-short-description) and switch to it."
    
    IMPLEMENTATION_INSTRUCTIONS="4. Implement the changes needed to complete the $TASK_ITEM, using feedback loops to verify your changes are working as intended (automated and manual testing)."
    
    PRE_COMMIT_INSTRUCTIONS="5. ONLY when you're absolutely certain your code is working as intended and all available automated checks are passing, update progress.txt with what you did, including the $TASK_ITEM number.${PRE_COMMIT_EXTRA:+ $PRE_COMMIT_EXTRA}
6. Stage ALL modified files (including progress.txt and any PRD files) and commit your changes with a well-written commit message following guidance in AGENTS.md"
    
    COMMIT_INSTRUCTIONS="7. Push your branch and raise a pull request with a title and description referencing the $TASK_ITEM, and share the link.
8. Wait for PR status checks to pass. If they fail, fix the issues and push again."
    [ -n "$PR_RULES" ] && COMMIT_INSTRUCTIONS="$COMMIT_INSTRUCTIONS
9. $PR_RULES"
else
    # Non-PR modes: 1-2 select, 3 implement, 4-5 pre-commit, 6 next step
    BRANCH_INSTRUCTIONS=""
    
    IMPLEMENTATION_INSTRUCTIONS="3. Implement the changes needed to complete the $TASK_ITEM, using feedback loops to verify your changes are working as intended (automated and manual testing)."
    
    PRE_COMMIT_INSTRUCTIONS="4. ONLY when you're absolutely certain your code is working as intended and all available automated checks are passing, update progress.txt with what you did, including the $TASK_ITEM number.${PRE_COMMIT_EXTRA:+ $PRE_COMMIT_EXTRA}
5. Stage ALL modified files (including progress.txt and any PRD files) and commit your changes with a well-written commit message following guidance in AGENTS.md"
    
    case "$COMMIT_MODE" in
        main)
            COMMIT_INSTRUCTIONS="6. Push your commit to origin."
            ;;
        commit)
            COMMIT_INSTRUCTIONS="6. Do NOT push - leave the commit local for review."
            ;;
        branch)
            if [ "$MODE" = "prd" ] && [ -n "$PRD_BRANCH" ]; then
                COMMIT_INSTRUCTIONS="5. Create or switch to branch '$PRD_BRANCH' and commit your changes with a well-written commit message following guidance in AGENTS.md
6. Do NOT push - leave the branch local for review."
            else
                COMMIT_INSTRUCTIONS="5. Create a new branch with a sensible name based on the $TASK_ITEM (e.g., feature/123-$TASK_ITEM-title) and commit your changes with a well-written commit message following guidance in AGENTS.md
6. Do NOT push - leave the branch local for review."
            fi
            ;;
        none)
            COMMIT_INSTRUCTIONS="6. Do NOT commit or push anything. Report what files were changed so they can be reviewed."
            ;;
    esac
fi

# ============================================================
# RUN AGENT
# ============================================================
PROMPT="
$TASK_CONTEXT

And here is the progress file (progress.txt):

$PROGRESS

$SELECTION_INSTRUCTIONS
$BRANCH_INSTRUCTIONS
$IMPLEMENTATION_INSTRUCTIONS
$PRE_COMMIT_INSTRUCTIONS
$COMMIT_INSTRUCTIONS
$COMPLETION_INSTRUCTIONS"

check_dependency "$AGENT"

case "$AGENT" in
    opencode) opencode --prompt "$PROMPT" ;;
    claude)   claude "$PROMPT" ;;
    *)        echo "Error: Unknown agent '$AGENT'"; exit 1 ;;
esac
