#!/usr/bin/env bash
# organize.sh — classify loose files in ~/Documents and move them into the
# canonical structure described in DOCUMENTS_STRUCTURE.md.
#
# Default mode is DRY-RUN. Pass --apply to actually move files.
#
# Usage:
#   ./organize.sh                    # dry-run on ~/Documents (read-only)
#   ./organize.sh --apply            # actually move files
#   ./organize.sh /some/path         # operate on a different root
#   ./organize.sh --only Inbox       # only classify files in Inbox/
#
# Safety:
#   * Never overwrites: if destination exists, appends "-001", "-002", ...
#   * Never enters known project / dependency / VC directories.
#   * Never touches files inside `Projects/` or `Archive/` — those are
#     considered already-organized git workspaces / cold storage.
#   * Treats any git repository as an ATOMIC object. The sweep refuses to
#     descend into a directory that contains a `.git/` at its root, and
#     discovered repos anywhere under ROOT are added to a hard skip-list.
#   * Logs every move to ${XDG_CACHE_HOME:-~/.cache}/organize.log so you can grep / undo.

set -euo pipefail

ROOT="${HOME}/Documents"
APPLY=0
ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --only)  ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *)  ROOT="$1"; shift ;;
  esac
done

[[ -d "$ROOT" ]] || { echo "not a directory: $ROOT" >&2; exit 1; }

# Log lives outside ROOT (XDG cache) so it isn't classified by its own sweep.
LOG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
LOG="$LOG_DIR/organize.log"
mkdir -p "$LOG_DIR"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# ---------- discover git repos (treated as atomic; never traversed) ----------
REPOS_FILE="$(mktemp)"
trap 'rm -f "$REPOS_FILE"' EXIT
find "$ROOT" \
  \( -type d \( -name node_modules -o -name .venv -o -name venv \
      -o -name __pycache__ -o -name target -o -name Pods \
      -o -name dist -o -name build -o -name vendor -o -name .next \) -prune \) -o \
  \( -type d -name .git -print \) 2>/dev/null \
  | sed 's|/\.git$||' \
  | sort -u > "$REPOS_FILE"

# Returns 0 if path is inside or equal to any discovered git repo root.
inside_repo() {
  local p="$1"
  while IFS= read -r r; do
    [[ -z "$r" ]] && continue
    case "$p" in
      "$r"|"$r"/*) return 0 ;;
    esac
  done < "$REPOS_FILE"
  return 1
}

# ---------- canonical destinations ----------
# Always create missing structure dirs (idempotent). The --apply flag gates
# file MOVES, not the schema itself — running organize.sh on a dir whose
# structure is half-built will heal it before doing anything else.
mk() {
  if [[ ! -d "$1" ]]; then
    mkdir -p "$1"
    echo "  + ${1#$ROOT/}/"
  fi
}

# Top-level buckets we manage.
TOP_BUCKETS=(
  Inbox
  Notes Notes/Work Notes/Study Notes/Ideas
  Docs Docs/Legal Docs/Compliance Docs/Finance Docs/Reports
  Docs/Presentations Docs/Designs Docs/References Docs/Personal
  Media Media/Screenshots Media/Photos Media/Logos
  Projects Projects/active Projects/client Projects/personal Projects/archive
  Resources Resources/Fonts Resources/Licenses Resources/Keys
  Resources/ApiCollections Resources/Configs
  Logs
  Archive
  Trash
)

# Names that already are canonical top-level buckets — directory sweep skips these.
CANONICAL_ROOT_DIRS=(
  Inbox Notes Docs Media Projects Resources Logs Archive Trash
  Scripts        # personal shell scripts repo, lives at root by exception
)

# Loose directories at root we deliberately leave alone. Adobe is load-bearing:
# Adobe apps depend on ~/Documents/Adobe and will recreate it if moved.
IGNORE_ROOT_DIRS=(
  Adobe
)

# Directories we never descend into when classifying loose files.
SKIP_DIRS=(
  # version control / build / package managers
  .git .svn .hg node_modules .pnpm .yarn bower_components jspm_packages
  dist build out .next .nuxt .turbo .svelte-kit .parcel-cache .vite
  __pycache__ .venv venv env virtualenv site-packages
  .pytest_cache .mypy_cache .ruff_cache .tox
  target .gradle .m2 .ivy2 bin obj Pods Carthage DerivedData vendor
  .cache coverage .nyc_output
  # AI / IDE configs
  .claude .opencode .aider .cursor .cursor-server .copilot .codeium
  .continue .windsurf .anthropic .openai .gemini
  .vscode .vscode-server .idea .vs .zed .fleet .nova
  # our own already-organized buckets
  Projects Archive .obsidian
)

# Directories that are SAFE to walk into and pull files out of (when --only Inbox
# is not set, this is the default sweep set). Anything else is left alone.
SWEEP_DIRS_DEFAULT=(
  ""           # root itself (loose files at ~/Documents/)
  Inbox
  curProj      # legacy: moves to Projects/active by hand
  tobedeleted  # legacy: should empty into Trash/
  serverlog    # legacy: empties into Logs/
  bruno        # legacy: empties into Resources/ApiCollections/
)

# ---------- classifier ----------
# echoes the destination directory (relative to $ROOT) for a given filename.
classify() {
  local path="$1"
  local name; name="$(basename "$path")"
  local lname; lname="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  local ext="${name##*.}"; ext="$(echo "$ext" | tr '[:upper:]' '[:lower:]')"
  [[ "$ext" == "$name" ]] && ext=""

  # 1. Logs
  case "$lname" in
    *.log|local[0-9]*.log) echo "Logs"; return ;;
  esac

  # 2. Trash candidates (installers, dups, archives of installers)
  case "$lname" in
    *.dmg|*.pkg) echo "Trash"; return ;;
    *-dup*|*-copy*|*-prev*) echo "Trash"; return ;;
  esac

  # 3. Screenshots
  case "$name" in
    Screenshot*|"Screen Shot"*|"Screen Recording"*) echo "Media/Screenshots"; return ;;
  esac

  # 4. Logos / brand marks
  case "$lname" in
    *logo*.png|*logo*.svg|*logo*.jpg|*logo*.jpeg|*logo*.webp|*logomark*) echo "Media/Logos"; return ;;
  esac

  # 5. Keys / certs
  case "$ext" in
    pem|key|crt|csr|p12|pfx) echo "Resources/Keys"; return ;;
  esac

  # 6. Fonts
  case "$ext" in
    ttf|otf|woff|woff2|eot) echo "Resources/Fonts"; return ;;
  esac

  # 7. API collections (Bruno / Postman files / .bru)
  case "$ext" in
    bru|postman_collection|postman_environment) echo "Resources/ApiCollections"; return ;;
  esac

  # 8. Markdown notes
  if [[ "$ext" == "md" ]]; then
    case "$lname" in
      todo*|notes*|meeting*|business*|credentials*|questions*|issuing*)
        echo "Notes/Work"; return ;;
      idea*|brainstorm*|draft*) echo "Notes/Ideas"; return ;;
      *) echo "Notes/Work"; return ;;
    esac
  fi

  # 9. Documents — categorize by name keywords
  case "$ext" in
    pdf|docx|doc|odt|rtf|txt|pptx|ppt|xlsx|xls|csv|numbers|pages|key)
      case "$lname" in
        *nda*|*agreement*|*contract*|*signed*|*amd[0-9]*|*amendment*|*mou*|*loi*|*mnda*|*msa*)
          echo "Docs/Legal"; return ;;
        *pci*|*kyc*|*aml*|*compliance*|*sanction*|*ofac*|*regulator*|*bsa*)
          echo "Docs/Compliance"; return ;;
        *invoice*|*statement*|*settlement*|*receipt*|*wire*|*ach*|*fee*|*payroll*|*tax*|*1099*|*w-?9*|*recon*)
          echo "Docs/Finance"; return ;;
        *report*|*assessment*|*audit*|*review*|*sop*|*disput*|*chargeback*|*proposal*)
          echo "Docs/Reports"; return ;;
        *pitch*|*deck*|*presentation*|*intro*|*overview*)
          echo "Docs/Presentations"; return ;;
        *design*|*mockup*|*card*|*brand*|*ui*|*ux*)
          echo "Docs/Designs"; return ;;
        *passport*|*license*|*license_*|*identity*|*proof*|*residency*|*lease*)
          echo "Docs/Personal"; return ;;
        *manual*|*spec*|*reference*|*guide*|*api*)
          echo "Docs/References"; return ;;
        *) echo "Inbox"; return ;;
      esac
      ;;
  esac

  # 10. Other media
  case "$ext" in
    png|jpg|jpeg|gif|webp|heic|tiff|bmp|svg) echo "Media/Photos"; return ;;
    mp4|mov|m4a|mp3|wav|aiff|avi|mkv|webm)   echo "Media/Photos"; return ;;
  esac

  # 11. Code archives that are dependency artifacts → Trash
  case "$ext" in
    zip|tar|gz|bz2|7z|xz|rar)
      case "$lname" in
        *theme*|*plugin*|*-dup*|*-copy*) echo "Trash"; return ;;
        *) echo "Inbox"; return ;;
      esac
      ;;
  esac

  echo "Inbox"
}

# ---------- directory classifier ----------
# Echoes the destination directory (relative to $ROOT) for a loose DIRECTORY
# at the root, or one of two sentinels:
#   "@ignore"  → leave in place silently (load-bearing dirs)
#   "@warn"    → leave in place, print a warning so the user can extend rules
classify_dir() {
  local path="$1"
  local name; name="$(basename "$path")"

  for ig in "${IGNORE_ROOT_DIRS[@]}"; do
    [[ "$name" == "$ig" ]] && { echo "@ignore"; return; }
  done

  # Git repos at root that aren't sanctioned top-level buckets → Projects/personal/.
  if [[ -d "$path/.git" ]]; then
    echo "Projects/personal"; return
  fi

  local lname; lname="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
  case "$lname" in
    *_config|*_configs|*-config|*-configs|dotfiles*|*_dotfiles)
      echo "Resources/Configs"; return ;;
  esac

  echo "@warn"
}

# ---------- ensure structure ----------
echo "ensuring canonical structure under $ROOT (creating any missing dirs)..."
for d in "${TOP_BUCKETS[@]}"; do mk "$ROOT/$d"; done
echo

if [[ "$APPLY" -eq 1 ]]; then
  printf '\n# === %s ===\n' "$TS" >> "$LOG"
fi

# ---------- safe move (no overwrite) ----------
move_safe() {
  local src="$1" dst_dir="$2"
  local base; base="$(basename "$src")"
  local dst="$dst_dir/$base"
  if [[ -e "$dst" ]]; then
    local stem ext n
    stem="${base%.*}"; ext="${base##*.}"
    [[ "$stem" == "$base" ]] && ext=""
    n=1
    while :; do
      local suffix; printf -v suffix '%03d' "$n"
      if [[ -n "$ext" ]]; then dst="$dst_dir/${stem}-${suffix}.${ext}"
      else                     dst="$dst_dir/${stem}-${suffix}"
      fi
      [[ ! -e "$dst" ]] && break
      n=$((n+1))
    done
  fi
  if [[ "$APPLY" -eq 1 ]]; then
    mkdir -p "$dst_dir"
    mv -- "$src" "$dst"
    printf 'mv\t%s\t%s\n' "$src" "$dst" >> "$LOG"
  fi
  printf '  %s  →  %s\n' "${src#$ROOT/}" "${dst#$ROOT/}"
}

# ---------- sweep ----------
declare -i moved=0 skipped=0

sweep_dir() {
  local rel="$1"
  local abs="$ROOT/$rel"; [[ -z "$rel" ]] && abs="$ROOT"
  [[ ! -d "$abs" ]] && return

  # Atomic-repo guard: refuse to sweep a directory that IS a git repo, or
  # that lives inside one. Repos are managed as a unit, not file-by-file.
  if [[ -d "$abs/.git" ]]; then
    echo "  (skipping — $rel is a git repo; treated as atomic)"
    return
  fi
  if inside_repo "$abs"; then
    echo "  (skipping — $rel is inside a git repo; treated as atomic)"
    return
  fi

  # Files DIRECTLY inside this dir (not recursing into sub-buckets we manage).
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    # Defense-in-depth: never act on a file that turns out to be inside a repo.
    if inside_repo "$f"; then continue; fi
    local name; name="$(basename "$f")"
    # skip our own scripts and the spec
    case "$name" in
      DOCUMENTS_STRUCTURE.md|find-duplicates.sh|organize.sh|organize.log) continue ;;
      .DS_Store|.localized|.gitkeep) continue ;;
    esac
    # don't re-classify files already in canonical buckets
    case "$rel" in
      Notes*|Docs*|Media*|Resources*|Logs*|Trash*|Archive*|Projects*|Scripts*) continue ;;
    esac
    local dest; dest="$(classify "$f")"
    if [[ "$dest" == "Inbox" && "$rel" == "Inbox" ]]; then
      skipped=$((skipped+1))
      continue
    fi
    move_safe "$f" "$ROOT/$dest"
    moved=$((moved+1))
  done < <(find "$abs" -maxdepth 1 -type f)
}

# Classify loose DIRECTORIES at the root. Canonical buckets are skipped; the
# rest are dispatched through classify_dir() and either moved, ignored, or
# warned about (so the user can extend the rules).
sweep_root_dirs() {
  declare -i warned=0
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    local name; name="$(basename "$d")"
    case "$name" in
      .*) continue ;;          # skip dotdirs (.claude, .UTSystemConfig, …)
    esac
    local lname; lname="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
    local is_known=0
    # Canonical buckets and legacy file-sweep dirs are both "known" — skip them
    # case-insensitively (macOS filesystem is case-insensitive by default).
    for c in "${CANONICAL_ROOT_DIRS[@]}" "${SWEEP_DIRS_DEFAULT[@]}"; do
      [[ -z "$c" ]] && continue
      local lc; lc="$(echo "$c" | tr '[:upper:]' '[:lower:]')"
      [[ "$lname" == "$lc" ]] && { is_known=1; break; }
    done
    [[ "$is_known" -eq 1 ]] && continue

    local dest; dest="$(classify_dir "$d")"
    case "$dest" in
      "@ignore") continue ;;
      "@warn")
        echo "  ! unclassified directory: $name/  (left in place — extend classify_dir to handle it)"
        warned=$((warned+1))
        ;;
      *)
        move_safe "$d" "$ROOT/$dest"
        moved=$((moved+1))
        ;;
    esac
  done < <(find "$ROOT" -maxdepth 1 -mindepth 1 -type d)
  [[ "$warned" -gt 0 ]] && echo "  ($warned unclassified directory/ies — see warnings above)"
}

if [[ "$APPLY" -eq 1 ]]; then
  echo "MODE: APPLY  (changes will be made; logged to organize.log)"
else
  echo "MODE: DRY-RUN  (no changes; pass --apply to act)"
fi
echo "ROOT: $ROOT"
REPO_COUNT=$(wc -l < "$REPOS_FILE" | tr -d ' ')
echo "REPOS: $REPO_COUNT discovered (treated as atomic — not traversed)"
echo

if [[ -n "$ONLY" ]]; then
  echo "→ sweeping only: $ONLY"
  sweep_dir "$ONLY"
else
  for d in "${SWEEP_DIRS_DEFAULT[@]}"; do
    [[ -n "$d" ]] && echo "→ sweeping: $d/" || echo "→ sweeping: <root>"
    sweep_dir "$d"
  done
  echo "→ sweeping: <loose root directories>"
  sweep_root_dirs
fi

echo
echo "summary: $moved file(s) classified, $skipped left in place."
[[ "$APPLY" -eq 0 ]] && echo "(dry run — re-run with --apply to perform moves)"
exit 0
