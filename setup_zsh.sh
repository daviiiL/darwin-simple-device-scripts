#!/usr/bin/env bash
# setup_zsh.sh — bootstrap the canonical zsh + starship environment.
#
# Idempotent: re-running skips files / clones / installs that already exist.
# Companion to populate.sh + organize.sh in this directory.
#
# Steps:
#   1. Ensure starship + eza are installed
#        macOS  → brew install (auto)        — fail with hint if no Homebrew
#        Linux  → prompt the user to install — script exits, nothing else changes
#   2. Create ~/.config/zshconfig and ~/.config/zshplugins
#   3. Clone zsh-autosuggestions + zsh-syntax-highlighting into the plugins dir
#   4. Write the modular zsh config files
#   5. Write ~/.config/starship.toml (preserves existing if present)
#   6. Patch ~/.zshrc to source the new zshconfig dir (in place if old line exists)
#   7. Rename ~/Documents/FILE_STRUCTURE.md → DOCUMENTS_STRUCTURE.md and
#      update organize.sh's skip-list to match
#   8. Optionally run organize.sh --apply (pass --organize to opt in)
#
# Usage:
#   ./setup_zsh.sh              # bootstrap only; organize.sh untouched
#   ./setup_zsh.sh --organize   # also run organize.sh --apply at the end
#   ./setup_zsh.sh --force      # overwrite existing zshconfig files
#
# Existing config files are NOT overwritten by default — delete them or pass
# --force to refresh.

set -euo pipefail

# ---------- args ----------
RUN_ORGANIZE=0
FORCE=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --organize) RUN_ORGANIZE=1; shift ;;
        --force)    FORCE=1; shift ;;
        -h|--help)  sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown flag: $1" >&2; exit 1 ;;
    esac
done

# ---------- styling ----------
C_OK=$'\033[1;32m'; C_WARN=$'\033[1;33m'; C_ERR=$'\033[1;31m'
C_DIM=$'\033[2m';   C_HDR=$'\033[1;36m'; C_RST=$'\033[0m'

step()  { printf '\n%s▸ %s%s\n' "$C_HDR" "$1" "$C_RST"; }
note()  { printf '  %s%s%s\n' "$C_DIM" "$1" "$C_RST"; }
ok()    { printf '  %s✓%s %s\n' "$C_OK" "$C_RST" "$1"; }
warn()  { printf '  %s!%s %s\n' "$C_WARN" "$C_RST" "$1"; }
fail()  { printf '  %s✗%s %s\n' "$C_ERR" "$C_RST" "$1" >&2; exit 1; }

# ---------- paths ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSH_CONFIG_DIR="$HOME/.config/zshconfig"
ZSH_PLUGINS_DIR="$HOME/.config/zshplugins"
STARSHIP_TOML="$HOME/.config/starship.toml"
ZSHRC="$HOME/.zshrc"
DOCS_ROOT="$HOME/Documents"
OLD_STRUCT="$DOCS_ROOT/FILE_STRUCTURE.md"
NEW_STRUCT="$DOCS_ROOT/DOCUMENTS_STRUCTURE.md"
ORGANIZE_SH="$SCRIPT_DIR/organize.sh"

# ---------- 1. tool check / install ----------
step "Checking required tools (starship, eza)"

OS="$(uname -s)"
have() { command -v "$1" >/dev/null 2>&1; }

ensure_macos_tool() {
    local tool="$1"
    if have "$tool"; then ok "$tool already installed"; return; fi
    if ! have brew; then
        fail "$tool is missing and Homebrew not found.
   Install Homebrew first: https://brew.sh
   Then re-run this script."
    fi
    note "installing $tool via Homebrew..."
    brew install "$tool"
    ok "$tool installed"
}

ensure_linux_tool() {
    local tool="$1"
    if have "$tool"; then ok "$tool already installed"; return; fi
    fail "$tool is missing.
   Install it through your package manager (apt/dnf/pacman/etc.) and re-run.
   Examples:
     apt:    sudo apt install $tool
     dnf:    sudo dnf install $tool
     pacman: sudo pacman -S $tool
     cargo:  cargo install $tool"
}

case "$OS" in
    Darwin) ensure_macos_tool starship; ensure_macos_tool eza ;;
    Linux)  ensure_linux_tool  starship; ensure_linux_tool  eza ;;
    *)      fail "unsupported OS: $OS" ;;
esac

# ---------- 2. config dirs ----------
step "Creating ~/.config/zshconfig and ~/.config/zshplugins"
mkdir -p "$ZSH_CONFIG_DIR" "$ZSH_PLUGINS_DIR"
ok "$ZSH_CONFIG_DIR"
ok "$ZSH_PLUGINS_DIR"

# ---------- 3. clone plugins ----------
step "Cloning zsh plugins"

clone_if_missing() {
    local repo="$1" dest="$2" name; name="$(basename "$dest")"
    if [[ -d "$dest/.git" ]]; then
        ok "$name already cloned"
    else
        note "cloning $name..."
        git clone --depth 1 "$repo" "$dest" >/dev/null 2>&1
        ok "$name"
    fi
}

clone_if_missing https://github.com/zsh-users/zsh-autosuggestions.git \
    "$ZSH_PLUGINS_DIR/zsh-autosuggestions"
clone_if_missing https://github.com/zsh-users/zsh-syntax-highlighting.git \
    "$ZSH_PLUGINS_DIR/zsh-syntax-highlighting"

# ---------- 4. write zsh config files ----------
step "Writing zshconfig modules"

write_file() {
    local path="$1" content="$2" name; name="$(basename "$path")"
    if [[ -f "$path" && "$FORCE" -ne 1 ]]; then
        ok "$name (exists, kept)"
        return
    fi
    printf '%s' "$content" > "$path"
    ok "$name"
}

write_file "$ZSH_CONFIG_DIR/env.zsh" 'export PATH="$HOME/.local/bin:$PATH"
'

write_file "$ZSH_CONFIG_DIR/aliases.zsh" 'alias ls="eza --icons --group-directories-first"
alias la="eza --icons --group-directories-first -a"
alias ll="eza --icons --group-directories-first -l"
alias tree="eza --icons --group-directories-first --tree"
'

write_file "$ZSH_CONFIG_DIR/options.zsh" '
setopt AUTO_CD
setopt INTERACTIVE_COMMENTS
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE
'

write_file "$ZSH_CONFIG_DIR/history.zsh" 'HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000

setopt SHARE_HISTORY
setopt APPEND_HISTORY
setopt INC_APPEND_HISTORY
setopt HIST_REDUCE_BLANKS
'

write_file "$ZSH_CONFIG_DIR/completion.zsh" '
autoload -Uz compinit && compinit

zstyle '"'"':completion:*'"'"' menu select
zstyle '"'"':completion:*'"'"' matcher-list '"'"'m:{a-z}={A-Z}'"'"'
'

write_file "$ZSH_CONFIG_DIR/direnv.zsh" 'command -v direnv >/dev/null 2>&1 && eval "$(direnv hook zsh)"
'

write_file "$ZSH_CONFIG_DIR/dirhash.zsh" '# Named directory expansions: type ~docs to mean ~/Documents, etc.
hash -d docs=~/Documents
hash -d proj=~/Documents/Projects
hash -d cur=~/Documents/Projects/active
hash -d notes=~/Documents/Notes
hash -d scripts=~/Documents/Scripts
hash -d dl=~/Downloads
hash -d conf=~/.config
'

write_file "$ZSH_CONFIG_DIR/nvm.zsh" 'export NVM_DIR="$HOME/.nvm"
# Homebrew (macOS) install path
[ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && \. "/opt/homebrew/opt/nvm/nvm.sh"
[ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && \. "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
# Linux / manual install path
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
'

write_file "$ZSH_CONFIG_DIR/starship.zsh" 'eval "$(starship init zsh)"
'

write_file "$ZSH_CONFIG_DIR/plugins.zsh" 'ZSH_PLUGINS_DIR="$HOME/.config/zshplugins"

[ -f "$ZSH_PLUGINS_DIR/zsh-autosuggestions/zsh-autosuggestions.zsh" ] && \
    source "$ZSH_PLUGINS_DIR/zsh-autosuggestions/zsh-autosuggestions.zsh"
[ -f "$ZSH_PLUGINS_DIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ] && \
    source "$ZSH_PLUGINS_DIR/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
'

# ---------- 5. starship.toml ----------
step "Writing ~/.config/starship.toml"
if [[ -f "$STARSHIP_TOML" && "$FORCE" -ne 1 ]]; then
    ok "starship.toml (exists, kept)"
else
    cat > "$STARSHIP_TOML" <<'STARSHIP_EOF'
format = """
$username\
$hostname\
$directory \
$git_branch\
$git_status\
$nodejs\
$python\
$rust\
$golang\
$java\
$docker_context\
$package\
$character"""

add_newline = false

[username]
show_always = true
format = "[$user]($style)"
style_user = "magenta"
style_root = "red bold"

[hostname]
ssh_only = false
format = "[@$hostname]($style)[/](white)"
style = "white dimmed"

[directory]
format = "[$path]($style)"
style = "white"
truncation_length = 3
truncation_symbol = "./"

[character]
success_symbol = "[>](green)"
error_symbol = "[>](red)"

[git_branch]
format = "[$branch]($style) "
style = "yellow bold"

[git_status]
format = "[$all_status$ahead_behind]($style) "
style = "red"

[nodejs]
format = "[node $version]($style) "
symbol = ""
style = "green bold"

[python]
format = "[py $version]($style) "
symbol = ""
style = "yellow"

[rust]
format = "[rs $version]($style) "
symbol = ""
style = "208 bold"

[golang]
format = "[go $version]($style) "
symbol = ""
style = "cyan bold"

[java]
format = "[java $version]($style) "
symbol = ""
style = "red"

[docker_context]
format = "[docker $context]($style) "
symbol = ""
style = "39"

[package]
format = "[pkg $version]($style) "
symbol = ""
style = "208"
STARSHIP_EOF
    ok "starship.toml"
fi

# ---------- 6. patch ~/.zshrc ----------
step "Wiring ~/.zshrc to source $ZSH_CONFIG_DIR"

ZSHRC_NEW_BLOCK='for conf in "$HOME/.config/zshconfig/"*.zsh; do
  source "$conf"
done'

if [[ ! -f "$ZSHRC" ]]; then
    note "no ~/.zshrc — creating one"
    printf '%s\n' "$ZSHRC_NEW_BLOCK" > "$ZSHRC"
    ok "~/.zshrc created"
elif grep -q '\.config/zshconfig/' "$ZSHRC"; then
    ok "~/.zshrc already sources zshconfig"
elif grep -q '\.config/\.zshconfig/' "$ZSHRC"; then
    # Replace old dot-prefixed path with new one in place.
    sed -i.bak 's|\.config/\.zshconfig/|.config/zshconfig/|g' "$ZSHRC"
    ok "~/.zshrc patched (old .zshconfig path → zshconfig); backup at ~/.zshrc.bak"
else
    printf '\n# zshconfig modular loader\n%s\n' "$ZSHRC_NEW_BLOCK" >> "$ZSHRC"
    ok "~/.zshrc appended source loop"
fi

# ---------- 7a. ensure ~/Documents canonical structure ----------
step "Ensuring ~/Documents structure"

POPULATE_SH="$SCRIPT_DIR/populate.sh"
if [[ -x "$POPULATE_SH" ]]; then
    # populate.sh creates any missing canonical dirs and is idempotent.
    "$POPULATE_SH" "$DOCS_ROOT"
else
    warn "populate.sh not found at $POPULATE_SH — skipping structure bootstrap"
fi

# ---------- 7b. rename FILE_STRUCTURE.md ----------
step "Renaming FILE_STRUCTURE.md → DOCUMENTS_STRUCTURE.md"

if [[ -f "$NEW_STRUCT" ]]; then
    ok "$(basename "$NEW_STRUCT") already in place"
elif [[ -f "$OLD_STRUCT" ]]; then
    mv "$OLD_STRUCT" "$NEW_STRUCT"
    ok "renamed → $(basename "$NEW_STRUCT")"
else
    warn "neither file found at $DOCS_ROOT (skipping)"
fi

# Update organize.sh skip-list reference if present and still pointing at old name.
if [[ -f "$ORGANIZE_SH" ]] && grep -q 'FILE_STRUCTURE\.md' "$ORGANIZE_SH"; then
    sed -i.bak 's|FILE_STRUCTURE\.md|DOCUMENTS_STRUCTURE.md|g' "$ORGANIZE_SH"
    ok "organize.sh updated (backup at organize.sh.bak)"
fi

# ---------- 8. organize ----------
if (( RUN_ORGANIZE )); then
    step "Running organize.sh --apply"
    if [[ ! -x "$ORGANIZE_SH" ]]; then
        warn "organize.sh not executable at $ORGANIZE_SH (skipping)"
    else
        "$ORGANIZE_SH" --apply
    fi
else
    step "Skipping organize.sh"
    note "pass --organize to also run: $ORGANIZE_SH --apply"
fi

# ---------- done ----------
printf '\n%s✓ setup complete.%s Open a new shell or: %ssource ~/.zshrc%s\n' \
    "$C_OK" "$C_RST" "$C_DIM" "$C_RST"
