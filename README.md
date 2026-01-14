# Ralph

An automated coding agent runner that picks tasks and implements them one at a time.

Ralph works with either GitHub issues or a PRD (Product Requirements Document) file as a task source, and uses [OpenCode](https://opencode.ai) to implement each task autonomously.

## Requirements

- `git` - for version control
- `gh` - GitHub CLI (for GitHub issues mode)
- `jq` - JSON processor (for PRD mode)
- `opencode` - AI coding CLI

## Installation

Clone the repository and add it to your PATH:

```bash
git clone https://github.com/ErisDS/ralph.git ~/.ralph

# Add to your shell config (~/.bashrc, ~/.zshrc, etc.)
export PATH="$HOME/.ralph:$PATH"
```

Alternatively, symlink to a directory already in your PATH:

```bash
git clone https://github.com/ErisDS/ralph.git ~/path/to/ralph
ln -s ~/path/to/ralph/ralph-once.sh /usr/local/bin/ralph-once
```

Then run from any project directory:

```bash
ralph-once.sh
```

## Usage

The simplest way to use Ralph is to run it without arguments in your project directory:

```bash
ralph-once.sh
```

On first run, Ralph will interactively ask you:
1. Where to get tasks from (GitHub issues or PRD file)
2. How to handle completed work (PR, commit+push, commit only, branch, or no commit)

Your preferences are saved to `.ralph/config.json` so subsequent runs just work.

### Command Line Options

You can also specify options directly:

```bash
# GitHub issues mode
ralph-once.sh <owner/repo>

# PRD file mode
ralph-once.sh --prd <path/to/prd.json>

# Re-run interactive setup
ralph-once.sh --setup
```

### Commit Strategy

Control how Ralph handles completed work:

```bash
--pr       # Raise a PR and wait for checks (default)
--main     # Commit to main and push
--commit   # Commit to main but don't push (for local review)
--branch   # Create a branch and commit (no push)
--none     # Don't commit, leave files unstaged
```

For `--branch` mode, Ralph will use the `branchName` from your PRD file if available, otherwise it generates a sensible name from the task.

Examples:

```bash
ralph-once.sh --pr myorg/myproject
ralph-once.sh --main --prd ./tasks/prd.json
ralph-once.sh --commit myorg/myproject
ralph-once.sh --branch --prd ./tasks/prd.json
ralph-once.sh --none myorg/myproject
```

## Configuration

Ralph stores project configuration in `.ralph/config.json`:

```json
{
  "mode": "github",
  "commitMode": "pr",
  "repo": "owner/repo",
  "prdFile": ""
}
```

Run `ralph-once.sh --setup` to reconfigure at any time.

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
