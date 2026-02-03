#!/bin/bash
set -e

# ============================================================
# Ralph - Parallel AI Agent CLI
# Manages Docker containers for AI coding agents across any project
# ============================================================

VERSION="2.0.0"
BASE_IMAGE_NAME="ralph-base"
CONTAINER_PREFIX="ralph"

# Get the directory where this script is located (resolving symlinks)
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================
# Helper Functions
# ============================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Find project root (look for .ralph/config.json)
find_ralph_config() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/.ralph/config.json" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

get_config_file() {
    local root="$1"
    if [ -f "$root/.ralph/config.json" ]; then
        echo "$root/.ralph/config.json"
        return 0
    fi
    return 1
}

# Get project name from config
get_project_name() {
    local root="$1"
    local config_file
    config_file=$(get_config_file "$root") || { echo "project"; return; }
    jq -r 'if (.repo|type) == "string" then ((.repo | split("/"))[-1] // "project") elif (.repo.name) then .repo.name else "project" end' "$config_file" | tr '[:upper:]' '[:lower:]'
}

# Get image name for project
get_image_name() {
    local project_name="$1"
    echo "ralph-${project_name}"
}

# Normalize task ID to container-safe format
normalize_task_id() {
    echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g'
}

# Parse task arguments: handles bare numbers, "issue 42", "--issue 42", etc.
# Sets: PARSED_TASK_ID (e.g., "issue-219")
# Args: all remaining arguments
parse_task_args() {
    PARSED_TASK_ID=""
    local task_type=""
    local task_value=""
    local collected_digits=""
    local raw_id=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --issue|--task|issue)
                task_type="issue"
                task_value="$2"
                shift 2
                ;;
            --prd|prd)
                task_type="prd"
                task_value="$2"
                shift 2
                ;;
            --prompt|prompt)
                task_type="prompt"
                task_value="$2"
                shift 2
                ;;
            -f|--follow|--all|-a)
                # Skip flags handled by caller
                shift
                ;;
            *)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    collected_digits="${collected_digits}${1}"
                elif [ -z "$raw_id" ]; then
                    raw_id="$1"
                fi
                shift
                ;;
        esac
    done
    
    if [ -n "$task_type" ]; then
        case "$task_type" in
            issue) PARSED_TASK_ID="issue-$task_value" ;;
            prd) PARSED_TASK_ID="prd-$(basename "$task_value")" ;;
            prompt) PARSED_TASK_ID="$task_value" ;;
        esac
    elif [ -n "$collected_digits" ]; then
        PARSED_TASK_ID="issue-$collected_digits"
    elif [ -n "$raw_id" ]; then
        PARSED_TASK_ID="$raw_id"
    fi
}

# Get container name
container_name() {
    local project_name="$1"
    local task_id="$2"
    echo "${CONTAINER_PREFIX}-${project_name}-$(normalize_task_id "$task_id")"
}

# Check if image exists
image_exists() {
    docker image inspect "$1" &>/dev/null
}

# Check if container exists
container_exists() {
    docker container inspect "$1" &>/dev/null 2>&1
}

# Check if container is running
container_running() {
    [ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]
}

# ============================================================
# Commands
# ============================================================

show_usage() {
    cat << EOF
Ralph - Parallel AI Agent CLI
Version: $VERSION

Usage: ralph.sh <command> [options]

Commands:
  build-base           Build the ralph-base Docker image
  build                Build project-specific image (run from project dir)
  start                Start a new agent container
  restart              Stop and restart a container with same task
  attach               Connect to agent for follow-up instructions
  list                 List all Ralph containers
  logs                 View container logs
  tail                 Follow container logs (shorthand for logs -f)
  stop                 Stop container(s)
  status               Show detailed status of a container
  shell                Open interactive shell in container
  watch                Watch containers and send macOS notifications on completion
  notify [task]        Send a test notification (or check status of a task)
  clean                Remove all stopped containers
  init [--force]       Initialize ralph config (interactive setup)

Start Options:
  --issue <number>     Work on a specific GitHub issue
  --task <number>      Alias for --issue
  --prd <file>         Use PRD mode with the given PRD file
  --prompt <text>      Use a custom prompt
  (no args)            Let Ralph choose its own task based on config.json

Examples:
  ralph.sh build-base                    # Build base image (one time)
  ralph.sh init                          # Interactive setup wizard
  ralph.sh init --force                  # Re-run setup (overwrite config)
  ralph.sh build                         # Build project image
  ralph.sh start                         # Let Ralph choose a task
  ralph.sh start 42                      # Start agent on issue 42 (github mode)
  ralph.sh start 2 1 9                   # Start agent on issue 219 (digits joined)
  ralph.sh start --issue 42              # Explicit issue flag
  ralph.sh attach issue-42               # Connect for follow-up work
  ralph.sh attach 42                     # Connect using bare number
  ralph.sh list                          # List all containers
  ralph.sh tail 42                       # Follow logs for issue 42
  ralph.sh restart 42                    # Stop and restart issue 42
  ralph.sh stop --all                    # Stop all containers

Environment Variables:
  GITHUB_TOKEN         Required for GitHub operations
  ANTHROPIC_API_KEY    Required for opencode with Anthropic
  RALPH_CPUS           CPU limit per container (default: 2)
  RALPH_MEMORY         Memory limit per container (default: 4g)

EOF
}

cmd_build_base() {
    log_info "Building ralph-base image..."
    
    docker build -t "$BASE_IMAGE_NAME" -f "$SCRIPT_DIR/docker/Dockerfile.base" "$SCRIPT_DIR"
    
    log_success "Base image built: $BASE_IMAGE_NAME"
}

# Detect GitHub repo from git remote
detect_github_repo() {
    git remote get-url origin 2>/dev/null | sed -E 's|.*github\.com[:/]||; s|\.git$||' || echo ""
}

cmd_init() {
    local target_dir="${1:-.}"
    local force_setup=false
    
    # Parse args
    while [[ $# -gt 0 ]]; do
        case $1 in
            --force|-f) force_setup=true; shift ;;
            *) target_dir="$1"; shift ;;
        esac
    done
    
    # Check if config already exists
    if [ -f "$target_dir/.ralph/config.json" ] && [ "$force_setup" = false ]; then
        log_warn ".ralph/config.json already exists"
        echo ""
        read -p "Do you want to reconfigure? [y/N]: " reconfigure
        if [[ ! "$reconfigure" =~ ^[Yy] ]]; then
            echo "Use 'ralph init --force' to overwrite existing config"
            return 0
        fi
    fi
    
    echo ""
    echo -e "${GREEN}Welcome to Ralph!${NC} Let's set up your project for parallel AI agents."
    echo ""
    
    # === Mode Selection ===
    echo "Where should Ralph get tasks from?"
    echo "  1) GitHub issues"
    echo "  2) PRD file (prd.json)"
    echo ""
    read -p "Choose [1/2]: " task_choice
    
    local mode="github"
    local repo=""
    local prd_file=""
    
    case $task_choice in
        1)
            mode="github"
            local detected=$(detect_github_repo)
            if [ -n "$detected" ]; then
                read -p "GitHub repo [$detected]: " repo
                [ -z "$repo" ] && repo="$detected"
            else
                read -p "GitHub repo (owner/repo): " repo
            fi
            ;;
        2)
            mode="prd"
            read -p "Path to PRD file [./prd.json]: " prd_file
            [ -z "$prd_file" ] && prd_file="./prd.json"
            ;;
        *)
            log_error "Invalid choice"
            exit 1
            ;;
    esac
    
    # === Commit Mode ===
    echo ""
    echo "How should Ralph handle completed work?"
    echo "  1) Raise a PR and wait for checks"
    echo "  2) Commit to main and push"
    echo "  3) Commit to main only (no push)"
    echo "  4) Branch and commit (no push)"
    echo "  5) Don't commit (leave files unstaged)"
    echo ""
    read -p "Choose [1/2/3/4/5]: " commit_choice
    
    local commit_mode="pr"
    case $commit_choice in
        1|"") commit_mode="pr" ;;
        2) commit_mode="main" ;;
        3) commit_mode="commit" ;;
        4) commit_mode="branch" ;;
        5) commit_mode="none" ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
    
    # === Agent Review (only for PR mode) ===
    local agent_review=""
    if [ "$commit_mode" = "pr" ]; then
        echo ""
        echo "Should Ralph wait for an AI code reviewer?"
        echo "  1) None (default)"
        echo "  2) Copilot - Wait for GitHub Copilot review"
        echo ""
        read -p "Choose [1/2]: " review_choice
        
        case $review_choice in
            1|"") agent_review="" ;;
            2) agent_review="copilot" ;;
            *) log_error "Invalid choice"; exit 1 ;;
        esac
    fi
    
    # === Agent Selection ===
    echo ""
    echo "Which AI agent should Ralph use?"
    echo "  1) opencode (default)"
    echo "  2) claude"
    echo ""
    read -p "Choose [1/2]: " agent_choice
    
    local agent="opencode"
    case $agent_choice in
        1|"") agent="opencode" ;;
        2) agent="claude" ;;
        *) log_error "Invalid choice"; exit 1 ;;
    esac
    
    # === Notifications (optional) ===
    echo ""
    echo "Do you want to set up notifications? (optional)"
    echo "  1) Skip for now"
    echo "  2) ntfy.sh (free push notifications)"
    echo "  3) Custom webhook"
    echo ""
    read -p "Choose [1/2/3]: " notify_choice
    
    local ntfy_url=""
    local webhook_url=""
    case $notify_choice in
        2)
            read -p "ntfy.sh topic URL (e.g., https://ntfy.sh/my-ralph): " ntfy_url
            ;;
        3)
            read -p "Webhook URL: " webhook_url
            ;;
    esac
    
    # === Create directories ===
    mkdir -p "$target_dir/ralph" "$target_dir/.ralph"
    
    # === Build config.json ===
    local config_file="$target_dir/.ralph/config.json"
    cat > "$config_file" << EOF
{
  "mode": "$mode",
  "commitMode": "$commit_mode",
  "repo": "$repo",
  "prdFile": "$prd_file",
  "agent": "$agent",
  "agentReview": "$agent_review",
  "notifications": {
    "webhook": "$webhook_url",
    "ntfy": "$ntfy_url",
    "onSuccess": true,
    "onFailure": true
  }
}
EOF
    log_success "Created .ralph/config.json"
    
    # === Copy Dockerfile if needed ===
    if [ -f "$target_dir/ralph/Dockerfile" ]; then
        log_warn "ralph/Dockerfile already exists, leaving it unchanged"
    else
        cp "$SCRIPT_DIR/templates/Dockerfile" "$target_dir/ralph/"
        log_success "Created ralph/Dockerfile"
    fi
    
    # === Copy prompt.md if needed ===
    if [ -f "$target_dir/ralph/prompt.md" ]; then
        log_warn "ralph/prompt.md already exists, leaving it unchanged"
    else
        cp "$SCRIPT_DIR/templates/prompt.md" "$target_dir/ralph/"
        log_success "Created ralph/prompt.md"
    fi
    
    # === Summary ===
    echo ""
    echo -e "${GREEN}Ralph is configured!${NC}"
    echo ""
    echo "Configuration:"
    echo "  Mode:        $mode"
    [ -n "$repo" ] && echo "  Repo:        $repo"
    [ -n "$prd_file" ] && echo "  PRD file:    $prd_file"
    echo "  Commit mode: $commit_mode"
    echo "  Agent:       $agent"
    [ -n "$agent_review" ] && echo "  Review:      $agent_review"
    [ -n "$ntfy_url" ] && echo "  Notify:      $ntfy_url"
    [ -n "$webhook_url" ] && echo "  Webhook:     $webhook_url"
    echo ""
    echo "Next steps:"
    echo "  1. Review/edit .ralph/config.json if needed"
    echo "  2. Customize ralph/prompt.md with project-specific instructions"
    echo "  3. Run: ralph build"
    echo "  4. Run: ralph start --issue <number>"
}

cmd_build() {
    local project_root
    if ! project_root=$(find_ralph_config); then
        log_error "No config found (.ralph/config.json). Run 'ralph.sh init' first."
        exit 1
    fi
    
    local config_file
    if ! config_file=$(get_config_file "$project_root"); then
        log_error "No config file found. Run 'ralph.sh init' first."
        exit 1
    fi
    
    if [ ! -f "$project_root/ralph/Dockerfile" ]; then
        log_error "No ralph/Dockerfile found. Run 'ralph.sh init' first."
        exit 1
    fi
    
    local project_name=$(get_project_name "$project_root")
    local image_name=$(get_image_name "$project_name")
    
    log_info "Building image for project: $project_name"
    
    # Check base image exists
    if ! image_exists "$BASE_IMAGE_NAME"; then
        log_warn "Base image not found. Building it first..."
        cmd_build_base
    fi
    
    # Build secrets from config (e.g., ["GITHUB_TOKEN", "TIPTAP_PRO_TOKEN"])
    # These are passed securely via BuildKit --secret, not baked into image layers
    local secret_args=""
    local build_secrets=$(jq -r '.buildSecrets // [] | .[]' "$config_file" 2>/dev/null)
    
    for secret_name in $build_secrets; do
        # Convert to lowercase for the secret id (e.g., GITHUB_TOKEN -> github_token)
        local secret_id=$(echo "$secret_name" | tr '[:upper:]' '[:lower:]')
        # Check if the env var is set
        local secret_value="${!secret_name}"
        if [ -n "$secret_value" ]; then
            secret_args="$secret_args --secret id=$secret_id,env=$secret_name"
        else
            log_warn "Secret $secret_name not set in environment"
        fi
    done
    
    DOCKER_BUILDKIT=1 docker build $secret_args -t "$image_name" "$project_root/ralph"
    
    log_success "Image built: $image_name"
}

cmd_start() {
    local project_root
    if ! project_root=$(find_ralph_config); then
        log_error "No config found (.ralph/config.json). Run 'ralph.sh init' first."
        exit 1
    fi
    
    local config_file
    if ! config_file=$(get_config_file "$project_root"); then
        log_error "No config file found. Run 'ralph.sh init' first."
        exit 1
    fi
    
    local project_name=$(get_project_name "$project_root")
    local image_name=$(get_image_name "$project_name")
    
    local task_type=""
    local task_value=""
    local task_id=""
    local mode_from_config
    mode_from_config=$(jq -r '.mode // "github"' "$config_file")
    
    # Collect any bare numbers (for "ralph start 2 1 9" -> issue 219)
    local collected_digits=""
    
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --issue|--task)
                task_type="issue"
                task_value="$2"
                task_id="issue-$2"
                shift 2
                ;;
            issue)
                task_type="issue"
                task_value="$2"
                task_id="issue-$2"
                shift 2
                ;;
            --prd)
                task_type="prd"
                task_value="$2"
                task_id="prd-$(basename "$2")"
                shift 2
                ;;
            prd)
                task_type="prd"
                task_value="$2"
                task_id="prd-$(basename "$2")"
                shift 2
                ;;
            --prompt)
                task_type="prompt"
                task_value="$2"
                task_id="custom-$(date +%s)"
                shift 2
                ;;
            prompt)
                task_type="prompt"
                task_value="$2"
                task_id="custom-$(date +%s)"
                shift 2
                ;;
            *)
                # Check if it's a number (bare issue number in github mode)
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    collected_digits="${collected_digits}${1}"
                    shift
                else
                    log_error "Unknown option: $1"
                    show_usage
                    exit 1
                fi
                ;;
        esac
    done
    
    # If we collected digits and no explicit task type, treat as issue number in github mode
    if [ -n "$collected_digits" ] && [ -z "$task_type" ]; then
        if [ "$mode_from_config" = "github" ]; then
            task_type="issue"
            task_value="$collected_digits"
            task_id="issue-$collected_digits"
        else
            log_error "Bare numbers only work in github mode. Use --prd or --prompt instead."
            exit 1
        fi
    fi
    
    if [ -z "$task_type" ]; then
        task_id="auto-$(date +%s)"
    fi
    
    # Check prerequisites
    if ! image_exists "$image_name"; then
        log_error "Image not found: $image_name. Run 'ralph.sh build' first."
        exit 1
    fi

    if [ "$task_type" = "issue" ] || { [ -z "$task_type" ] && [ "$mode_from_config" = "github" ]; }; then
        if [ -z "$GITHUB_TOKEN" ]; then
            log_error "GITHUB_TOKEN environment variable is required"
            exit 1
        fi
    else
        if [ -z "$GITHUB_TOKEN" ]; then
            log_warn "GITHUB_TOKEN not set. GitHub operations may fail."
        fi
    fi
    
    local cname=$(container_name "$project_name" "$task_id")
    
    # Check if container already exists
    if container_exists "$cname"; then
        if container_running "$cname"; then
            log_error "Container $cname is already running"
            exit 1
        else
            log_warn "Removing stopped container $cname"
            docker rm "$cname"
        fi
    fi
    
    # Resource limits
    local cpus="${RALPH_CPUS:-2}"
    local memory="${RALPH_MEMORY:-4g}"
    
    # Build docker run command
    local docker_args=(
        run
        --detach
        --name "$cname"
        --cpus="$cpus"
        --memory="$memory"
        -e "GITHUB_TOKEN=$GITHUB_TOKEN"
        -e "RALPH_TASK_ID=$task_id"
        --label "ralph.project=$project_name"
        --label "ralph.folder=$project_root"
    )

    if [ -d "$project_root/.ralph" ]; then
        docker_args+=(-v "$project_root/.ralph:/workspace/.ralph:ro")
    fi
    
    # Mount .env file if it exists (for pnpm install, etc.)
    if [ -f "$project_root/.env" ]; then
        docker_args+=(-v "$project_root/.env:/workspace/.env:ro")
    fi
    
    # Mount Docker socket if it exists (for pnpm dx, docker compose, etc.)
    if [ -S /var/run/docker.sock ]; then
        docker_args+=(-v "/var/run/docker.sock:/var/run/docker.sock")
        # Run as root to access Docker socket (socket permissions don't transfer well)
        # The agent tools (opencode/claude) handle their own security
        docker_args+=(--user root)
        # Use host network so container can reach localhost ports (e.g., databases)
        docker_args+=(--network host)
    fi
    
    # Add ANTHROPIC_API_KEY if set
    if [ -n "$ANTHROPIC_API_KEY" ]; then
        docker_args+=(-e "ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY")
    fi

    local opencode_auth_file="$HOME/.local/share/opencode/auth.json"
    if [ -f "$opencode_auth_file" ]; then
        docker_args+=(-v "$opencode_auth_file:/home/ralph/.local/share/opencode/auth.json:ro")
    fi

    local opencode_config_dir="$HOME/.config/opencode"
    if [ -d "$opencode_config_dir" ]; then
        docker_args+=(-v "$opencode_config_dir:/home/ralph/.config/opencode-host:ro")
    fi

    local claude_config_dir="$HOME/.config/claude"
    if [ -d "$claude_config_dir" ]; then
        docker_args+=(-v "$claude_config_dir:/home/ralph/.config/claude:ro")
    fi

    local claude_anthropic_dir="$HOME/.config/anthropic"
    if [ -d "$claude_anthropic_dir" ]; then
        docker_args+=(-v "$claude_anthropic_dir:/home/ralph/.config/anthropic:ro")
    fi

    local claude_home_dir="$HOME/.claude"
    if [ -d "$claude_home_dir" ]; then
        docker_args+=(-v "$claude_home_dir:/home/ralph/.claude:ro")
    fi
    
    # Add image and entrypoint args
    docker_args+=("$image_name")
    if [ -n "$task_type" ]; then
        docker_args+=("--$task_type" "$task_value")
    fi
    
    log_info "Starting container: $cname"
    log_info "Project: $project_name"
    if [ -n "$task_type" ]; then
        log_info "Task: $task_type = $task_value"
    else
        log_info "Task: auto (config)"
    fi
    log_info "Resources: $cpus CPUs, $memory memory"
    
    docker "${docker_args[@]}"
    
    log_success "Container started: $cname"
    echo ""
    echo "View logs:     ralph.sh logs $task_id"
    echo "Follow logs:   ralph.sh logs -f $task_id"
    echo "Stop:          ralph.sh stop $task_id"
}

# Format seconds into human readable time (e.g., "5m", "1h 23m", "2d 5h")
format_duration() {
    local seconds=$1
    if [ "$seconds" -lt 60 ]; then
        echo "${seconds}s"
    elif [ "$seconds" -lt 3600 ]; then
        echo "$((seconds / 60))m"
    elif [ "$seconds" -lt 86400 ]; then
        local hours=$((seconds / 3600))
        local mins=$(((seconds % 3600) / 60))
        if [ "$mins" -gt 0 ]; then
            echo "${hours}h ${mins}m"
        else
            echo "${hours}h"
        fi
    else
        local days=$((seconds / 86400))
        local hours=$(((seconds % 86400) / 3600))
        echo "${days}d ${hours}h"
    fi
}

# Get time since last log output in seconds
get_idle_seconds() {
    local container=$1
    local last_log_time=$(docker logs --timestamps "$container" 2>&1 | tail -1 | cut -d' ' -f1 | sed 's/Z$//')
    if [ -n "$last_log_time" ] && [ "$last_log_time" != "" ]; then
        # Convert ISO timestamp to epoch
        local last_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${last_log_time%%.*}" "+%s" 2>/dev/null || echo "")
        if [ -n "$last_epoch" ]; then
            local now_epoch=$(date "+%s")
            echo $((now_epoch - last_epoch))
            return
        fi
    fi
    echo "0"
}

# Check if agent is waiting for user input based on recent log output
# Returns: "waiting" if permission/input prompt detected, "active" otherwise
check_waiting_state() {
    local container=$1
    # Get last 20 lines of logs and check for common prompt patterns
    local recent_logs=$(docker logs "$container" 2>&1 | tail -20)
    
    # Patterns that indicate waiting for user input
    if echo "$recent_logs" | grep -qE '\[Y/n\]|\[y/N\]|Allow\?|Approve\?|yes/no|Confirm\?|Continue\?|Press Enter|waiting for|ask about this'; then
        echo "waiting"
    else
        echo "active"
    fi
}

cmd_list() {
    echo ""
    printf "%-12s %-12s %-10s %-10s %-6s %s\n" "PROJECT" "STATUS" "RUNNING" "IDLE" "TASK" "FOLDER"
    printf "%-12s %-12s %-10s %-10s %-6s %s\n" "────────────" "────────────" "──────────" "──────────" "──────" "────────────────"
    
    docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r name status; do
        # Extract task from container name (last part after project name)
        task="${name##*-}"
        
        # Get project from label, or extract from image name
        local project=$(docker inspect "$name" --format '{{index .Config.Labels "ralph.project"}}' 2>/dev/null)
        if [ -z "$project" ] || [ "$project" = "<no value>" ]; then
            project=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null | sed 's/^ralph-//')
        fi
        
        # Get folder from label (if available)
        local folder=$(docker inspect "$name" --format '{{index .Config.Labels "ralph.folder"}}' 2>/dev/null)
        if [ -z "$folder" ] || [ "$folder" = "<no value>" ]; then
            folder="-"
        else
            folder=$(basename "$folder")
        fi
        
        local idle_time="-"
        local uptime="-"
        
        # Parse status
        if [[ "$status" == *"Up"* ]]; then
            uptime=$(echo "$status" | sed 's/Up //' | sed 's/ (.*)//')
            
            # Check if agent process is running
            agent_running=$(docker exec "$name" ps -o comm= 2>/dev/null | grep -E "^(opencode|claude|node)$" | head -1)
            
            if [ -n "$agent_running" ]; then
                # Agent process exists - check how long since last output
                local idle_secs=$(get_idle_seconds "$name")
                idle_time=$(format_duration "$idle_secs")
                
                # Check if waiting for user input (permission prompt, etc.)
                local waiting_state=$(check_waiting_state "$name")
                
                if [ "$waiting_state" = "waiting" ]; then
                    state="${BLUE}⏸ waiting${NC}"
                elif [ "$idle_secs" -gt 120 ]; then
                    state="${BLUE}⏸ idle${NC}"
                else
                    state="${YELLOW}⚡ working${NC}"
                fi
            else
                state="${GREEN}✓ done${NC}"
            fi
        elif [[ "$status" == *"Exited (0)"* ]]; then
            state="${GREEN}✓ done${NC}"
        else
            state="${RED}✗ failed${NC}"
        fi
        
        printf "%-12s ${state}%-2s %-10s %-10s %-6s %s\n" "$project" "" "$uptime" "$idle_time" "$task" "$folder"
    done
    
    echo ""
}

cmd_logs() {
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
    fi
    
    local follow=false
    local task_id=""
    local collected_digits=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow=true
                shift
                ;;
            *)
                # Collect digits for "logs 2 1 9" -> issue-219
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    collected_digits="${collected_digits}${1}"
                else
                    task_id="$1"
                fi
                shift
                ;;
        esac
    done
    
    # Bare numbers -> treat as issue number
    if [ -n "$collected_digits" ] && [ -z "$task_id" ]; then
        task_id="issue-$collected_digits"
    fi
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh logs [-f] <task-id> | ralph.sh logs 42"
        exit 1
    fi
    
    # Try to find the container
    local cname=""
    
    # If we have project context, try project-specific names first
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    # Fall back to searching all containers
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        log_info "Available containers:"
        docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '  {{.Names}}'
        exit 1
    fi
    
    if [ "$follow" = true ]; then
        docker logs -f "$cname"
    else
        docker logs "$cname"
    fi
}

cmd_tail() {
    # Shorthand for logs -f
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
    fi
    
    parse_task_args "$@"
    local task_id="$PARSED_TASK_ID"
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh tail <task-id> | ralph.sh tail 42"
        exit 1
    fi
    
    # Find container
    local cname=""
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        log_info "Available containers:"
        docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '  {{.Names}}'
        exit 1
    fi
    
    docker logs -f "$cname"
}

cmd_restart() {
    # Restart a container with the same task
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    local project_root=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
        project_root="$config_dir"
    fi
    
    parse_task_args "$@"
    local task_id="$PARSED_TASK_ID"
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph restart <task-id> | ralph restart 42"
        exit 1
    fi
    
    # Find container
    local cname=""
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        log_info "Available containers:"
        docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '  {{.Names}}'
        exit 1
    fi
    
    # Extract task info from container name
    # Container name format: ralph-<project>-<task_id>
    local container_task_id
    container_task_id=$(echo "$cname" | sed "s/^${CONTAINER_PREFIX}-${project_name}-//")
    
    # Get folder from label (for running from different directory)
    local container_folder
    container_folder=$(docker inspect -f '{{index .Config.Labels "ralph.folder"}}' "$cname" 2>/dev/null || echo "")
    
    if [ -n "$container_folder" ] && [ -d "$container_folder" ]; then
        project_root="$container_folder"
    fi
    
    log_info "Stopping container: $cname"
    docker stop "$cname" 2>/dev/null || true
    docker rm "$cname" 2>/dev/null || true
    
    # Determine task type and value from task_id
    local task_type=""
    local task_value=""
    if [[ "$container_task_id" =~ ^issue-(.+)$ ]]; then
        task_type="issue"
        task_value="${BASH_REMATCH[1]}"
    elif [[ "$container_task_id" =~ ^prd-(.+)$ ]]; then
        task_type="prd"
        task_value="${BASH_REMATCH[1]}"
    else
        task_type="prompt"
        task_value="$container_task_id"
    fi
    
    log_info "Restarting task: $task_type $task_value"
    
    # Change to project directory and start
    if [ -n "$project_root" ] && [ -d "$project_root" ]; then
        cd "$project_root"
    fi
    
    # Re-run start command
    cmd_start "--$task_type" "$task_value"
}

cmd_stop() {
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
    fi
    
    local stop_all=false
    local task_id=""
    local task_type=""
    local task_value=""
    local collected_digits=""
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --all|-a)
                stop_all=true
                shift
                ;;
            --issue|--task)
                task_type="issue"
                task_value="$2"
                shift 2
                ;;
            --prd)
                task_type="prd"
                task_value="$2"
                shift 2
                ;;
            --prompt)
                task_type="prompt"
                task_value="$2"
                shift 2
                ;;
            issue)
                task_type="issue"
                task_value="$2"
                shift 2
                ;;
            prd)
                task_type="prd"
                task_value="$2"
                shift 2
                ;;
            prompt)
                task_type="prompt"
                task_value="$2"
                shift 2
                ;;
            *)
                # Collect digits for "stop 2 1 9" -> issue-219
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    collected_digits="${collected_digits}${1}"
                elif [ -z "$task_id" ]; then
                    task_id="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -n "$task_type" ]; then
        case "$task_type" in
            issue) task_id="issue-$task_value" ;;
            prd) task_id="prd-$(basename "$task_value")" ;;
            prompt) task_id="$task_value" ;;
        esac
    elif [ -n "$collected_digits" ]; then
        # Bare numbers -> treat as issue number
        task_id="issue-$collected_digits"
    fi
    
    if [ "$stop_all" = true ]; then
        local filter="name=${CONTAINER_PREFIX}-"
        if [ -n "$project_name" ]; then
            filter="name=${CONTAINER_PREFIX}-${project_name}-"
            log_info "Stopping all Ralph containers for project: $project_name"
        else
            log_info "Stopping all Ralph containers..."
        fi
        
        local containers=$(docker ps -q --filter "$filter")
        if [ -n "$containers" ]; then
            docker stop $containers
            docker rm $containers
            log_success "Containers stopped and removed"
        else
            log_info "No running containers found"
        fi
        return
    fi
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID or --all"
        echo "Usage: ralph.sh stop <task-id> | ralph.sh stop --issue <number> | --all"
        exit 1
    fi
    
    # Find container (similar logic to logs)
    local cname=""
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        exit 1
    fi
    
    log_info "Stopping container: $cname"
    docker stop "$cname" 2>/dev/null || true
    docker rm "$cname"
    log_success "Container stopped and removed: $cname"
}

cmd_status() {
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
    fi
    
    parse_task_args "$@"
    local task_id="$PARSED_TASK_ID"
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh status <task-id> | ralph.sh status 42"
        exit 1
    fi
    
    # Find container
    local cname=""
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        exit 1
    fi
    
    echo ""
    echo "Container: $cname"
    echo "─────────────────────────────────────────"
    
    docker inspect "$cname" --format '
Status:    {{.State.Status}}
Started:   {{.State.StartedAt}}
Finished:  {{if eq .State.FinishedAt "0001-01-01T00:00:00Z"}}-{{else}}{{.State.FinishedAt}}{{end}}
Exit Code: {{.State.ExitCode}}
'
    
    if container_running "$cname"; then
        echo ""
        echo "Git Status:"
        docker exec "$cname" git -C /workspace status --short 2>/dev/null || echo "  (unable to get git status)"
        
        echo ""
        echo "Current Branch:"
        docker exec "$cname" git -C /workspace branch --show-current 2>/dev/null || echo "  (unable to get branch)"
        
        echo ""
        echo "Recent Commits:"
        docker exec "$cname" git -C /workspace log --oneline -3 2>/dev/null || echo "  (no commits yet)"
    fi
    
    echo ""
}

cmd_shell() {
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
    fi
    
    parse_task_args "$@"
    local task_id="$PARSED_TASK_ID"
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh shell <task-id> | ralph.sh shell 42"
        exit 1
    fi
    
    # Find container
    local cname=""
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        exit 1
    fi
    
    if ! container_running "$cname"; then
        log_error "Container is not running: $cname"
        exit 1
    fi
    
    log_info "Opening shell in: $cname"
    docker exec -it "$cname" /bin/bash
}

cmd_attach() {
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
    fi
    
    local task_id=""
    local task_type=""
    local task_value=""
    local collected_digits=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --issue|--task)
                task_type="issue"
                task_value="$2"
                shift 2
                ;;
            --prd)
                task_type="prd"
                task_value="$2"
                shift 2
                ;;
            --prompt)
                task_type="prompt"
                task_value="$2"
                shift 2
                ;;
            issue)
                task_type="issue"
                task_value="$2"
                shift 2
                ;;
            prd)
                task_type="prd"
                task_value="$2"
                shift 2
                ;;
            *)
                # Collect digits for "attach 2 1 9" -> issue-219
                if [[ "$1" =~ ^[0-9]+$ ]]; then
                    collected_digits="${collected_digits}${1}"
                elif [ -z "$task_id" ]; then
                    task_id="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -n "$task_type" ]; then
        case "$task_type" in
            issue) task_id="issue-$task_value" ;;
            prd) task_id="prd-$(basename "$task_value")" ;;
            prompt) task_id="$task_value" ;;
        esac
    elif [ -n "$collected_digits" ]; then
        # Bare numbers -> treat as issue number
        task_id="issue-$collected_digits"
    fi

    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh attach <task-id> | ralph.sh attach 42 | ralph.sh attach --issue <number>"
        exit 1
    fi
    
    # Find container
    local cname=""
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        exit 1
    fi
    
    if ! container_running "$cname"; then
        log_error "Container is not running: $cname"
        log_info "The agent may have completed or failed. Check logs with:"
        echo "  ralph.sh logs $task_id"
        exit 1
    fi
    
    log_info "Attaching to agent in: $cname"
    log_info "Resuming opencode session..."
    echo ""
    
    # Run opencode --continue to resume the session interactively
    docker exec -it -w /workspace "$cname" opencode --continue
}

cmd_clean() {
    log_info "Cleaning up stopped Ralph containers..."
    
    local stopped=$(docker ps -aq --filter "name=${CONTAINER_PREFIX}-" --filter "status=exited")
    if [ -n "$stopped" ]; then
        docker rm $stopped
        log_success "Removed stopped containers"
    else
        log_info "No stopped containers to remove"
    fi
    
    log_info "Removing dangling images..."
    docker image prune -f
    
    log_success "Cleanup complete"
}

# Send macOS notification
notify_macos() {
    local title="$1"
    local message="$2"
    local sound="${3:-Glass}"
    
    if command -v osascript &>/dev/null; then
        osascript -e "display notification \"$message\" with title \"$title\" sound name \"$sound\""
    fi
}

cmd_watch() {
    # Track containers we've already notified about (use temp file for compatibility)
    local notified_file=$(mktemp)
    # Track which containers had agent running (to detect transition to done)
    local working_file=$(mktemp)
    trap "rm -f $notified_file $working_file; tput cnorm 2>/dev/null" EXIT
    
    # Hide cursor for cleaner display
    tput civis 2>/dev/null || true
    
    # Warm-up: record already-exited containers and already-done containers
    docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r name status; do
        if [[ "$status" == *"Exited"* ]]; then
            echo "$name" >> "$notified_file"
        elif [[ "$status" == *"Up"* ]]; then
            local agent_running=$(docker exec "$name" ps -o comm= 2>/dev/null | grep -E "^(opencode|claude|node)$" | head -1)
            if [ -n "$agent_running" ]; then
                echo "$name" >> "$working_file"
            else
                echo "$name" >> "$notified_file"
            fi
        fi
    done
    
    while true; do
        # Move cursor to top and clear screen
        tput home 2>/dev/null || clear
        tput ed 2>/dev/null || true
        
        # Header
        echo ""
        echo -e "${BLUE}Ralph Watch${NC} - Live container status (Ctrl+C to exit)"
        echo -e "Updated: $(date '+%H:%M:%S')"
        echo ""
        printf "%-12s %-12s %-10s %-10s %-6s %s\n" "PROJECT" "STATUS" "RUNNING" "IDLE" "TASK" "FOLDER"
        printf "%-12s %-12s %-10s %-10s %-6s %s\n" "────────────" "────────────" "──────────" "──────────" "──────" "────────────────"
        
        # Get all Ralph containers and display + check for notifications
        local container_count=0
        while IFS=$'\t' read -r name status; do
            [ -z "$name" ] && continue
            container_count=$((container_count + 1))
            local task="${name##*-}"
            
            # Get project from label, or extract from image name
            local project=$(docker inspect "$name" --format '{{index .Config.Labels "ralph.project"}}' 2>/dev/null)
            if [ -z "$project" ] || [ "$project" = "<no value>" ]; then
                project=$(docker inspect "$name" --format '{{.Config.Image}}' 2>/dev/null | sed 's/^ralph-//')
            fi
            
            # Get folder from label (if available)
            local folder=$(docker inspect "$name" --format '{{index .Config.Labels "ralph.folder"}}' 2>/dev/null)
            if [ -z "$folder" ] || [ "$folder" = "<no value>" ]; then
                folder="-"
            else
                folder=$(basename "$folder")
            fi
            
            local idle_time="-"
            local uptime="-"
            
            # Parse status for display
            if [[ "$status" == *"Up"* ]]; then
                uptime=$(echo "$status" | sed 's/Up //' | sed 's/ (.*)//')
                local agent_running=$(docker exec "$name" ps -o comm= 2>/dev/null | grep -E "^(opencode|claude|node)$" | head -1)
                
                if [ -n "$agent_running" ]; then
                    # Agent process exists - check how long since last output
                    local idle_secs=$(get_idle_seconds "$name")
                    idle_time=$(format_duration "$idle_secs")
                    
                    # Check if waiting for user input (permission prompt, etc.)
                    local waiting_state=$(check_waiting_state "$name")
                    
                    if [ "$waiting_state" = "waiting" ]; then
                        state="${BLUE}⏸ waiting${NC}"
                    elif [ "$idle_secs" -gt 120 ]; then
                        state="${BLUE}⏸ idle${NC}"
                    else
                        state="${YELLOW}⚡ working${NC}"
                    fi
                    
                    # Mark as working if not already
                    if ! grep -qx "$name" "$working_file" 2>/dev/null; then
                        echo "$name" >> "$working_file"
                    fi
                else
                    state="${GREEN}✓ done${NC}"
                    # Check if it transitioned from working to done
                    if grep -qx "$name" "$working_file" 2>/dev/null && ! grep -qx "$name" "$notified_file" 2>/dev/null; then
                        notify_macos "Ralph: $project complete" "Task $task finished successfully" "Glass"
                        echo "$name" >> "$notified_file"
                    fi
                fi
            elif [[ "$status" == *"Exited (0)"* ]]; then
                state="${GREEN}✓ done${NC}"
                # Notify if not already
                if ! grep -qx "$name" "$notified_file" 2>/dev/null; then
                    if grep -qx "$name" "$working_file" 2>/dev/null; then
                        notify_macos "Ralph: $project complete" "Task $task finished successfully" "Glass"
                    fi
                    echo "$name" >> "$notified_file"
                fi
            else
                state="${RED}✗ failed${NC}"
                # Notify if not already
                if ! grep -qx "$name" "$notified_file" 2>/dev/null; then
                    notify_macos "Ralph: $project failed" "Task $task exited with error" "Basso"
                    echo "$name" >> "$notified_file"
                fi
            fi
            
            printf "%-12s ${state}%-2s %-10s %-10s %-6s %s\n" "$project" "" "$uptime" "$idle_time" "$task" "$folder"
        done < <(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}')
        
        if [ "$container_count" -eq 0 ]; then
            echo -e "  ${YELLOW}No Ralph containers running${NC}"
        fi
        
        echo ""
        sleep 5
    done
}

cmd_notify() {
    # Manual notification test / send notification for a specific container
    local task_id="$1"
    
    if [ -z "$task_id" ]; then
        # Just test notification
        notify_macos "Ralph Test" "Notifications are working!" "Glass"
        log_success "Test notification sent"
        return
    fi
    
    # Find and check specific container
    local config_dir
    config_dir=$(find_ralph_config) || true
    
    local project_name=""
    if [ -n "$config_dir" ]; then
        project_name=$(get_project_name "$config_dir")
    fi
    
    local cname=""
    if [ -n "$project_name" ]; then
        for pattern in "$task_id" "issue-$task_id"; do
            local try_name="${CONTAINER_PREFIX}-${project_name}-${pattern}"
            if container_exists "$try_name"; then
                cname="$try_name"
                break
            fi
        done
    fi
    
    if [ -z "$cname" ]; then
        cname=$(docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}' | grep -E "(^|-)${task_id}$" | head -1)
    fi
    
    if [ -z "$cname" ]; then
        log_error "Container not found for task: $task_id"
        exit 1
    fi
    
    local status=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null)
    local exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$cname" 2>/dev/null)
    
    if [ "$status" = "running" ]; then
        # Check if agent is still working
        local agent_running=$(docker exec "$cname" ps -o comm= 2>/dev/null | grep -E "^(opencode|claude|node)$" | head -1)
        if [ -n "$agent_running" ]; then
            notify_macos "Ralph: $project_name" "Task $task_id is still running..."
        else
            notify_macos "Ralph: $project_name" "Task $task_id completed, waiting for review"
        fi
    elif [ "$exit_code" = "0" ]; then
        notify_macos "Ralph: $project_name complete" "Task $task_id finished successfully" "Glass"
    else
        notify_macos "Ralph: $project_name failed" "Task $task_id exited with code $exit_code" "Basso"
    fi
    
    log_success "Notification sent"
}

# ============================================================
# Main
# ============================================================

if [ $# -eq 0 ]; then
    show_usage
    exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
    build-base)
        cmd_build_base "$@"
        ;;
    init)
        cmd_init "$@"
        ;;
    build)
        cmd_build "$@"
        ;;
    start)
        cmd_start "$@"
        ;;
    list|ls)
        cmd_list "$@"
        ;;
    logs)
        cmd_logs "$@"
        ;;
    tail)
        cmd_tail "$@"
        ;;
    restart)
        cmd_restart "$@"
        ;;
    stop)
        cmd_stop "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    shell|sh)
        cmd_shell "$@"
        ;;
    attach)
        cmd_attach "$@"
        ;;
    clean)
        cmd_clean "$@"
        ;;
    watch)
        cmd_watch "$@"
        ;;
    notify)
        cmd_notify "$@"
        ;;
    -h|--help|help)
        show_usage
        ;;
    -v|--version)
        echo "ralph $VERSION"
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        show_usage
        exit 1
        ;;
esac
