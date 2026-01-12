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

if claude --permission-mode acceptEdits "
Here are the open GitHub issues for $REPO:

$ISSUES

And here is the progress file:
@progress.txt

1. Review the issues and progress file.
2. Find the next issue to work on (pick the lowest numbered issue not marked as done in progress.txt).
3. Implement the changes needed to resolve the issue.
4. Check your work for quality issues, iteratively make any amends.
5. Commit your changes with a well-written commit message following guidance in AGENTS.md
6. Update progress.txt with what you did, including the issue number.
7. Raise a pull request with a title and description referencing the issue, and share the link
8. Output: <promise>COMPLETE</promise>
ONLY DO ONE ISSUE AT A TIME."; then
    echo "Ralph completed successfully"
else
    echo "Ralph exited with an error"
    exit 1
fi
