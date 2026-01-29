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
  attach               Connect to agent for follow-up instructions
  list                 List all Ralph containers
  logs                 View container logs
  stop                 Stop container(s)
  status               Show detailed status of a container
  shell                Open interactive shell in container
  watch                Watch containers and send macOS notifications on completion
  notify [task]        Send a test notification (or check status of a task)
  clean                Remove all stopped containers
  init                 Initialize ralph config in current project

Start Options:
  --issue <number>     Work on a specific GitHub issue
  --task <number>      Alias for --issue
  --prd <file>         Use PRD mode with the given PRD file
  --prompt <text>      Use a custom prompt
  (no args)            Let Ralph choose its own task based on config.json

Examples:
  ralph.sh build-base                    # Build base image (one time)
  ralph.sh init                          # Set up ralph in current project
  ralph.sh build                         # Build project image
  ralph.sh start                         # Let Ralph choose a task
  ralph.sh start --issue 42              # Start agent on issue
  ralph.sh start issue 42                # Start agent using type + id
  ralph.sh attach issue-42               # Connect for follow-up work
  ralph.sh attach issue 42               # Connect using type + id
  ralph.sh attach --issue 42             # Connect using flags
  ralph.sh list                          # List all containers
  ralph.sh logs -f issue-42              # Follow logs
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

cmd_init() {
    local target_dir="${1:-.}"
    
    log_info "Initializing ralph in $target_dir..."
    
    mkdir -p "$target_dir/ralph" "$target_dir/.ralph"
    
    if [ -f "$target_dir/.ralph/config.json" ]; then
        log_warn ".ralph/config.json already exists, leaving it unchanged"
    else
        cp "$SCRIPT_DIR/templates/config.json" "$target_dir/.ralph/config.json"
        log_info "Created .ralph/config.json"
    fi
    
    if [ -f "$target_dir/ralph/Dockerfile" ]; then
        log_warn "ralph/Dockerfile already exists, leaving it unchanged"
    else
        cp "$SCRIPT_DIR/templates/Dockerfile" "$target_dir/ralph/"
    fi
    
    if [ -f "$target_dir/ralph/prompt.md" ]; then
        log_warn "ralph/prompt.md already exists, leaving it unchanged"
    else
        cp "$SCRIPT_DIR/templates/prompt.md" "$target_dir/ralph/"
    fi
    
    log_success "Ralph config initialized"
    echo ""
    echo "Next steps:"
    echo "  1. Edit .ralph/config.json with your project details"
    echo "  2. Edit ralph/Dockerfile if needed"
    echo "  3. Run: ralph.sh build"
    echo "  4. Run: ralph.sh start --issue <number>"
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
    
    # Check for GITHUB_TOKEN (needed for private repo clone)
    if [ -z "$GITHUB_TOKEN" ]; then
        log_warn "No GITHUB_TOKEN set. Build may fail for private repos."
    fi
    
    local build_args=""
    if [ -n "$GITHUB_TOKEN" ]; then
        build_args="--build-arg GITHUB_TOKEN=$GITHUB_TOKEN"
    fi
    
    # Build from the project's ralph directory
    docker build $build_args -t "$image_name" "$project_root/ralph"
    
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
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done
    
    if [ -z "$task_type" ]; then
        task_id="auto-$(date +%s)"
    fi
    
    # Check prerequisites
    if ! image_exists "$image_name"; then
        log_error "Image not found: $image_name. Run 'ralph.sh build' first."
        exit 1
    fi
    
    local mode_from_config
    mode_from_config=$(jq -r '.mode // "github"' "$config_file")

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
    )

    if [ -d "$project_root/.ralph" ]; then
        docker_args+=(-v "$project_root/.ralph:/workspace/.ralph:ro")
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

cmd_list() {
    echo ""
    printf "%-40s %-15s %-15s %s\n" "CONTAINER" "STATUS" "UPTIME" "TASK"
    printf "%-40s %-15s %-15s %s\n" "────────────────────────────────────────" "───────────────" "───────────────" "────────────────────"
    
    docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r name status; do
        # Extract task from container name (last part after project name)
        task="${name##*-}"
        
        # Parse status
        if [[ "$status" == *"Up"* ]]; then
            uptime=$(echo "$status" | sed 's/Up //')
            # Check if agent is actively working or idle
            agent_running=$(docker exec "$name" ps -o comm= 2>/dev/null | grep -E "^(opencode|claude|node)$" | head -1)
            if [ -n "$agent_running" ]; then
                state="${YELLOW}⚡ working${NC}"
            else
                state="${GREEN}✓ done${NC}"
            fi
        elif [[ "$status" == *"Exited (0)"* ]]; then
            state="${GREEN}✓ done${NC}"
            uptime="-"
        else
            state="${RED}✗ failed${NC}"
            uptime="-"
        fi
        
        printf "%-40s ${state}%-5s %-15s %s\n" "$name" "" "$uptime" "$task"
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
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--follow)
                follow=true
                shift
                ;;
            *)
                task_id="$1"
                shift
                ;;
        esac
    done
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh logs [-f] <task-id>"
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
                if [ -z "$task_id" ]; then
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
    
    local task_id="$1"
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh status <task-id>"
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
    
    local task_id="$1"
    
    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh shell <task-id>"
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
                if [ -z "$task_id" ]; then
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
    fi

    if [ -z "$task_id" ]; then
        log_error "Must specify a task ID"
        echo "Usage: ralph.sh attach <task-id> | ralph.sh attach --issue <number>"
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
    log_info "Watching Ralph containers for completion..."
    log_info "Press Ctrl+C to stop watching"
    echo ""
    
    # Track containers we've already notified about (use temp file for compatibility)
    local notified_file=$(mktemp)
    trap "rm -f $notified_file" EXIT
    
    # Warm-up: record already-exited containers so we don't notify about them
    docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r name status; do
        if [[ "$status" == *"Exited"* ]]; then
            echo "$name" >> "$notified_file"
        fi
    done
    
    local running_count=$(docker ps --filter "name=${CONTAINER_PREFIX}-" -q | wc -l | tr -d ' ')
    log_info "Watching $running_count running container(s)..."
    echo ""
    
    while true; do
        # Get all Ralph containers
        docker ps -a --filter "name=${CONTAINER_PREFIX}-" --format '{{.Names}}\t{{.Status}}' | while IFS=$'\t' read -r name status; do
            # Skip if we've already notified
            if grep -qx "$name" "$notified_file" 2>/dev/null; then
                continue
            fi
            
            # Check if container just finished
            if [[ "$status" == *"Exited"* ]]; then
                local task="${name##*-}"
                local project="${name#${CONTAINER_PREFIX}-}"
                project="${project%-*}"
                
                if [[ "$status" == *"Exited (0)"* ]]; then
                    log_success "Container finished: $name"
                    notify_macos "Ralph: $project complete" "Task $task finished successfully" "Glass"
                else
                    log_error "Container failed: $name"
                    notify_macos "Ralph: $project failed" "Task $task exited with error" "Basso"
                fi
                echo "$name" >> "$notified_file"
            fi
        done
        
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
