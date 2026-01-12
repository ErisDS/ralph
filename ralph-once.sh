#!/bin/bash

if [ -z "$1" ]; then
    echo "Usage: ralph-once.sh <owner/repo>"
    echo "Example: ralph-once.sh myorg/myproject"
    exit 1
fi

REPO="$1"

# Fetch open issues from the repo
ISSUES=$(gh issue list --repo "$REPO" --state open --limit 20 --json number,title,body,labels)

if [ -z "$ISSUES" ] || [ "$ISSUES" = "[]" ]; then
    echo "No open issues found in $REPO"
    exit 0
fi

claude --permission-mode acceptEdits "
Here are the open GitHub issues for $REPO:

$ISSUES

And here is the progress file:
@progress.txt

1. Review the issues and progress file.
2. Find the next issue to work on (pick the lowest numbered issue not marked as done in progress.txt).
3. Implement the changes needed to resolve the issue.
4. Check your work for quality issues, make any amends.
5. Commit your changes with a message referencing the issue (e.g., 'Fix #123: description').
6. Update progress.txt with what you did, including the issue number.
ONLY DO ONE ISSUE AT A TIME."
