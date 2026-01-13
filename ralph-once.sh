#!/bin/bash
set -e

if [ -z "$1" ]; then
    echo "Usage: ralph-once.sh <owner/repo>"
    echo "Example: ralph-once.sh myorg/myproject"
    exit 1
fi

REPO="$1"

# Verify we're in a git repo that matches the target
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: Not in a git repository"
    exit 1
fi

REMOTE_URL=$(git remote get-url origin 2>/dev/null || echo "")
if [[ ! "$REMOTE_URL" =~ "$REPO" ]]; then
    echo "Error: Current directory doesn't appear to be a clone of $REPO"
    echo "Remote URL: $REMOTE_URL"
    exit 1
fi

# Get the default branch and ensure we're on latest
DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main")
echo "Checking out $DEFAULT_BRANCH and pulling latest..."
git checkout "$DEFAULT_BRANCH"
git pull origin "$DEFAULT_BRANCH"

# Ensure progress.txt exists
touch progress.txt

# Fetch open issues from the repo
if ! ISSUES=$(gh issue list --repo "$REPO" --state open --limit 20 --json number,title,body,labels); then
    echo "Error: Failed to fetch issues from $REPO"
    exit 1
fi

if [ -z "$ISSUES" ] || [ "$ISSUES" = "[]" ]; then
    echo "No open issues found in $REPO"
    exit 0
fi

PROGRESS=$(cat progress.txt)

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
6. ONLY when all checks are passing, commit your changes with a well-written commit message following guidance in AGENTS.md
7. Update progress.txt with what you did, including the issue number.
8. Raise a pull request with a title and description referencing the issue, and share the link.
9. Wait for PR status checks to pass. If they fail, fix the issues and push again.
10. Output: <promise>COMPLETE</promise>
ONLY DO ONE ISSUE AT A TIME."
