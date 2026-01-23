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
ralph.sh start --issue 42        # Start agent on issue 42
ralph.sh start --issue 43        # Start another agent on issue 43
ralph.sh list                    # See all running agents
```

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
│  │  - Creates feature branch                                   │ │
│  │  - Runs opencode with the task prompt                       │ │
│  │  - Pushes branch & creates PR when done                     │ │
│  │                                                             │ │
│  │  /workspace/  ← Project repo clone (isolated)               │ │
│  │                                                             │ │
│  └────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐              │
│  │ Container 1 │  │ Container 2 │  │ Container 3 │   ...        │
│  │ issue-42    │  │ issue-43    │  │ US-001      │              │
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

# 3. Initialize ralph in your project
cd ~/your-project
~/path/to/ralph/ralph.sh init

# 4. Edit ralph/ralph.json with your project details

# 5. Build project image
~/path/to/ralph/ralph.sh build

# 6. Start agents
~/path/to/ralph/ralph.sh start --issue 42
~/path/to/ralph/ralph.sh start --issue 43
```

### Project Setup

Each project needs a `ralph/` directory with configuration:

```
your-project/
├── ralph/
│   ├── ralph.json       # Project configuration
│   ├── Dockerfile       # Extends ralph-base
│   ├── prompt.md        # Optional: custom prompt template
│   └── opencode.json    # Optional: opencode config (MCP servers, etc.)
└── ...
```

Run `ralph.sh init` to create this from templates.

### Configuration (`ralph.json`)

```json
{
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
    "model": "anthropic/claude-sonnet-4-20250514"
  },
  "git": {
    "branchPrefix": "ralph/",
    "user": "Ralph Bot",
    "email": "ralph@example.com"
  }
}
```

### Commands

| Command                | Description                                  |
| ---------------------- | -------------------------------------------- |
| `build-base`           | Build the ralph-base Docker image (one time) |
| `init`                 | Initialize ralph config in current project   |
| `build`                | Build project-specific image                 |
| `start --issue N`      | Start agent on GitHub issue                  |
| `start --prd ID`       | Start agent on PRD story                     |
| `start --prompt "..."` | Start agent with custom prompt               |
| `list`                 | List all Ralph containers                    |
| `logs [-f] ID`         | View container logs                          |
| `status ID`            | Show detailed container status               |
| `stop ID`              | Stop and remove container                    |
| `stop --all`           | Stop all containers                          |
| `shell ID`             | Open bash in running container               |
| `clean`                | Remove stopped containers                    |

### Custom opencode Config

For project-specific MCP servers or model settings, create `ralph/opencode.json`:

```json
{
  "$schema": "https://opencode.ai/config.json",
  "model": "anthropic/claude-sonnet-4-20250514",
  "mcp": {
    "railway": {
      "type": "local",
      "command": ["npx", "-y", "@railway/mcp-server"],
      "enabled": true
    }
  }
}
```

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
--opencode  # Use opencode (default)
--claude    # Use claude
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
| `ANTHROPIC_API_KEY` | For Anthropic | API key for Claude models                    |
| `RALPH_CPUS`        | No            | CPU limit per container (default: 2)         |
| `RALPH_MEMORY`      | No            | Memory limit per container (default: 4g)     |

---

## Why "Ralph"?

Named after Ralph Wiggum - it tries its best, one task at a time. Or now, several tasks at once!
