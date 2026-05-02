#!/usr/bin/env bash
# setup.sh — main entry point for initial machine setup.
#
# Clone this repo to ~/Scripts (the canonical home — dirhash.zsh expands
# ~scripts to it) and run ./setup.sh. Idempotent — safe to re-run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

C_HDR=$'\033[1;36m'; C_ERR=$'\033[1;31m'; C_RST=$'\033[0m'
step() { printf '\n%s▸ %s%s\n' "$C_HDR" "$1" "$C_RST"; }

step "Running setup_zsh.sh --organize"
"$SCRIPT_DIR/setup_zsh.sh" --organize

print_zsh_warning() {
    printf '\n%s╔══════════════════════════════════════════════════════╗%s\n' "$C_ERR" "$C_RST"
    printf '%s║  ACTION REQUIRED — set zsh as your login shell:      ║%s\n' "$C_ERR" "$C_RST"
    printf '%s║                                                      ║%s\n' "$C_ERR" "$C_RST"
    printf '%s║      chsh -s /bin/zsh                                ║%s\n' "$C_ERR" "$C_RST"
    printf '%s╚══════════════════════════════════════════════════════╝%s\n\n' "$C_ERR" "$C_RST"
}

print_zsh_warning
