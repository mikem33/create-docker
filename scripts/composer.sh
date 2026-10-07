#!/usr/bin/env bash
#
# composer — run Composer inside the current project's container, as if it were local.
#
# Finds the enclosing generated project by walking up from the working
# directory, picks the container that actually holds the PHP runtime (the
# "php" service on the nginx variant, "web" on the Apache one), and mirrors
# your location: run it from src/wp-content/themes/foo and Composer starts in
# /var/www/html/wp-content/themes/foo, so it finds that directory's composer.json.
#
# Symlink it onto your PATH as "composer":
#   ln -s ~/Dev/create-docker/scripts/composer.sh ~/.local/bin/composer

set -euo pipefail

RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; RESET=$'\033[0m'
die() { echo "${RED}✗${RESET} $*" >&2; exit 1; }

# ─── Locate the project ──────────────────────────────────────────────────────
# Walk up from $PWD until a docker-compose.yml turns up.

root="$PWD"
while [[ "$root" != "/" && ! -f "$root/docker-compose.yml" ]]; do
    root="$(dirname "$root")"
done
[[ -f "$root/docker-compose.yml" ]] \
    || die "Not inside a Docker project (no docker-compose.yml in $PWD or any parent)."

# ─── Pick the container running PHP ──────────────────────────────────────────
# Ask Compose rather than guessing "<dirname>-web": the container_name is fixed
# at creation time, so a renamed project directory would break name guessing.
# "php" first — on the nginx variant "web" is nginx:alpine and has no PHP.

container=""
for svc in php web; do
    cid="$(docker compose --project-directory "$root" ps -q "$svc" 2>/dev/null | head -1)" || true
    if [[ -n "$cid" ]]; then container="$cid"; break; fi
done

if [[ -z "$container" ]]; then
    die "No running container for this project. Start it first: start-docker $(basename "$root")"
fi

docker exec "$container" test -x /usr/bin/composer 2>/dev/null \
    || die "Composer is not installed in this project's container — was $(basename "$root") created with Composer?"

# ─── Mirror the working directory ────────────────────────────────────────────
# Host <root>/src is mounted at /var/www/html, so a path below src/ maps across
# one-to-one. Anywhere else in the project falls back to the web root.

workdir="/var/www/html"
src="$root/src"
if [[ "$PWD" == "$src"/* ]]; then
    workdir="/var/www/html/${PWD#"$src"/}"
elif [[ "$PWD" != "$src" && "$PWD" != "$root" ]]; then
    # somewhere like nginx/ — the mapping does not reach here, so say so once
    echo "${YELLOW}!${RESET} $PWD is outside src/; running from the web root instead." >&2
fi

# ─── Hand over to Composer ───────────────────────────────────────────────────
# -i keeps stdin open so piped input works; -t only when stdout is a terminal,
# so Composer keeps its colours and prompts interactively but piping into
# grep or jq stays clean.

exec_flags=(-i)
[[ -t 1 ]] && exec_flags+=(-t)

exec docker exec "${exec_flags[@]}" -w "$workdir" "$container" composer "$@"
