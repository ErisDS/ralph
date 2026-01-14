# Ralph

An automated coding agent runner that picks tasks and implements them one at a time.

Ralph works with either GitHub issues or a PRD (Product Requirements Document) file as a task source, and uses [OpenCode](https://opencode.ai) to implement each task autonomously.

## Requirements

- `git` - for version control
- `gh` - GitHub CLI (for GitHub issues mode)
- `jq` - JSON processor (for PRD mode)
- `opencode` - AI coding CLI

## Usage

```bash
# GitHub issues mode
ralph-once.sh <owner/repo>

# PRD file mode
ralph-once.sh --prd <path/to/prd.json>
```

### Commit Strategy

By default, Ralph raises a pull request and waits for status checks to pass. You can also commit directly to main:

```bash
# PR mode (default) - creates PR and waits for checks
ralph-once.sh myorg/myproject
ralph-once.sh --pr myorg/myproject

# Main mode - commits directly to main branch
ralph-once.sh --main myorg/myproject
ralph-once.sh --main --prd ./tasks/prd.json
```

## How It Works

1. Checks out the default branch and pulls latest changes
2. Fetches tasks (GitHub issues or PRD user stories)
3. Passes tasks to OpenCode with instructions to:
   - Pick the next available task
   - Implement the changes
   - Run tests and linter
   - Commit and push (either via PR or direct to main)
   - Update progress tracking

### Task Selection

**GitHub mode:** Picks the lowest numbered open issue not marked as done in `progress.txt`.

**PRD mode:** Picks an incomplete task (`passes: false`) whose dependencies are all satisfied, preferring lower priority numbers and lower IDs.

## PRD File Format

PRD files should contain a `userStories` array:

```json
{
  "name": "Project Name",
  "userStories": [
    {
      "id": "US-001",
      "title": "Task title",
      "description": "What needs to be done",
      "acceptanceCriteria": ["Criterion 1", "Criterion 2"],
      "priority": 1,
      "passes": false,
      "dependsOn": []
    }
  ]
}
```

When a task is completed, Ralph updates the PRD file to set `passes: true` and adds `completionNotes`.

## Progress Tracking

Ralph maintains a `progress.txt` file in the repository root to track completed work. This file is used to avoid re-working completed tasks.

## Why "Ralph"?

Named after Ralph Wiggum - it tries its best, one task at a time.
