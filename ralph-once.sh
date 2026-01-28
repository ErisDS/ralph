#!/bin/bash
set -e

VERSION="1.0.0"
CONFIG_DIR=".ralph"
CONFIG_FILE="$CONFIG_DIR/config.json"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

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

    AGENT_REVIEW=$(json_value '.agentReview')
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    # Build JSON, omitting empty optional fields
    local json="{"
    json="$json\n  \"mode\": \"$MODE\","
    json="$json\n  \"commitMode\": \"$COMMIT_MODE\","
    [ -n "$REPO" ] && json="$json\n  \"repo\": \"$REPO\","
    [ -n "$PRD_FILE" ] && json="$json\n  \"prdFile\": \"$PRD_FILE\","

    [ -n "$AGENT_REVIEW" ] && json="$json\n  \"agentReview\": \"$AGENT_REVIEW\","
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
        echo "Should Ralph wait for an AI code reviewer?"
        echo "  1) None (default)"
        echo "  2) Copilot - Wait for GitHub Copilot review approval"
        echo ""
        read -p "Choose [1/2]: " review_choice
        
        case $review_choice in
            1|"") AGENT_REVIEW="" ;;
            2)    AGENT_REVIEW="copilot" ;;
            *)    echo "Invalid choice"; exit 1 ;;
        esac
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

  --copilot       Wait for GitHub Copilot code review approval
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

AGENT_REVIEW=""
FORCE_SETUP=false
SPECIFIC_TASK=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --prd)         MODE="prd"; PRD_FILE="$2"; shift 2 ;;
        --task|--issue) SPECIFIC_TASK="$2"; shift 2 ;;
        --pr)          COMMIT_MODE="pr"; shift ;;

        --copilot)     AGENT_REVIEW="copilot"; shift ;;
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

FLAG_AGENT_REVIEW="$AGENT_REVIEW"

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

[ -n "$FLAG_AGENT_REVIEW" ] && AGENT_REVIEW="$FLAG_AGENT_REVIEW"

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

# For PRD mode, use progress.txt; for GitHub mode, use recent commit history
if [ "$MODE" = "prd" ]; then
    touch progress.txt
    PROGRESS=$(cat progress.txt)
else
    PROGRESS=$(git log --oneline -10 2>/dev/null || echo "No commits yet")
fi

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

$ISSUES"
        # Clear SPECIFIC_TASK so the agent picks from sub-issues
        SPECIFIC_TASK=""
    else
        TASK_CONTEXT="Here are the open GitHub issues for $REPO:

$ISSUES"
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

# ============================================================
# BUILD STRUCTURED PROMPT
# ============================================================

# --- SECTION 1: CHOOSE THE TASK ---
if [ -n "$SPECIFIC_TASK" ]; then
    SECTION_CHOOSE="## 1. Choose the Task

Work on $TASK_ITEM #$SPECIFIC_TASK specifically. Do NOT pick a different $TASK_ITEM."
    echo "Targeting specific $TASK_ITEM: #$SPECIFIC_TASK"
elif [ "$MODE" = "prd" ]; then
    SECTION_CHOOSE="## 1. Choose the Task

Review the available ${TASK_ITEM}s and the progress file, then select ONE to work on:
- Pick the next best $TASK_ITEM to work on, prioritising as you see fit
- Fall back to the lowest-numbered $TASK_ITEM if priority isn't clear
- Skip any already marked done in progress.txt"
else
    SECTION_CHOOSE="## 1. Choose the Task

Review the available ${TASK_ITEM}s and the recent commit history, then select ONE to work on:
- Pick the next best $TASK_ITEM to work on, prioritising as you see fit
- Fall back to the lowest-numbered $TASK_ITEM if priority isn't clear"
fi

# --- SECTION 2: IMPLEMENT WITH FEEDBACK LOOPS ---
SECTION_IMPLEMENT="## 2. Implement the Task

Work through the $TASK_ITEM systematically, using ALL available feedback loops to ensure code works as intended and passes all checks.

### Available Feedback Loops
Use these to verify your changes are working:
- **Automated tests**: Run the test suite frequently as you make changes
- **Linter/Type checker**: Check for code quality issues and type errors  
- **Manual testing**: Test the actual behavior in a browser/terminal/REPL
- **Build**: Ensure the project compiles/builds without errors
- **AGENTS.md**: Check for project-specific standards, commands, and guidelines

### Implementation Approach
1. Understand the requirements fully before writing code
2. Make incremental changes, testing after each significant change
3. If tests exist, run them early and often
4. If no tests exist for your changes, consider adding them
5. Verify the fix/feature works manually, not just that tests pass
6. Keep iterating until you meet the Definition of Done"

# --- SECTION 3: DEFINITION OF DONE ---
# Progress tracking differs: PRD mode uses progress.txt, GitHub mode uses commit messages
if [ "$MODE" = "prd" ]; then
    PROGRESS_ITEM="- [ ] progress.txt is updated with what you did"
else
    PROGRESS_ITEM="- [ ] Your commit message clearly describes what was done and why"
fi

if [ "$COMMIT_MODE" = "pr" ]; then
    SECTION_DONE="## 3. Definition of Done

You are ONLY done when ALL of the following are true:
- [ ] All automated tests pass
- [ ] Linter/type checks pass (if available)
- [ ] You have manually verified the change works as intended
- [ ] Code follows project standards (check AGENTS.md)
$PROGRESS_ITEM
- [ ] If there are deployments, wait for them to succeed and re-verify your changes work${PRE_COMMIT_EXTRA:+
- [ ] $PRE_COMMIT_EXTRA}"
else
    SECTION_DONE="## 3. Definition of Done

You are ONLY done when ALL of the following are true:
- [ ] All automated tests pass
- [ ] Linter/type checks pass (if available)  
- [ ] You have manually verified the change works as intended
- [ ] Code follows project standards (check AGENTS.md)
$PROGRESS_ITEM
- [ ] If there are deployments, wait for them to succeed and re-verify your changes work${PRE_COMMIT_EXTRA:+
- [ ] $PRE_COMMIT_EXTRA}"
fi

# --- SECTION 4: DELIVER ---
# Stage instruction differs: PRD mode includes progress.txt, GitHub mode doesn't
if [ "$MODE" = "prd" ]; then
    STAGE_INSTRUCTION="Stage ALL modified files (including progress.txt and any PRD files)"
else
    STAGE_INSTRUCTION="Stage all modified files"
fi

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

SECTION_DELIVER="## 4. Deliver

ONLY after meeting ALL criteria in 'Definition of Done':

$DELIVER_STEPS"

# --- SECTION 5: CODE REVIEW (optional, only for PR mode with agent review) ---
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

**Do not stop early. Keep going until fully approved.**"
fi

# Adjust final completion message based on whether review is required
if [ -n "$SECTION_REVIEW" ]; then
    COMPLETION_MESSAGE="When the PR is approved and all checks pass, output: <promise>COMPLETE</promise>"
else
    COMPLETION_MESSAGE="When complete, output: <promise>COMPLETE</promise>"
fi

# ============================================================
# ASSEMBLE FINAL PROMPT
# ============================================================
if [ "$MODE" = "prd" ]; then
    PROGRESS_HEADER="## Progress So Far"
else
    PROGRESS_HEADER="## Recent Commits"
fi

if [ -n "$SECTION_REVIEW" ]; then
    SECTION_REVIEW_BLOCK="$SECTION_REVIEW

---"
else
    SECTION_REVIEW_BLOCK=""
fi

IMPORTANT_MESSAGE="**IMPORTANT**: Only work on ONE $TASK_ITEM."

TEMPLATE_PATH="$SCRIPT_DIR/templates/prompt-once.md"
if [ -f ".ralph/prompt-once.md" ]; then
    TEMPLATE_PATH=".ralph/prompt-once.md"
fi

PROMPT_TEMPLATE=$(cat "$TEMPLATE_PATH")
PROMPT="$PROMPT_TEMPLATE"
PROMPT="${PROMPT//\{\{TASK_CONTEXT\}\}/$TASK_CONTEXT}"
PROMPT="${PROMPT//\{\{PROGRESS_HEADER\}\}/$PROGRESS_HEADER}"
PROMPT="${PROMPT//\{\{PROGRESS\}\}/$PROGRESS}"
PROMPT="${PROMPT//\{\{SECTION_CHOOSE\}\}/$SECTION_CHOOSE}"
PROMPT="${PROMPT//\{\{SECTION_IMPLEMENT\}\}/$SECTION_IMPLEMENT}"
PROMPT="${PROMPT//\{\{SECTION_DONE\}\}/$SECTION_DONE}"
PROMPT="${PROMPT//\{\{SECTION_DELIVER\}\}/$SECTION_DELIVER}"
PROMPT="${PROMPT//\{\{SECTION_REVIEW_BLOCK\}\}/$SECTION_REVIEW_BLOCK}"
PROMPT="${PROMPT//\{\{COMPLETION_MESSAGE\}\}/$COMPLETION_MESSAGE}"
PROMPT="${PROMPT//\{\{IMPORTANT_MESSAGE\}\}/$IMPORTANT_MESSAGE}"

check_dependency "$AGENT"

case "$AGENT" in
    opencode) opencode --prompt "$PROMPT" ;;
    claude)   claude "$PROMPT" ;;
    *)        echo "Error: Unknown agent '$AGENT'"; exit 1 ;;
esac
