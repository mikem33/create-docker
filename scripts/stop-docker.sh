#!/usr/bin/env bash
# stop-docker — stop a create-docker project
#
# Stops the project containers without removing them or their volumes.
# The global Traefik proxy is left running (it is shared across projects).
#
# Usage:
#   stop-docker              # lists running projects and prompts for selection
#   stop-docker my-project   # skips the selection prompt

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

# ─── Output helpers ───────────────────────────────────────────────────────────

info()    { echo -e "${BLUE}  →${RESET} $*"; }
success() { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  !${RESET} $*"; }
die()     { echo -e "${RED}  ✗${RESET} $*" >&2; exit 1; }

# ─── Header ───────────────────────────────────────────────────────────────────
#
# Pixel art logo inspired by the Omarchy block-character branding style.
# Each letter is 5 columns × 5 rows. Two colours map to the Gruvbox palette:
#   YELLOW → terminal color3 → pause/caution action
#   ORANGE → terminal color3 → #d8a657 (warm yellow)

print_header() {
    echo ""
    echo -e "${YELLOW}   ████ █████  ███  ████ ${RESET}"
    echo -e "${YELLOW}  █       █   █   █ █   █${RESET}"
    echo -e "${YELLOW}   ███    █   █   █ ████ ${RESET}"
    echo -e "${YELLOW}      █   █   █   █ █    ${RESET}"
    echo -e "${YELLOW}  ████    █    ███  █    ${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █   █${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     ███   ████  ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █ █  ${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ █  ██${RESET}"
    echo ""
    echo -e "  stop a create-docker project"
    echo "  ─────────────────────────────────────────"
    echo ""
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

        echo -e "  ${BOLD}Select project to stop:${RESET}"
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

    # ── Stop project ──────────────────────────────────────────────────────────
    echo ""
    info "Stopping ${BOLD}${slug}${RESET}..."
    docker compose -f "$project_dir/docker-compose.yml" stop
    echo ""
    echo "  ─────────────────────────────────────"
    success "Project '${slug}' stopped. Data is preserved."
    echo -e "  Run ${BOLD}start-docker ${slug}${RESET} to bring it back up."
    echo "  ─────────────────────────────────────"
    echo ""
}

main "$@"
