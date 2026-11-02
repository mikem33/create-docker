#!/usr/bin/env bash
#
# pnpm — run pnpm inside the current Vite project's container, as if it were local.
#
# Finds the enclosing generated project by walking up from the working
# directory. If it is a Vite project (its docker-compose.yml has a "vite"
# service), pnpm runs in that container and mirrors your location: run it from
# src/packages/foo and pnpm starts in /app/packages/foo. Its output stays in
# your terminal and Ctrl+C stops it, so `pnpm dev` behaves as it does locally.
#
# Anywhere else (no project, or a PHP/WordPress one) it hands over to the
# host's own pnpm untouched, so projects outside Docker keep working.
#
# Symlink it onto your PATH as "pnpm", ahead of the host's pnpm:
#   ln -s ~/Dev/create-docker/scripts/pnpm.sh ~/.local/bin/pnpm

set -euo pipefail

RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; BLUE=$'\033[0;34m'; RESET=$'\033[0m'
die() { echo "${RED}✗${RESET} $*" >&2; exit 1; }

# ─── Host pnpm ───────────────────────────────────────────────────────────────
# The next "pnpm" on PATH that is not this script (or a symlink to it).

run_host_pnpm() {
    local self candidate
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    while IFS= read -r candidate; do
        [[ "$(readlink -f "$candidate")" == "$self" ]] && continue
        exec "$candidate" "$@"
    done < <(type -ap pnpm)
    die "Not inside a Docker Vite project, and pnpm is not installed on this machine."
}

# ─── Locate the project ──────────────────────────────────────────────────────
# Walk up from $PWD until a docker-compose.yml turns up.

root="$PWD"
while [[ "$root" != "/" && ! -f "$root/docker-compose.yml" ]]; do
    root="$(dirname "$root")"
done

# Only Vite projects have a "vite" service; anything else is the host's business.
if [[ ! -f "$root/docker-compose.yml" ]] || ! grep -q '^  vite:' "$root/docker-compose.yml"; then
    run_host_pnpm "$@"
fi

# ─── Find the running container ──────────────────────────────────────────────
# Ask Compose rather than guessing "<dirname>-vite": the container_name is fixed
# at creation time, so a renamed project directory would break name guessing.

container="$(docker compose --project-directory "$root" ps -q vite 2>/dev/null | head -1)" || true
if [[ -z "$container" ]]; then
    die "The Vite container is not running. Start it first: start-docker $(basename "$root")"
fi

# ─── Mirror the working directory ────────────────────────────────────────────
# Host <root>/src is mounted at /app, so a path below src/ maps across
# one-to-one. Anywhere else in the project falls back to /app.

workdir="/app"
src="$root/src"
if [[ "$PWD" == "$src"/* ]]; then
    workdir="/app/${PWD#"$src"/}"
elif [[ "$PWD" != "$src" && "$PWD" != "$root" ]]; then
    # somewhere like nginx/ — the mapping does not reach here, so say so once
    echo "${YELLOW}!${RESET} $PWD is outside src/; running from src/ instead." >&2
fi

# ─── Hand over to pnpm ───────────────────────────────────────────────────────
# One line on stderr says where it runs, since the command looks local.
# -i keeps stdin open so piped input works; -t only when stdout is a terminal,
# so pnpm keeps its colours and prompts and Ctrl+C reaches `pnpm dev`, while
# piping into grep or jq stays clean.

name="$(docker inspect -f '{{.Name}}' "$container")"
echo "${BLUE}→${RESET} pnpm in ${name#/}" >&2

exec_flags=(-i)
[[ -t 1 ]] && exec_flags+=(-t)

# Docker does not stop an exec'd process when its client goes away, so closing
# the terminal would leave `pnpm dev` running in the container, and the next
# one would quietly move to another port nginx does not proxy. The process
# inside records its PID; on hangup or termination the wrapper stops it.
# (Ctrl+C needs none of this: it reaches pnpm through the TTY.)

pidfile="/tmp/pnpm-wrapper-$$.pid"
in_container() { docker exec "$container" sh -c "$1" sh "$pidfile" >/dev/null 2>&1 || true; }
stop_inside() { in_container '[ -f "$1" ] && kill -TERM "$(cat "$1")"; rm -f "$1"'; }
trap 'stop_inside; exit 129' HUP
trap 'stop_inside; exit 143' TERM

status=0
docker exec "${exec_flags[@]}" -w "$workdir" "$container" \
    sh -c 'echo $$ > "$0"; exec pnpm "$@"' "$pidfile" "$@" || status=$?
in_container 'rm -f "$1"'
exit "$status"
