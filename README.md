# Ralph

An automated AI coding agent runner. Run tasks one at a time with `ralph-once.sh`, or run multiple agents in parallel with Docker using `ralph.sh`.

## Two Modes of Operation

### 1. Single Agent (`ralph-once.sh`)

Run one agent at a time in your current shell. Simple, no Docker required.

```bash
ralph-once.sh                    # Interactive setup on first run
ralph-once.sh myorg/myproject    # Work on GitHub issues
ralph-once.sh --prd ./prd.json   # Work on PRD tasks
```

### 2. Parallel Agents (`ralph.sh`)

Run multiple agents simultaneously in isolated Docker containers. Each agent gets its own repo clone so they can't interfere with each other.

```bash
ralph.sh build-base              # Build base image (one time)
ralph.sh build                   # Build project image
ralph.sh start                   # Let Ralph choose a task
ralph.sh start --issue 42        # Start agent on issue 42
ralph.sh start --cli claude      # Override agent CLI for this run
ralph.sh start --opencode        # Shorthand for --cli opencode
ralph.sh start --claude          # Shorthand for --cli claude
ralph.sh start --model openai/gpt-5.3  # Override model (opencode)
ralph.sh list                    # See all running agents
```

---

## Key Learnings

- GitHub mode uses the last 10 commit messages as context; write clear commit messages with what/why.
- PRD mode relies on `progress.txt`; keep it updated as tasks complete.
- `--issue` can target epics with tasklists; Ralph will choose the best open sub-issue.
- "Dependency Dashboard" issues are ignored automatically.
- `--copilot` (or `agentReview: "copilot"`) adds a required Copilot review loop before completion.
- Add project-specific commands, manual testing steps, or deploy checks in `ralph/prompt.md` or `.ralph/prompt-once.md` (single-agent).

---

## Parallel Agents (Docker)

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        YOUR MACHINE                              │
│                                                                  │
│  ralph.sh                                                        │
│  ────────                                                        │
│  CLI that manages Docker containers                              │
│  - Runs on your machine                                          │
│  - Starts/stops/monitors containers                              │
│  - Passes credentials via environment variables                  │
│                                                                  │
│         │                                                        │
│         │ docker run ...                                         │
│         ▼                                                        │
│  ┌────────────────────────────────────────────────────────────┐ │
│  │              DOCKER CONTAINER                               │ │
│  │                                                             │ │
│  │  entrypoint.sh                                              │ │
│  │  ─────────────                                              │ │
│  │  Runs INSIDE each container when it starts                  │ │
│  │  - Fetches latest code from GitHub                          │ │
│  │  - Builds a task prompt from issues/PRD                     │ │
│  │  - Runs opencode with Ralph's tuned instructions            │ │
│  │  - Leaves the container running for follow-up               │ │
│  │                                                             │ │
│  │  /workspace/  ← Project repo clone (isolated)               │ │
│  │                                                             │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ Container 1 │  │ Container 2 │  │ Container 3 │   ...        │
│  │ auto-123    │  │ issue-42    │  │ prd-foo     │              │
│  └─────────────┘  └─────────────┘  └─────────────┘              │
└─────────────────────────────────────────────────────────────────┘
```

### Quick Start

```bash
# 1. Set credentials
export GITHUB_TOKEN="ghp_..."
export ANTHROPIC_API_KEY="sk-ant-..."

# 2. Build base image (one time)
./ralph.sh build-base

# 3. Initialize ralph in your project (interactive wizard)
cd ~/your-project
~/path/to/ralph/ralph.sh init

# 4. Build project image
~/path/to/ralph/ralph.sh build

# 6. Start agents
~/path/to/ralph/ralph.sh start
~/path/to/ralph/ralph.sh start --issue 42
```

### Project Setup

Each project uses `.ralph/config.json` (shared with `ralph-once.sh`) plus a `ralph/` directory for Docker:

```
your-project/
├── .ralph/
│   └── config.json      # Shared config (ralph-once + Docker)
├── ralph/
│   ├── Dockerfile       # Extends ralph-base
│   └── prompt.md        # Optional: project instructions to append
├── opencode.json        # Optional: project opencode config (MCP servers, etc.)
└── ...
```

Run `ralph.sh init` to create this from templates.

### Agent Settings (Docker)

- Base image includes the `claude` CLI.
- `ralph.sh` mounts host Claude settings when present (`~/.claude`, `~/.config/claude`, `~/.config/anthropic`).
- `ralph.sh` mounts host opencode settings (`~/.config/opencode`) as global config.
- Opencode automatically merges global config with project's `opencode.json` if present.
- Set `"agent": "claude"` in `.ralph/config.json` to use Claude instead of opencode.

### Configuration (`.ralph/config.json`)

Single-agent prompt template can be overridden per project by creating `.ralph/prompt-once.md`. The template contains the full implementation guidance and Definition of Done - see `templates/prompt-once.md` for the default and available placeholders.

```json
{
  "mode": "github",
  "commitMode": "pr",
  "prdFile": "./prd.json",
  "repo": {
    "owner": "your-org",
    "name": "your-project",
    "url": "https://github.com/your-org/your-project.git"
  },
  "runtime": {
    "node": "22",
    "packageManager": "pnpm"
  },
  "commands": {
    "install": "pnpm install --frozen-lockfile",
    "build": "pnpm build",
    "check": "pnpm check"
  },
  "agent": {
    "cli": "opencode",
    "model": "openai/gpt-5.3",
    "review": null
  },
  "git": {
    "branchPrefix": "ralph/",
    "user": "Ralph Bot",
    "email": "ralph@example.com"
  }
}
```

Notes:
- `mode`: `github` or `prd`
- `prdFile`: used when `mode` is `prd`
- `commitMode`: `pr`, `main`, `commit`, `branch`, or `none`
- `agent.review`: set to `copilot` to require Copilot review in PR mode
- `ralph.sh start --cli` and `--model` override config for a single run (or use `--opencode`/`--claude`)

Optional: add project-specific instructions in `ralph/prompt.md` (Docker) or `.ralph/prompt-once.md` (single-agent).

### Commands

| Command                | Description                                  |
| ---------------------- | -------------------------------------------- |
| `build-base`           | Build the ralph-base Docker image (one time) |
| `init`                 | Interactive setup wizard for new projects     |
| `init --force`         | Re-run setup, overwrite existing config       |
| `build`                | Build project-specific image                 |
| `models [provider]`    | List available opencode models               |
| `start`                | Start agent using config.json task selection |
| `start --issue N`      | Start agent on a specific GitHub issue       |
| `start 42`             | Start agent on issue 42 (bare number, github mode) |
| `start --prd <file>`   | Start agent in PRD mode with given file      |
| `start --prompt "..."` | Start agent with custom prompt               |
| `list`                 | List all Ralph containers with status        |
| `logs [-f] ID`         | View container logs                          |
| `tail ID`              | Follow logs (shorthand for `logs -f`)        |
| `status ID`            | Show detailed container status               |
| `restart ID`           | Stop and restart container with same task    |
| `stop ID`              | Stop and remove container                    |
| `stop --all`           | Stop all containers                          |
| `attach ID`            | Connect to agent for follow-up instructions  |
| `shell ID`             | Open bash in running container               |
| `watch`                | Watch containers, send macOS notifications   |
| `notify [ID]`          | Test notifications or check task status      |
| `clean`                | Remove stopped containers                    |

**Bare number support**: In GitHub mode, you can use bare numbers for task IDs:
```bash
ralph.sh start 42        # Starts issue-42
ralph.sh tail 42         # Follow logs for issue-42  
ralph.sh restart 42      # Restart issue-42
ralph.sh attach 42       # Attach to issue-42
ralph.sh stop 42         # Stop issue-42
```

### Custom opencode Config

For project-specific MCP servers or model settings, create `opencode.json` in your project root:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "openai/gpt-5.3",
  "mcp": {
    "railway": {
      "type": "local",
      "command": ["npx", "-y", "@railway/mcp-server"],
      "enabled": true
    }
  }
}
```

Opencode automatically merges your global `~/.config/opencode/` settings with the project's `opencode.json`.

### Container Status

The `list` and `watch` commands show container status with these indicators:

| Status | Meaning |
| ------ | ------- |
| `⚡ working` | Agent is actively producing output |
| `⏸ waiting` | Agent is waiting for input (detected prompt like `[Y/n]`) |
| `⏸ idle` | No output for >2 minutes, may need attention |
| `✓ done` | Agent finished successfully |
| `✗ failed` | Agent exited with an error |

The table also shows:
- **PROJECT** - Which project the container belongs to
- **FOLDER** - Local path to the project
- **RUNNING** - Total container uptime
- **IDLE** - Time since last output

### Notifications

Get notified when agents finish their work.

#### macOS Desktop Notifications

```bash
# Watch all containers and get notified when they finish
ralph.sh watch

# Test that notifications work
ralph.sh notify

# Check status of a specific task (and send notification)
ralph.sh notify issue-42
```

#### Webhooks (ntfy.sh, custom)

Add notification settings to your project's `.ralph/config.json`:

```json
{
  "notifications": {
    "webhook": "https://your-webhook.example.com/ralph",
    "ntfy": "https://ntfy.sh/your-topic",
    "onSuccess": true,
    "onFailure": true
  }
}
```

**Webhook format** (generic JSON POST):
```json
{
  "status": "success",
  "title": "Ralph: project done",
  "message": "Task issue-42 completed successfully",
  "task": "issue-42",
  "repo": "owner/project"
}
```

**ntfy.sh** sends with priority and tags (✅ for success, ❌ for failure).

Popular notification services:
- [ntfy.sh](https://ntfy.sh) - Free, self-hostable, has iOS/Android apps
- [Pushover](https://pushover.net) - Use webhook with their API
- Custom webhook to Slack, Discord, etc.

---

## Single Agent (`ralph-once.sh`)

For simpler use cases where you only need one agent at a time.

### Requirements

- `git` - for version control
- `gh` - GitHub CLI (for GitHub issues mode)
- `jq` - JSON processor (for PRD mode)
- `opencode` or `claude` - AI coding CLI

### Installation

```bash
git clone https://github.com/ErisDS/ralph.git ~/.ralph
export PATH="$HOME/.ralph:$PATH"
```

### Usage

```bash
# Interactive setup on first run
ralph-once.sh

# GitHub issues mode
ralph-once.sh myorg/myproject

# PRD file mode
ralph-once.sh --prd ./tasks/prd.json

# Re-run interactive setup
ralph-once.sh --setup
```

### Commit Strategies

```bash
--pr       # Raise a PR and wait for checks (default)
--main     # Commit to main and push
--commit   # Commit to main but don't push
--branch   # Create a branch and commit (no push)
--none     # Don't commit, leave files unstaged
```

### AI Agent Selection

```bash
--cli <name>  # Use opencode or claude
--opencode  # Use opencode (default)
--claude    # Use claude
--model <model> # Override model (opencode only)
```

### Configuration

Stored in `.ralph/config.json` per project:

```json
{
  "mode": "github",
  "commitMode": "pr",
  "repo": "owner/repo",
  "agent": "opencode"
}
```

---

## PRD File Format

Both modes support PRD (Product Requirements Document) files:

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

---

## Environment Variables

| Variable            | Required      | Description                                  |
| ------------------- | ------------- | -------------------------------------------- |
| `GITHUB_TOKEN`      | Yes           | GitHub personal access token with repo scope |
| `OPENAI_API_KEY`    | For OpenAI    | API key for OpenAI models                    |
| `ANTHROPIC_API_KEY` | For Anthropic | API key for Anthropic models                 |
| `RALPH_CPUS`        | No            | CPU limit per container (default: 2)         |
| `RALPH_MEMORY`      | No            | Memory limit per container (default: 4g)     |

---

## Why "Ralph"?

Named after Ralph Wiggum - it tries its best, one task at a time. Or now, several tasks at once!
