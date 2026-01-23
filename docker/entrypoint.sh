#!/bin/bash
set -e

# ============================================================
# Ralph Generic Entrypoint
# Runs inside containers to execute AI agent tasks
# Reads configuration from /ralph/ralph.json
# ============================================================

CONFIG_FILE="/ralph/ralph.json"
PROMPT_FILE="/ralph/prompt.md"
DEFAULT_PROMPT_FILE="/usr/local/share/ralph-prompt.md"

# ============================================================
# Read Configuration
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file not found: $CONFIG_FILE"
    exit 1
fi

# Parse config with jq
REPO_OWNER=$(jq -r '.repo.owner' "$CONFIG_FILE")
REPO_NAME=$(jq -r '.repo.name' "$CONFIG_FILE")
BRANCH_PREFIX=$(jq -r '.git.branchPrefix // "ralph/"' "$CONFIG_FILE")
GIT_USER=$(jq -r '.git.user // "Ralph Bot"' "$CONFIG_FILE")
GIT_EMAIL=$(jq -r '.git.email // "ralph@example.com"' "$CONFIG_FILE")
CHECK_COMMAND=$(jq -r '.commands.check // "npm test"' "$CONFIG_FILE")
MODEL=$(jq -r '.agent.model // "anthropic/claude-sonnet-4-20250514"' "$CONFIG_FILE")

# ============================================================
# Argument Parsing
# ============================================================
TASK_TYPE=""
TASK_ID=""
ISSUE_NUMBER=""
PRD_STORY_ID=""
CUSTOM_PROMPT=""

show_usage() {
    cat << 'EOF'
Usage: entrypoint.sh [OPTIONS]

Options:
  --issue <number>     Work on a GitHub issue
  --prd <story-id>     Work on a PRD user story (e.g., US-001)
  --prompt <text>      Work on a custom prompt
  -h, --help           Show this help message

Environment variables:
  GITHUB_TOKEN         Required for gh CLI and pushing
  ANTHROPIC_API_KEY    Required for opencode with Anthropic models

EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --issue)
            TASK_TYPE="issue"
            ISSUE_NUMBER="$2"
            TASK_ID="issue-${2}"
            shift 2
            ;;
        --prd)
            TASK_TYPE="prd"
            PRD_STORY_ID="$2"
            TASK_ID="$2"
            shift 2
            ;;
        --prompt)
            TASK_TYPE="prompt"
            CUSTOM_PROMPT="$2"
            TASK_ID="custom-$(date +%s)"
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

if [ -z "$TASK_TYPE" ]; then
    echo "Error: Must specify --issue, --prd, or --prompt"
    show_usage
    exit 1
fi

# ============================================================
# Environment Validation
# ============================================================
if [ -z "$GITHUB_TOKEN" ]; then
    echo "Error: GITHUB_TOKEN environment variable is required"
    exit 1
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

# Check if project has custom opencode config
if [ -f "/ralph/opencode.json" ]; then
    cp /ralph/opencode.json "$HOME/.config/opencode/opencode.json"
else
    # Create minimal config with model from ralph.json
    cat > "$HOME/.config/opencode/opencode.json" << EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "model": "$MODEL"
}
EOF
fi

# ============================================================
# GitHub CLI Authentication
# ============================================================
echo "Verifying GitHub CLI authentication..."
if ! gh auth status &>/dev/null; then
    echo "Error: GitHub CLI authentication failed"
    exit 1
fi
echo "GitHub CLI authenticated successfully"

# ============================================================
# Update Repository
# ============================================================
cd /workspace

# Configure git for this repo
git config user.name "$GIT_USER"
git config user.email "$GIT_EMAIL"
git config url."https://${GITHUB_TOKEN}@github.com/".insteadOf "https://github.com/"

echo "Fetching latest changes..."
git fetch origin

echo "Resetting to origin/main..."
git checkout main
git reset --hard origin/main

# Check if dependencies need updating (for pnpm projects)
if [ -f "pnpm-lock.yaml" ] && git diff HEAD@{1} --name-only 2>/dev/null | grep -q "pnpm-lock.yaml"; then
    echo "Dependencies changed, running pnpm install..."
    pnpm install --frozen-lockfile
fi

# ============================================================
# Create Feature Branch
# ============================================================
BRANCH_NAME="${BRANCH_PREFIX}${TASK_ID}"
echo "Creating feature branch: $BRANCH_NAME"
git checkout -b "$BRANCH_NAME"

# ============================================================
# Build Prompt
# ============================================================
build_prompt() {
    local task_title=""
    local task_description=""
    local acceptance_criteria=""
    
    case "$TASK_TYPE" in
        issue)
            echo "Fetching issue #${ISSUE_NUMBER}..."
            local issue_json
            issue_json=$(gh issue view "$ISSUE_NUMBER" --repo "${REPO_OWNER}/${REPO_NAME}" --json title,body,labels)
            
            task_title=$(echo "$issue_json" | jq -r '.title')
            task_description=$(echo "$issue_json" | jq -r '.body // "No description provided"')
            acceptance_criteria="- Issue requirements are implemented
- All existing tests pass
- Code follows project patterns
- ${CHECK_COMMAND} passes"
            ;;
        prd)
            echo "Loading PRD story ${PRD_STORY_ID}..."
            local prd_file=""
            for f in prd.json docs/prd.json PRD.json; do
                if [ -f "$f" ]; then
                    prd_file="$f"
                    break
                fi
            done
            
            if [ -z "$prd_file" ]; then
                echo "Error: No PRD file found"
                exit 1
            fi
            
            local story_json
            story_json=$(jq --arg id "$PRD_STORY_ID" '.userStories[] | select(.id == $id)' "$prd_file" 2>/dev/null || echo "")
            
            if [ -z "$story_json" ] || [ "$story_json" = "null" ]; then
                echo "Error: Story ${PRD_STORY_ID} not found in ${prd_file}"
                exit 1
            fi
            
            task_title=$(echo "$story_json" | jq -r '.title // .name // "Unknown Story"')
            task_description=$(echo "$story_json" | jq -r '.description // "No description"')
            acceptance_criteria=$(echo "$story_json" | jq -r '.acceptanceCriteria // [] | map("- " + .) | join("\n")' 2>/dev/null || echo "- Story requirements are met")
            ;;
        prompt)
            task_title="Custom Task"
            task_description="$CUSTOM_PROMPT"
            acceptance_criteria="- Task requirements are implemented
- All existing tests pass
- ${CHECK_COMMAND} passes"
            ;;
    esac
    
    # Use project prompt template if exists, otherwise use default
    local template_file="$PROMPT_FILE"
    if [ ! -f "$template_file" ]; then
        template_file="$DEFAULT_PROMPT_FILE"
    fi
    
    if [ ! -f "$template_file" ]; then
        # Inline default template
        cat << PROMPT_EOF
# Task: ${task_title}

**Type:** ${TASK_TYPE}
**ID:** ${TASK_ID}
**Branch:** ${BRANCH_NAME}

## Description

${task_description}

## Acceptance Criteria

${acceptance_criteria}

---

## Instructions

You are an autonomous coding agent. Complete the task described above.

1. Explore the codebase to understand the structure
2. Implement the changes following existing patterns
3. Run the quality checks: ${CHECK_COMMAND}
4. Fix any issues that arise
5. Commit your changes with a descriptive message

Do NOT push or create PRs - the entrypoint script handles this.
PROMPT_EOF
        return
    fi
    
    # Read template and substitute variables
    local prompt
    prompt=$(cat "$template_file")
    prompt="${prompt//\{\{TASK_TYPE\}\}/$TASK_TYPE}"
    prompt="${prompt//\{\{TASK_ID\}\}/$TASK_ID}"
    prompt="${prompt//\{\{TASK_TITLE\}\}/$task_title}"
    prompt="${prompt//\{\{TASK_DESCRIPTION\}\}/$task_description}"
    prompt="${prompt//\{\{ACCEPTANCE_CRITERIA\}\}/$acceptance_criteria}"
    prompt="${prompt//\{\{BRANCH_NAME\}\}/$BRANCH_NAME}"
    prompt="${prompt//\{\{REPO_OWNER\}\}/$REPO_OWNER}"
    prompt="${prompt//\{\{REPO_NAME\}\}/$REPO_NAME}"
    prompt="${prompt//\{\{CHECK_COMMAND\}\}/$CHECK_COMMAND}"
    
    echo "$prompt"
}

PROMPT=$(build_prompt)

# ============================================================
# Run opencode
# ============================================================
echo "=============================================="
echo "Starting opencode agent..."
echo "Task: $TASK_TYPE - $TASK_ID"
echo "Branch: $BRANCH_NAME"
echo "Model: $MODEL"
echo "=============================================="

if ! opencode run "$PROMPT"; then
    echo "Error: opencode failed"
    exit 1
fi

# ============================================================
# Post-Processing: Create PR if changes were made
# ============================================================
echo "=============================================="
echo "Agent completed, checking for changes..."
echo "=============================================="

COMMITS_AHEAD=$(git rev-list --count origin/main..HEAD)

if [ "$COMMITS_AHEAD" -eq 0 ]; then
    echo "No commits were made. Agent may not have completed the task."
    exit 1
fi

echo "Found $COMMITS_AHEAD commit(s) on branch $BRANCH_NAME"

# Push the branch
echo "Pushing branch to origin..."
git push -u origin "$BRANCH_NAME"

# Create PR
echo "Creating pull request..."

PR_TITLE=""
PR_BODY=""

case "$TASK_TYPE" in
    issue)
        PR_TITLE="[Ralph] Fix issue #${ISSUE_NUMBER}"
        PR_BODY="## Summary

This PR was automatically created by Ralph to address issue #${ISSUE_NUMBER}.

## Changes

See commit history for details.

## Testing

- [ ] Quality checks pass
- [ ] Manual testing completed

Closes #${ISSUE_NUMBER}"
        ;;
    prd)
        PR_TITLE="[Ralph] Implement ${PRD_STORY_ID}"
        PR_BODY="## Summary

This PR was automatically created by Ralph to implement story ${PRD_STORY_ID}.

## Changes

See commit history for details.

## Testing

- [ ] Quality checks pass
- [ ] Acceptance criteria verified"
        ;;
    prompt)
        PR_TITLE="[Ralph] ${TASK_ID}"
        PR_BODY="## Summary

This PR was automatically created by Ralph for a custom task.

## Original Prompt

${CUSTOM_PROMPT}

## Changes

See commit history for details.

## Testing

- [ ] Quality checks pass"
        ;;
esac

PR_URL=$(gh pr create \
    --repo "${REPO_OWNER}/${REPO_NAME}" \
    --title "$PR_TITLE" \
    --body "$PR_BODY" \
    --head "$BRANCH_NAME" \
    --base main)

echo "=============================================="
echo "SUCCESS!"
echo "PR created: $PR_URL"
echo "=============================================="

# Request Copilot review if available
PR_NUMBER=$(echo "$PR_URL" | grep -oE '[0-9]+$')
if [ -n "$PR_NUMBER" ]; then
    echo "Requesting Copilot review..."
    gh api -X POST "repos/${REPO_OWNER}/${REPO_NAME}/pulls/${PR_NUMBER}/requested_reviewers" \
        -f 'reviewers[]=copilot-pull-request-reviewer[bot]' 2>/dev/null || true
fi

exit 0
