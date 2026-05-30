#!/usr/bin/env bash
# start-docker — start a create-docker project
#
# Ensures the global Traefik proxy is running, then brings up the project
# containers. Safe to run if containers are already up (idempotent).
#
# Usage:
#   start-docker              # lists projects and prompts for selection
#   start-docker my-project   # skips the selection prompt

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
ORANGE='\033[0;33m'  # Used for DOCKER rows in logo (→ Gruvbox yellow #d8a657)
BOLD='\033[1m'
RESET='\033[0m'

# ─── Paths ────────────────────────────────────────────────────────────────────

DEV_DIR="${CREATE_DOCKER_DIR:-$HOME/Dev}"
PROXY_DIR="$DEV_DIR/.proxy"

# ─── Output helpers ───────────────────────────────────────────────────────────

info()    { echo -e "${BLUE}  →${RESET} $*"; }
success() { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  !${RESET} $*"; }
die()     { echo -e "${RED}  ✗${RESET} $*" >&2; exit 1; }

# ─── Header ───────────────────────────────────────────────────────────────────
#
# Pixel art logo inspired by the Omarchy block-character branding style.
# Each letter is 5 columns × 5 rows. Two colours map to the Gruvbox palette:
#   GREEN  → terminal color2 → positive/start action
#   ORANGE → terminal color3 → #d8a657 (warm yellow)

print_header() {
    echo ""
    echo -e "${GREEN}   ████ █████  ███  ████  █████${RESET}"
    echo -e "${GREEN}  █       █   █   █ █   █   █  ${RESET}"
    echo -e "${GREEN}   ███    █   █████ ████    █  ${RESET}"
    echo -e "${GREEN}      █   █   █   █ █ █     █  ${RESET}"
    echo -e "${GREEN}  ████    █   █   █ █  ██   █  ${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █   █${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     ███   ████  ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █ █  ${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ █  ██${RESET}"
    echo ""
    echo -e "  start a create-docker project"
    echo "  ─────────────────────────────────────────"
    echo ""
}

# ─── Proxy ────────────────────────────────────────────────────────────────────

ensure_proxy_running() {
    if [ ! -f "$PROXY_DIR/docker-compose.yml" ]; then
        die "Global proxy not found. Run create-docker first to set it up."
    fi

    if docker compose -f "$PROXY_DIR/docker-compose.yml" ps --quiet 2>/dev/null | grep -q .; then
        return  # already running
    fi

    info "Starting global proxy..."
    docker compose -f "$PROXY_DIR/docker-compose.yml" up -d
    success "Global proxy started."
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    print_header

    local slug=""

    # ── Resolve project slug ──────────────────────────────────────────────────
    if [ -n "${1:-}" ]; then
        slug="$1"
        echo -e "  ${BOLD}Project:${RESET} $slug"
    else
        local -a projects=()
        for dir in "$DEV_DIR"/*/; do
            [ -d "$dir" ] || continue
            local name
            name=$(basename "$dir")
            [[ "$name" == .* ]] && continue
            [ -f "$dir/docker-compose.yml" ] || continue
            projects+=("$name")
        done

        if [ ${#projects[@]} -eq 0 ]; then
            die "No projects found in $DEV_DIR"
        fi

        echo -e "  ${BOLD}Select project to start:${RESET}"
        echo ""
        PS3="  > "
        select choice in "${projects[@]}"; do
            if [ -n "$choice" ]; then
                slug="$choice"
                break
            else
                warn "Please enter a valid number."
            fi
        done
    fi

    # ── Validate ──────────────────────────────────────────────────────────────
    local project_dir="$DEV_DIR/$slug"
    [ -d "$project_dir" ] || die "Project '$slug' not found at $project_dir"
    [ -f "$project_dir/docker-compose.yml" ] || die "No docker-compose.yml found in $project_dir"

    # ── Ensure proxy is up ────────────────────────────────────────────────────
    ensure_proxy_running

    # ── Start project ─────────────────────────────────────────────────────────
    echo ""
    info "Starting ${BOLD}${slug}${RESET}..."
    docker compose -f "$project_dir/docker-compose.yml" up -d
    echo ""
    echo "  ─────────────────────────────────────"
    success "Project '${slug}' is running."
    echo ""
    echo -e "  ${BOLD}https://${slug}.test${RESET}"
    echo "  ─────────────────────────────────────"
    echo ""
}

main "$@"
