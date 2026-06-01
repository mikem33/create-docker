#!/usr/bin/env bash
# delete-docker — remove a create-docker project
#
# Stops and removes all containers, volumes, and locally-built images for the
# project, then deletes the project folder, TLS certificate, Traefik config,
# and /etc/hosts entries.
#
# Shared resources (base Docker images, the proxy, other projects) are untouched.
#
# Usage:
#   delete-docker              # lists projects and prompts for selection
#   delete-docker my-project   # skips the selection prompt

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
CERTS_DIR="$PROXY_DIR/certs"

# ─── Output helpers ───────────────────────────────────────────────────────────

info()    { echo -e "${BLUE}  →${RESET} $*"; }
success() { echo -e "${GREEN}  ✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}  !${RESET} $*"; }
die()     { echo -e "${RED}  ✗${RESET} $*" >&2; exit 1; }

# ─── Header ───────────────────────────────────────────────────────────────────
#
# Pixel art logo inspired by the Omarchy block-character branding style.
# Each letter is 5 columns × 5 rows. Two colours map to the Gruvbox palette:
#   RED    → terminal color1 → destructive action
#   ORANGE → terminal color3 → #d8a657 (warm yellow)

print_header() {
    echo ""
    echo -e "${RED}  ████  █████ █     █████ █████ █████${RESET}"
    echo -e "${RED}  █   █ █     █     █       █   █    ${RESET}"
    echo -e "${RED}  █   █ ████  █     ████    █   ████ ${RESET}"
    echo -e "${RED}  █   █ █     █     █       █   █    ${RESET}"
    echo -e "${RED}  ████  █████ █████ █████   █   █████${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █   █${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     ███   ████  ████ ${RESET}"
    echo -e "${ORANGE}  █   █ █   █ █     █  █  █     █ █  ${RESET}"
    echo -e "${ORANGE}  ████   ███   ████ █   █ █████ █  ██${RESET}"
    echo ""
    echo -e "  remove a create-docker project"
    echo "  ─────────────────────────────────────────"
    echo ""
}

# ─── /etc/hosts removal ───────────────────────────────────────────────────────

remove_hosts_entry() {
    local domain="$1"

    if grep -qF "$domain" /etc/hosts; then
        info "Removing ${BOLD}${domain}${RESET} from /etc/hosts (requires sudo)..."
        # Escape dots so sed treats them as literals, not regex wildcards
        local escaped
        escaped=$(printf '%s' "$domain" | sed 's/\./\\./g')
        sudo sed -i "/[[:space:]]${escaped}$/d" /etc/hosts
        success "Removed: $domain"
    fi
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
        # Discover projects: any non-hidden dir under $DEV_DIR with a docker-compose.yml
        local -a projects=()
        for dir in "$DEV_DIR"/*/; do
            [ -d "$dir" ] || continue
            local name
            name=$(basename "$dir")
            [[ "$name" == .* ]] && continue          # skip .proxy and other hidden dirs
            [ -f "$dir/docker-compose.yml" ] || continue
            projects+=("$name")
        done

        if [ ${#projects[@]} -eq 0 ]; then
            die "No projects found in $DEV_DIR"
        fi

        echo -e "  ${BOLD}Select project to delete:${RESET}"
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

    # ── Summary and confirmation ──────────────────────────────────────────────
    echo ""
    echo -e "  ${BOLD}What will be deleted:${RESET}"
    echo "  ─────────────────────────────────────"
    echo "  Containers + volumes  $slug-*"
    echo "  Project folder        $project_dir"
    echo "  TLS certificate       $CERTS_DIR/${slug}.pem"
    echo "  Traefik config        $PROXY_DIR/conf/${slug}.yml"
    echo "  /etc/hosts entries    ${slug}.test (and -db/-mail if present)"
    echo "  ─────────────────────────────────────"
    echo ""
    echo -e "  ${RED}${BOLD}This cannot be undone.${RESET}"
    echo ""
    read -rp "  Delete '${slug}'? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo "  Aborted."; exit 0; }
    echo ""

    # ── 1. Stop containers, remove volumes, remove locally-built images ───────
    if [ -f "$project_dir/docker-compose.yml" ]; then
        info "Stopping containers and removing volumes..."
        # --rmi local  → removes images built from a Dockerfile in this project
        #                leaves untouched: mysql, nginx, phpmyadmin, mailhog, etc.
        # -v           → removes named volumes (db_data — project-specific data)
        docker compose -f "$project_dir/docker-compose.yml" down -v --rmi local 2>/dev/null || true
        success "Containers and volumes removed."
    fi

    # ── 2. Remove project folder ──────────────────────────────────────────────
    # cd away first so the shell is not left inside a deleted directory
    cd "$DEV_DIR"
    info "Removing project folder..."
    rm -rf "$project_dir"
    success "Removed: $project_dir"

    # ── 3. Remove TLS certificate and Traefik dynamic config ─────────────────
    rm -f "$CERTS_DIR/${slug}.pem" "$CERTS_DIR/${slug}-key.pem"
    rm -f "$PROXY_DIR/conf/${slug}.yml"
    success "TLS certificate and Traefik config removed."

    # ── 4. Remove /etc/hosts entries ──────────────────────────────────────────
    echo ""
    remove_hosts_entry "${slug}.test"
    remove_hosts_entry "${slug}-db.test"
    remove_hosts_entry "${slug}-mail.test"

    # ── Done ──────────────────────────────────────────────────────────────────
    echo ""
    echo "  ─────────────────────────────────────"
    echo -e "  ${GREEN}${BOLD}Done.${RESET} Project '${slug}' has been removed."
    echo "  ─────────────────────────────────────"
    echo ""
}

main "$@"
