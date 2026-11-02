#!/usr/bin/env bash
# Installs create-docker's commands for this user: links each script in scripts/ into
# ~/.local/bin under its command name, so a `git pull` here updates them.
#   ./install.sh --dry   -> what it would do
#   ./install.sh         -> does it
# Safe to run again: links already in place are left alone ("ok"), missing ones are added.
# A different file or link already at a command's name (e.g. your own wp) is never touched;
# it is reported, and that one command is skipped.
set -euo pipefail
cd "$(dirname "$0")"
REPO="$(pwd)"
BIN="$HOME/.local/bin"

DRY=0; [ "${1:-}" = "--dry" ] && DRY=1
run() { echo "+ $*"; [ $DRY -eq 1 ] || "$@"; }

# command name -> script; wp, composer and pnpm only act inside a create-docker project
COMMANDS=(
  create-docker:create-docker.sh
  delete-docker:delete-docker.sh
  start-docker:start-docker.sh
  stop-docker:stop-docker.sh
  wp:wp.sh
  composer:composer.sh
  pnpm:pnpm.sh
)

[ -d "$BIN" ] || run mkdir -p "$BIN"

skipped=0; linked=0
for entry in "${COMMANDS[@]}"; do
  name="${entry%%:*}"; src="$REPO/scripts/${entry#*:}"; dst="$BIN/$name"
  [ -x "$src" ] || run chmod +x "$src"
  if [ -L "$dst" ] && [ "$(readlink -f "$dst")" = "$(readlink -f "$src")" ]; then
    echo "  ok        ~/.local/bin/$name"; continue
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    echo "  skipped   ~/.local/bin/$name: something else is already there ($(readlink -f "$dst" 2>/dev/null || echo "$dst"))" >&2
    skipped=1; continue
  fi
  run ln -s "$src" "$dst"; linked=1
done

# ~/.local/bin must be on PATH, and ahead of the host's pnpm for the pnpm wrapper to be used
case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "  warning   ~/.local/bin is not on your PATH; add it in your shell config" >&2 ;;
esac
if [ $DRY -eq 0 ] && [ -L "$BIN/pnpm" ] && [ "$(command -v pnpm)" != "$BIN/pnpm" ]; then
  echo "  warning   'pnpm' resolves to $(command -v pnpm); put ~/.local/bin ahead of it on PATH" >&2
fi

[ $skipped -eq 0 ] || echo "  Some commands were skipped; remove what is there and run again to link them." >&2

# Shells remember where they last found a command, so one that already ran pnpm keeps
# using the host's /usr/bin/pnpm and never sees the new link.
if [ $linked -eq 1 ] && [ $DRY -eq 0 ]; then
  echo "  New commands linked: open a new terminal (or run 'rehash' in zsh, 'hash -r' in bash) before using them."
fi
