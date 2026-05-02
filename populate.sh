#!/usr/bin/env bash
# populate.sh — bootstrap the canonical ~/Documents/ structure on a new system.
#
# Run this once on a fresh machine. It will:
#   1. Create the directory tree described in FILE_STRUCTURE.md
#   2. Deploy organize.sh, find-duplicates.sh, and populate.sh into
#      $ROOT/Scripts/ via deploy_file() (default $ROOT is ~/Documents;
#      the canonical repo home is ~/Scripts — see setup.sh)
#   3. Ensure ${XDG_CACHE_HOME:-~/.cache} exists so organize.sh can write its log
#
# Usage:
#   ./populate.sh                  # bootstrap into ~/Documents
#   ./populate.sh /custom/root     # bootstrap into a different root
#
# Source layout: this script expects to live in the same directory as the
# scripts it deploys (e.g. a cloned dotfiles repo or a thumb drive).

set -euo pipefail

ROOT="${1:-$HOME/Documents}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- canonical directory tree (mirrors FILE_STRUCTURE.md) ----------
DIRS=(
  Inbox
  Notes Notes/Work Notes/Study Notes/Ideas
  Docs Docs/Legal Docs/Compliance Docs/Finance Docs/Reports
  Docs/Presentations Docs/Designs Docs/References Docs/Personal
  Media Media/Screenshots Media/Photos Media/Logos
  Projects Projects/active Projects/client Projects/personal Projects/archive
  Resources Resources/Fonts Resources/Licenses Resources/Keys Resources/ApiCollections
  Logs
  Archive
  Trash
  Scripts
)

# Files this script will deploy into ROOT/Scripts/.
SCRIPTS_TO_DEPLOY=(
  organize.sh
  find-duplicates.sh
  populate.sh
)

# ---------- deploy_file ------------------------------------------------------
# Copy/install a single source file to its destination.
#
# Args: $1 = absolute source path, $2 = absolute destination path
# Behavior decisions are YOURS — see the design notes below.
#
# Design choices to make:
#   1. Conflict policy when $2 already exists:
#        a) skip      — leave existing file alone (safe re-run, preserves local edits)
#        b) overwrite — always replace (always-in-sync, risks blowing away edits)
#        c) prompt    — ask the user per file (slow but safe)
#        d) backup    — rename existing to "$2.bak.<timestamp>" then copy
#   2. Copy vs symlink:
#        - cp creates a frozen snapshot; later edits to source don't propagate
#        - ln -s makes the deployed file always reflect the source repo
#   3. Should this function chmod +x for *.sh files, or trust source perms?
#
# Echo a one-line summary to stdout (the caller relies on it for logging).
# Return non-zero on hard failure; "skipped" is success.
deploy_file() {
  local src="$1" dst="$2"
  if [[ -e "$dst" ]]; then
    echo "  = ${dst#$ROOT/}  (exists, skipped)"
    return 0
  fi
  cp "$src" "$dst"
  [[ "$dst" == *.sh ]] && chmod +x "$dst"
  echo "  + ${dst#$ROOT/}"
}

# ---------- bootstrap --------------------------------------------------------
echo "→ ROOT: $ROOT"
echo "→ SRC:  $SRC"
echo

echo "creating directory tree…"
for d in "${DIRS[@]}"; do
  if [[ ! -d "$ROOT/$d" ]]; then
    mkdir -p "$ROOT/$d"
    echo "  + $d/"
  fi
done

echo
echo "ensuring cache dir for organize.log…"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
mkdir -p "$CACHE_DIR"
echo "  ok: $CACHE_DIR"

echo
echo "deploying scripts…"
for f in "${SCRIPTS_TO_DEPLOY[@]}"; do
  src="$SRC/$f"
  dst="$ROOT/Scripts/$f"
  if [[ ! -f "$src" ]]; then
    echo "  ! source missing, skipping: $src"
    continue
  fi
  deploy_file "$src" "$dst"
done

echo
echo "done. inspect $ROOT/Scripts/ and run ./organize.sh --help to verify."
