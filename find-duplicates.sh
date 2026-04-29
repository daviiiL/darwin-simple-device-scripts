#!/usr/bin/env bash
# find-duplicates.sh — find binary-identical duplicates under ~/Documents.
#
# Git repositories are treated as ATOMIC objects:
#   * Files inside a git repo are NOT individually compared.
#   * Whole repos are fingerprinted and compared against each other.
#     Duplicate repos can be deleted as a unit.
#
# Loose files (anything outside a repo and outside dependency / build / AI /
# IDE / OS-junk dirs) go through a per-file interactive dedup prompt.
#
# Usage:
#   ./find-duplicates.sh                  # interactive scan, ~/Documents
#   ./find-duplicates.sh /some/path
#   ./find-duplicates.sh --report-only    # print, no prompts
#   ./find-duplicates.sh --no-repo-dedup  # only loose-file dedup
#   ./find-duplicates.sh --repos-only     # only repo dedup
#   ./find-duplicates.sh -m 100k          # min file size for loose files
#
# Prompt keys (per file):    y=delete  N=keep  s=skip group  q/a=quit
# Prompt keys (whole group): G=keep [1], delete all others  N=fall through to
#                            per-file  s=skip  q=quit
# Refuses to delete the last remaining copy in any group.

set -euo pipefail

ROOT="${HOME}/Documents"
MIN_SIZE="1c"
REPORT_ONLY=0
DO_REPOS=1
DO_LOOSE=1
USE_COLOR=1
[[ -n "${NO_COLOR:-}" ]] && USE_COLOR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--min-size)   MIN_SIZE="$2"; shift 2 ;;
    --report-only)   REPORT_ONLY=1; shift ;;
    --no-repo-dedup) DO_REPOS=0; shift ;;
    --repos-only)    DO_LOOSE=0; shift ;;
    --no-color)      USE_COLOR=0; shift ;;
    -h|--help)       sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "unknown flag: $1" >&2; exit 1 ;;
    *)  ROOT="$1"; shift ;;
  esac
done

[[ -d "$ROOT" ]] || { echo "not a directory: $ROOT" >&2; exit 1; }

WORK="$(mktemp -d)"
# bar_finish already calls spin_stop and is a no-op when inactive.
trap 'bar_finish 2>/dev/null || true; rm -rf "$WORK"' EXIT

# ============================================================
# Excludes — never descend into these directory names anywhere.
# ============================================================
# Note: .git is intentionally NOT in EXCLUDE_DIRS — we use it to discover repos.

EXCLUDE_DIRS=(
  # version control (other than git)
  .svn .hg
  # JS / TS package managers + build outputs
  node_modules .pnpm .yarn bower_components jspm_packages
  dist build out .next .nuxt .turbo .svelte-kit .parcel-cache .vite
  # python
  __pycache__ .venv venv env virtualenv site-packages
  .pytest_cache .mypy_cache .ruff_cache .tox
  # rust / java / kotlin / scala
  target .gradle .m2 .ivy2
  # .NET
  bin obj
  # ios / macos
  Pods Carthage DerivedData
  # php / composer / generic
  vendor
  # caches / coverage
  .cache coverage .nyc_output
  # AI assistants / agents
  .claude .opencode .aider .aider.tags.cache .aider.chat.history
  .cursor .cursor-server .copilot .codeium .continue .windsurf
  .anthropic .openai .gemini
  # editors / IDEs
  .vscode .vscode-server .idea .vs .zed .fleet .nova .sublime-project
  # ad-hoc python virtualenvs
  nhp_env
  # specific app bundle
  Photoshop\ Cloud\ Associates
)

EXCLUDE_FILES=(
  .DS_Store Thumbs.db .localized desktop.ini
  '*.pyc' '*.pyo' '*.class' '*.o' '*.obj' '*.swp' '*.swo'
)

DIR_EXPR=()
for d in "${EXCLUDE_DIRS[@]}"; do DIR_EXPR+=( -name "$d" -o ); done
unset 'DIR_EXPR[${#DIR_EXPR[@]}-1]'

FILE_EXPR=()
for f in "${EXCLUDE_FILES[@]}"; do FILE_EXPR+=( ! -name "$f" ); done

# ============================================================
# Helpers
# ============================================================
# ---- color ----
# Honor NO_COLOR env, --no-color flag, and non-TTY stderr.
[[ -t 2 ]] || USE_COLOR=0
if (( USE_COLOR == 1 )); then
  C_RESET=$'\e[0m';  C_BOLD=$'\e[1m';  C_DIM=$'\e[2m'
  C_RED=$'\e[31m';   C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m';  C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'
  C_GREY=$'\e[90m'
else
  C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GREEN=; C_YELLOW=
  C_BLUE=; C_MAGENTA=; C_CYAN=; C_GREY=
fi

human_size() {
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB TB",u," ");
    i=1; while (b>=1024 && i<5) { b/=1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

md5_of() { openssl md5 "$1" 2>/dev/null | awk '{print $NF}'; }

# Portable file size in bytes (BSD stat fallback to GNU stat).
file_size() { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }

count_lines() { wc -l < "$1" | tr -d ' '; }

# canonical_rank PATH → small integer (lower = more canonical).
# Drives "G=keep [1]" so the canonical copy is the default keeper, and groups
# are listed canonical-first. Mirrors FILE_STRUCTURE.md's bucket priorities.
# Markers (-dup/-copy/-prev/-old, also _dup etc.) penalize *within* canonical
# buckets too, so a "-copy" subfolder under Docs/ ranks worse than its sibling.
canonical_rank() {
  local p="$1"
  local rel="${p#$ROOT/}"
  local lower; lower=$(printf '%s' "$rel" | tr '[:upper:]' '[:lower:]')
  case "$lower" in
    trash/*|tobedeleted*) echo 95; return ;;
  esac
  # Dup-marker as a path-component suffix: -dup, _copy, etc., before /, ., or EOS.
  if [[ "$lower" =~ [-_](dup|copy|prev|old)(/|\.|$) ]]; then
    echo 90; return
  fi
  case "$lower" in
    inbox/*)                      echo 70; return ;;
    archive/*|*/backup-archive/*) echo 60; return ;;
  esac
  case "$rel" in
    Docs/*|Notes/*|Media/*|Resources/*|Projects/*|Logs/*) echo 10; return ;;
  esac
  echo 50
}

# Color code for a path based on canonical_rank. Empty string when colors off.
path_color() {
  local r; r=$(canonical_rank "$1")
  if   (( r <= 10 )); then printf '%s' "$C_GREEN"
  elif (( r <= 50 )); then printf ''
  elif (( r <= 70 )); then printf '%s' "$C_YELLOW"
  else                     printf '%s' "$C_RED"
  fi
}

# ---- bottom-pinned bar / spinner ----
# bar_init reserves the last terminal row via the DECSTBM scroll region.
# Log lines printed afterward scroll above; the bottom row holds either:
#   - a static byte-based progress bar (bar_update PCT LABEL), or
#   - a Claude-Code-style pulsing-star spinner (spin_start MSG / spin_set MSG).
# Use spin_stop to silence the spinner before drawing a bar, and vice versa.
# bar_finish restores the scroll region.
# All functions no-op when stderr is not a TTY (CI / redirected output).

BAR_ACTIVE=0
BAR_ROW=0           # phase line: spinner / per-phase bar
TOTAL_BAR_ROW=0     # absolute bottom: total progress bar
BAR_COLS=0
TOTAL_PCT=0
SPIN_PID=""
SPIN_MSG_FILE=""

# Read the terminal size via TIOCGWINSZ (`stty size`). More reliable than
# `tput lines` (which can read a stale $LINES env var and report the current
# command block's size in some terminals).
# Sets QUERIED_ROWS / QUERIED_COLS on success.
QUERIED_ROWS=0
QUERIED_COLS=0
query_term_size() {
  [[ -t 2 ]] || return 1
  local size
  size=$(stty size </dev/tty 2>/dev/null) || return 1
  local rows="${size%% *}"
  local cols="${size##* }"
  [[ "$rows" =~ ^[0-9]+$ && "$cols" =~ ^[0-9]+$ ]] || return 1
  (( rows > 0 && cols > 0 )) || return 1
  QUERIED_ROWS=$rows
  QUERIED_COLS=$cols
}

bar_init() {
  (( BAR_ACTIVE == 1 )) && return 0
  [[ -t 2 ]] || return 0
  if query_term_size; then
    TOTAL_BAR_ROW=$QUERIED_ROWS
    BAR_COLS=$QUERIED_COLS
  else
    TOTAL_BAR_ROW=$(tput lines 2>/dev/null) || return 0
    BAR_COLS=$(tput cols 2>/dev/null) || return 0
  fi
  BAR_ROW=$(( TOTAL_BAR_ROW - 1 ))
  (( TOTAL_BAR_ROW >= 4 && BAR_COLS >= 20 )) || return 0
  # Clear the visible viewport so the script owns the full window, set the
  # scroll region to rows 1..(N-2), then home the cursor so log lines stack
  # from the top down. Bars live in rows N-1 and N, redrawn by their own fns.
  printf '\e[2J\e[1;%dr\e[H' "$((BAR_ROW - 1))" >&2
  BAR_ACTIVE=1
  total_bar_update 0 ""
}

# Render a horizontal bar to a target row. fill/empty chars + colors positional.
_paint_bar() {
  local row="$1" pct="$2" label="$3" fill_ch="$4" empty_ch="$5"
  local fill_color="${6:-}" empty_color="${7:-$C_GREY}"
  local overhead=$(( 9 + ${#label} ))
  local width=$(( BAR_COLS - overhead ))
  (( width < 10 )) && width=10
  local filled=$(( pct * width / 100 ))
  local empty=$(( width - filled ))
  local f e
  printf -v f '%*s' "$filled" ''; f="${f// /$fill_ch}"
  printf -v e '%*s' "$empty"  ''; e="${e// /$empty_ch}"
  printf '\e7\e[%d;1H\e[2K [%s%s%s%s%s%s] %3d%% %s\e8' \
    "$row" "$fill_color" "$f" "$C_RESET" "$empty_color" "$e" "$C_RESET" \
    "$pct" "$label" >&2
}

bar_update() {
  (( BAR_ACTIVE == 1 )) || return 0
  _paint_bar "$BAR_ROW" "$1" "$2" '=' '-' "$C_CYAN"
}

# Total progress bar at the absolute bottom row. Solid blocks distinguish it
# from the per-phase bar above. Only repaints when the integer % changes.
total_bar_update() {
  (( BAR_ACTIVE == 1 )) || return 0
  local pct="$1" label="${2:-}"
  if (( pct == TOTAL_PCT )) && [[ -z "$label" ]]; then return 0; fi
  TOTAL_PCT=$pct
  _paint_bar "$TOTAL_BAR_ROW" "$pct" "$label" '█' '░' "$C_GREEN"
}

bar_finish() {
  spin_stop
  (( BAR_ACTIVE == 1 )) || return 0
  # Clear both reserved rows, reset scroll region.
  printf '\e7\e[%d;1H\e[2K\e[%d;1H\e[2K\e[r\e8' \
    "$BAR_ROW" "$TOTAL_BAR_ROW" >&2
  BAR_ACTIVE=0
}

# Background pulsing-star animation (Claude-Code style). Reads its message
# from SPIN_MSG_FILE every tick so spin_set is cheap.
spin_start() {
  (( BAR_ACTIVE == 1 )) || return 0
  spin_stop
  SPIN_MSG_FILE="$WORK/.spin.msg"
  printf '%s' "${1:-working…}" > "$SPIN_MSG_FILE"
  (
    glyphs=('✢' '✳' '✶' '✻' '✽' '✻' '✶' '✳')
    i=0
    while :; do
      msg=$(cat "$SPIN_MSG_FILE" 2>/dev/null) || msg=""
      printf '\e7\e[%d;1H\e[2K %s%s%s %s\e8' \
        "$BAR_ROW" "$C_CYAN" "${glyphs[$((i % ${#glyphs[@]}))]}" "$C_RESET" "$msg" >&2
      i=$((i + 1))
      sleep 0.1
    done
  ) &
  SPIN_PID=$!
}

spin_set() {
  [[ -n "$SPIN_MSG_FILE" && -e "$SPIN_MSG_FILE" ]] || return 0
  printf '%s' "$*" > "$SPIN_MSG_FILE" 2>/dev/null || true
}

spin_stop() {
  if [[ -n "$SPIN_PID" ]]; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
  fi
  [[ -n "$SPIN_MSG_FILE" ]] && rm -f "$SPIN_MSG_FILE"
  SPIN_MSG_FILE=""
}

QUIT=0

# A directory is "empty-ish" if it contains nothing besides .DS_Store / .localized.
dir_emptyish() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  while IFS= read -r entry; do
    case "$(basename "$entry")" in
      .DS_Store|.localized) ;;
      *) return 1 ;;
    esac
  done < <(find "$d" -mindepth 1 -maxdepth 1 2>/dev/null)
  return 0
}

# After a deletion, walk upward from $1, prompting to remove each empty-ish
# directory. Stops at ROOT or "/". Sets QUIT on user q/a. Always returns 0 —
# stopping early because a dir wasn't empty is normal flow, not an error
# (and a non-zero return would trip set -e in the calling loop body).
maybe_prune_empty_dir() {
  local d="$1"
  while [[ -n "$d" && "$d" != "$ROOT" && "$d" != "/" ]]; do
    [[ -d "$d" ]] || return 0
    dir_emptyish "$d" || return 0
    local ans
    while true; do
      printf '          dir is empty (only .DS_Store ok): %s\n          remove dir? [y/N/q]: ' "$d"
      read -r ans </dev/tty || { QUIT=1; return 0; }
      case "${ans:-N}" in
        y|Y) break ;;
        n|N|"") return 0 ;;
        q|Q|a|A) QUIT=1; return 0 ;;
        *) echo "          (y/N/q?)";;
      esac
    done
    find "$d" -maxdepth 1 -type f \( -name .DS_Store -o -name .localized \) -delete 2>/dev/null
    if rmdir -- "$d" 2>/dev/null; then
      echo "          ${C_GREEN}removed dir${C_RESET}: ${C_DIM}$d${C_RESET}"
      d="$(dirname "$d")"
    else
      echo "          ${C_BOLD}${C_RED}rmdir failed${C_RESET} for $d"
      return 0
    fi
  done
  return 0
}

# Walks files in a directory honoring EXCLUDE_DIRS, .git pruning, .app pruning,
# and EXCLUDE_FILES. Writes paths to stdout.
walk_files() {
  local d="$1"
  find "$d" \
    \( -type d \( "${DIR_EXPR[@]}" \) -prune \) -o \
    \( -type d -name .git -prune \) -o \
    \( -type d -name "*.app" -prune \) -o \
    \( -type f "${FILE_EXPR[@]}" -print \)
}

# Reserve the bottom row for the rest of the script. Bar / spinner share it.
bar_init

# ============================================================
# Phase 1 — discover git repos under ROOT
# ============================================================
echo "${C_BOLD}${C_CYAN}discovering git repos...${C_RESET}" >&2
spin_start "Discovering git repos…"
find "$ROOT" \
  \( -type d \( "${DIR_EXPR[@]}" \) -prune \) -o \
  \( -type d -name .git -print \) 2>/dev/null \
  | sed 's|/\.git$||' \
  | sort -u > "$WORK/repos.lst"
spin_stop

REPO_COUNT=$(count_lines "$WORK/repos.lst")
echo "  found $REPO_COUNT repo(s)" >&2
total_bar_update 5 "discovery"

# ============================================================
# Phase 2 — loose-file dedup (files outside any repo)
# ============================================================
LOOSE_DUP_GROUPS=0
if [[ "$DO_LOOSE" -eq 1 ]]; then
  echo "${C_BOLD}${C_CYAN}scanning loose files...${C_RESET}" >&2
  spin_start "Walking ${ROOT}…"

  walk_files "$ROOT" > "$WORK/all_files.lst" || true
  total_bar_update 10 "walk"
  # MIN_SIZE is applied via stat below; the listing pass is unfiltered.
  : > "$WORK/loose.lst"
  if [[ "$REPO_COUNT" -gt 0 ]]; then
    spin_set "Filtering files inside $REPO_COUNT repo(s)…"
    awk -v rfile="$WORK/repos.lst" '
      BEGIN {
        while ((getline r < rfile) > 0) repos[++n] = r "/"
        close(rfile)
      }
      { for (i=1; i<=n; i++) if (index($0, repos[i]) == 1) next; print }
    ' "$WORK/all_files.lst" > "$WORK/loose.lst"
  else
    cp "$WORK/all_files.lst" "$WORK/loose.lst"
  fi

  spin_set "Sizing loose files…"
  : > "$WORK/loose.by_size.tsv"
  min_bytes=$(awk -v m="$MIN_SIZE" 'BEGIN{
    n=m; gsub(/[^0-9.]/,"",n); n=n+0
    if (m ~ /[Kk]/) n*=1024
    else if (m ~ /[Mm]/) n*=1024*1024
    else if (m ~ /[Gg]/) n*=1024*1024*1024
    print int(n)
  }')
  sized=0
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    sz=$(file_size "$f")
    [[ "$sz" -ge "$min_bytes" ]] || continue
    printf '%s\t%s\n' "$sz" "$f" >> "$WORK/loose.by_size.tsv"
    sized=$((sized + 1))
    if (( sized % 250 == 0 )); then spin_set "Sizing loose files… ($sized)"; fi
  done < "$WORK/loose.lst"
  spin_stop

  LOOSE_TOTAL=$(count_lines "$WORK/loose.by_size.tsv")
  echo "  candidate loose files: $LOOSE_TOTAL" >&2
  total_bar_update 25 "sized"

  # Size-collision pre-filter
  awk -F'\t' '
    { c[$1]++; rows[NR]=$0; sz[NR]=$1 }
    END { for (i=1;i<=NR;i++) if (c[sz[i]] > 1) print rows[i] }
  ' "$WORK/loose.by_size.tsv" > "$WORK/loose.maybe.tsv"

  CAND=$(count_lines "$WORK/loose.maybe.tsv")
  HASH_BYTES=$(awk -F'\t' '{s+=$1} END{print s+0}' "$WORK/loose.maybe.tsv")
  echo "  size collisions: hashing $CAND files ($(human_size "$HASH_BYTES"))" >&2

  : > "$WORK/loose.hashes.tsv"
  n=0
  done_bytes=0
  last_pct=-1
  while IFS=$'\t' read -r sz path; do
    n=$((n+1))
    h=$(md5_of "$path") || h=""
    [[ -n "$h" ]] && printf '%s\t%s\t%s\n' "$h" "$sz" "$path" >> "$WORK/loose.hashes.tsv"
    done_bytes=$(( done_bytes + sz ))
    if (( BAR_ACTIVE == 1 )); then
      pct=$(( HASH_BYTES > 0 ? done_bytes * 100 / HASH_BYTES : 100 ))
      if (( pct != last_pct )); then
        bar_update "$pct" "$n/$CAND  $(human_size "$done_bytes")/$(human_size "$HASH_BYTES")"
        # Map phase % (0..100) into total bar slice 25..60.
        total_bar_update $(( 25 + pct * 35 / 100 )) "hashing"
        last_pct=$pct
      fi
    elif (( n % 200 == 0 )); then
      printf '    hashed %d/%d\n' "$n" "$CAND" >&2
    fi
  done < "$WORK/loose.maybe.tsv"

  spin_start "Grouping duplicates…"
  sort -k1,1 "$WORK/loose.hashes.tsv" | awk -F'\t' '
    { groups[$1]++; data[$1] = data[$1] $2 "\t" $3 "\n"; size[$1] = $2 }
    END {
      for (h in groups) if (groups[h] > 1) {
        printf "GROUP\t%s\t%d\t%d\n%s", h, groups[h], size[h], data[h]
      }
    }
  ' > "$WORK/loose.groups.txt"
  spin_stop

  LOOSE_DUP_GROUPS=$(grep -c '^GROUP	' "$WORK/loose.groups.txt" || true)
  echo "  loose duplicate groups: $LOOSE_DUP_GROUPS" >&2
  total_bar_update 65 "loose-grouped"
fi

# ============================================================
# Phase 3 — repo-level dedup
# ============================================================
REPO_DUP_GROUPS=0
if [[ "$DO_REPOS" -eq 1 && "$REPO_COUNT" -ge 2 ]]; then
  echo "${C_BOLD}${C_CYAN}summarizing $REPO_COUNT repo(s)...${C_RESET}" >&2
  spin_start "Summarizing repos… (0/$REPO_COUNT)"

  : > "$WORK/repo_summary.tsv"
  ri=0
  while IFS= read -r r; do
    ri=$((ri + 1))
    spin_set "Summarizing repos… ($ri/$REPO_COUNT) $(basename "$r")"
    # Map summary progress into total bar slice 65..80.
    total_bar_update $(( 65 + ri * 15 / REPO_COUNT )) "summarizing"
    [[ ! -d "$r" ]] && continue
    walk_files "$r" > "$WORK/_files"
    fc=$(count_lines "$WORK/_files")
    [[ "$fc" -eq 0 ]] && continue
    bytes=0
    while IFS= read -r f; do
      bytes=$((bytes + $(file_size "$f")))
    done < "$WORK/_files"
    printf '%s\t%s\t%s\n' "$r" "$fc" "$bytes" >> "$WORK/repo_summary.tsv"
  done < "$WORK/repos.lst"

  spin_set "Pre-filtering repo candidates…"
  # Cheap pre-filter: only repos sharing (file_count, total_bytes) get hashed.
  awk -F'\t' '
    { key=$2"\t"$3; c[key]++; rows[NR]=$0; k[NR]=key }
    END { for (i=1;i<=NR;i++) if (c[k[i]] > 1) print rows[i] }
  ' "$WORK/repo_summary.tsv" > "$WORK/repo_candidates.tsv"
  spin_stop

  CAND_REPOS=$(count_lines "$WORK/repo_candidates.tsv")
  echo "  repos with size+count collision (full fingerprint): $CAND_REPOS" >&2

  if (( CAND_REPOS > 0 )); then
    spin_start "Fingerprinting repos… (0/$CAND_REPOS)"
  fi
  : > "$WORK/repo_fp.tsv"
  fpi=0
  while IFS=$'\t' read -r r fc bytes; do
    fpi=$((fpi + 1))
    spin_set "Fingerprinting repos… ($fpi/$CAND_REPOS) $(basename "$r")"
    # Map fingerprint progress into total bar slice 82..98.
    total_bar_update $(( 82 + fpi * 16 / CAND_REPOS )) "fingerprinting"
    : > "$WORK/_manifest"
    walk_files "$r" | while IFS= read -r f; do
      rel="${f#$r/}"
      h=$(md5_of "$f")
      printf '%s\t%s\n' "$rel" "$h"
    done | sort > "$WORK/_manifest"
    fp=$(md5_of "$WORK/_manifest")
    printf '%s\t%s\t%s\t%s\n' "$fp" "$r" "$fc" "$bytes" >> "$WORK/repo_fp.tsv"
  done < "$WORK/repo_candidates.tsv"
  spin_stop

  sort -k1,1 "$WORK/repo_fp.tsv" | awk -F'\t' '
    { g[$1]++; d[$1] = d[$1] $2 "\t" $3 "\t" $4 "\n" }
    END {
      for (h in g) if (g[h] > 1) {
        printf "RGROUP\t%s\t%d\n%s", h, g[h], d[h]
      }
    }
  ' > "$WORK/repo.groups.txt"

  REPO_DUP_GROUPS=$(grep -c '^RGROUP	' "$WORK/repo.groups.txt" || true)
  echo "  duplicate repo groups: $REPO_DUP_GROUPS" >&2
fi

total_bar_update 100 "complete"

# ============================================================
# Phase 4 — report mode
# ============================================================
bar_finish

if [[ "$REPORT_ONLY" -eq 1 ]]; then
  if [[ "${REPO_DUP_GROUPS:-0}" -gt 0 ]]; then
    echo
    echo "=== duplicate repos ==="
    awk -F'\t' '
      /^RGROUP\t/ { printf "\n── repo group  fp:%s  ×%d\n", substr($2,1,12), $3; next }
      { printf "    %-7s %-13s %s\n", $2 " files", $3 " bytes", $1 }
    ' "$WORK/repo.groups.txt"
  fi
  if [[ "${LOOSE_DUP_GROUPS:-0}" -gt 0 ]]; then
    echo
    echo "=== duplicate loose files ==="
    awk -F'\t' '
      /^GROUP\t/ { printf "\n── %s  ×%d  (%s each)\n", substr($2,1,12), $3, $4; next }
      { printf "    %s\n", $2 }
    ' "$WORK/loose.groups.txt"
  fi
  if [[ "${REPO_DUP_GROUPS:-0}" -eq 0 && "${LOOSE_DUP_GROUPS:-0}" -eq 0 ]]; then
    echo "no duplicates."
  fi
  exit 0
fi

# ============================================================
# Phase 5a — interactive: duplicate repos
# ============================================================
prompt_repo_group() {
  local total=${#repo_paths[@]}
  local kept_now=$total
  local skip_group=0

  # Re-sort entries by canonical rank (path is in entry|count|bytes).
  if (( total > 1 )); then
    local _sorted entry path
    _sorted=$(
      for entry in "${repo_paths[@]}"; do
        path="${entry%%|*}"
        printf '%d\t%s\n' "$(canonical_rank "$path")" "$entry"
      done | sort -t$'\t' -k1,1n -k2,2 | cut -f2-
    )
    repo_paths=()
    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue
      repo_paths+=("$entry")
    done <<< "$_sorted"
  fi

  echo
  echo "${C_BOLD}${C_YELLOW}── repo group $repo_idx/$REPO_DUP_GROUPS${C_RESET}  ${C_DIM}fp:${current_fp:0:12}  ×$total${C_RESET}"
  for ((i=0; i<total; i++)); do
    local entry="${repo_paths[i]}"
    local p="${entry%%|*}"; local rest="${entry#*|}"
    local fc="${rest%%|*}"; local bytes="${rest#*|}"
    printf '    %s[%d]%s %s%s%s  %s(%s files, %s)%s\n' \
      "$C_CYAN" "$((i+1))" "$C_RESET" \
      "$(path_color "$p")" "$p" "$C_RESET" \
      "$C_DIM" "$fc" "$(human_size "$bytes")" "$C_RESET"
  done

  # Group-bulk prompt: pick the keeper, rm -rf the rest.
  local ans keep_idx=""
  while true; do
    printf '    bulk action? [G=keep [1] / 1-%d=keep that one / Enter=per-repo / s=skip / q=quit]: ' "$total"
    read -r ans </dev/tty || { QUIT=1; return 0; }
    case "${ans:-}" in
      G|g|y|Y) keep_idx=0; break ;;
      ""|n|N) break ;;
      s|S) echo "    ${C_DIM}skipped.${C_RESET}"; return 0 ;;
      q|Q|a|A) QUIT=1; return 0 ;;
      *)
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= total )); then
          keep_idx=$((ans - 1))
          break
        fi
        echo "    (1-$total / G / Enter / s / q?)"
        ;;
    esac
  done

  if [[ -n "$keep_idx" ]]; then
    local keeper_entry="${repo_paths[keep_idx]}"
    local keeper="${keeper_entry%%|*}"
    local deleted=0
    local -a parents=()
    for ((i=0; i<total; i++)); do
      if (( i == keep_idx )); then continue; fi
      local entry="${repo_paths[i]}"
      local p="${entry%%|*}"
      if [[ ! -d "$p" ]]; then continue; fi
      if rm -rf -- "$p"; then
        deleted=$((deleted+1))
        parents+=("$(dirname "$p")")
        echo "          ${C_RED}deleted${C_RESET}: $p"
      else
        echo "          ${C_BOLD}${C_RED}rm -rf failed${C_RESET}: $p"
      fi
    done
    echo "    ${C_BOLD}bulk:${C_RESET} ${C_GREEN}kept${C_RESET} $keeper, ${C_RED}deleted $deleted repo(s).${C_RESET}"
    local d
    while IFS= read -r d; do
      if [[ -z "$d" ]]; then continue; fi
      maybe_prune_empty_dir "$d"
      if (( QUIT == 1 )); then break; fi
    done < <(printf '%s\n' "${parents[@]}" | sort -u)
    return 0
  fi

  # Per-repo prompt
  for ((i=0; i<total; i++)); do
    if (( skip_group == 1 )); then break; fi
    if (( QUIT == 1 )); then break; fi
    local entry="${repo_paths[i]}"
    local p="${entry%%|*}"
    if [[ ! -d "$p" ]]; then continue; fi
    if (( kept_now <= 1 )); then
      echo "    [$((i+1))/$total] $p"
      echo "          (last remaining copy — auto-keep)"
      continue
    fi
    while true; do
      printf '    [%d/%d] %s\n          delete entire repo? [y/N/s/q]: ' "$((i+1))" "$total" "$p"
      read -r ans </dev/tty || { QUIT=1; break; }
      case "${ans:-N}" in
        y|Y)
          if rm -rf -- "$p"; then
            kept_now=$((kept_now-1))
            echo "          ${C_RED}deleted (rm -rf).${C_RESET}"
            maybe_prune_empty_dir "$(dirname "$p")"
          else
            echo "          ${C_BOLD}${C_RED}rm -rf failed.${C_RESET}"
          fi
          break ;;
        n|N|"") echo "          ${C_GREEN}kept.${C_RESET}"; break ;;
        s|S)    skip_group=1; echo "          ${C_DIM}skipping rest of group.${C_RESET}"; break ;;
        q|Q|a|A) QUIT=1; echo "          ${C_BOLD}${C_RED}quitting.${C_RESET}"; break ;;
        *)      echo "          (y/N/s/q?)";;
      esac
    done
  done
  return 0
}

if [[ "${REPO_DUP_GROUPS:-0}" -gt 0 ]]; then
  echo
  echo "${C_BOLD}${C_MAGENTA}=== duplicate repos ===${C_RESET}"
  echo "${C_DIM}for each repo: y=rm -rf this entire repo, N=keep, s=skip group, q=quit${C_RESET}"

  repo_idx=0
  current_fp=""
  declare -a repo_paths

  while IFS=$'\t' read -r col1 col2 col3 col4; do
    if [[ "$col1" == "RGROUP" ]]; then
      if [[ -n "$current_fp" ]]; then
        prompt_repo_group
        if (( QUIT == 1 )); then break; fi
      fi
      repo_idx=$((repo_idx + 1))
      current_fp="$col2"
      repo_paths=()
    else
      repo_paths+=("${col1}|${col2}|${col3}")
    fi
  done < "$WORK/repo.groups.txt"

  if [[ "$QUIT" -eq 0 && -n "$current_fp" ]]; then
    prompt_repo_group
  fi
fi

# ============================================================
# Phase 5b — interactive: duplicate loose files
# ============================================================
prompt_file_group() {
  local total=${#current_paths[@]}
  local kept_now=$total
  local skip_group=0

  # Re-sort by canonical rank so [1] is the most canonical copy.
  if (( total > 1 )); then
    local _sorted p
    _sorted=$(
      for p in "${current_paths[@]}"; do
        printf '%d\t%s\n' "$(canonical_rank "$p")" "$p"
      done | sort -t$'\t' -k1,1n -k2,2 | cut -f2-
    )
    current_paths=()
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      current_paths+=("$p")
    done <<< "$_sorted"
  fi

  echo
  echo "${C_BOLD}${C_YELLOW}── group $group_idx/$LOOSE_DUP_GROUPS${C_RESET}  ${C_DIM}md5:${current_hash:0:12}  ×$total  ($(human_size "$current_size") each)${C_RESET}"
  for ((i=0; i<total; i++)); do
    local _p="${current_paths[i]}"
    echo "    ${C_CYAN}[$((i+1))]${C_RESET} $(path_color "$_p")$_p${C_RESET}"
  done

  # Group-bulk prompt: pick the keeper, delete the rest.
  local ans keep_idx=""
  while true; do
    printf '    bulk action? [G=keep [1] / 1-%d=keep that one / Enter=per-file / s=skip / q=quit]: ' "$total"
    read -r ans </dev/tty || { QUIT=1; return 0; }
    case "${ans:-}" in
      G|g|y|Y) keep_idx=0; break ;;
      ""|n|N) break ;;
      s|S) echo "    ${C_DIM}skipped.${C_RESET}"; return 0 ;;
      q|Q|a|A) QUIT=1; return 0 ;;
      *)
        if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= total )); then
          keep_idx=$((ans - 1))
          break
        fi
        echo "    (1-$total / G / Enter / s / q?)"
        ;;
    esac
  done

  if [[ -n "$keep_idx" ]]; then
    local keeper="${current_paths[keep_idx]}"
    local deleted=0
    local -a parents=()
    for ((i=0; i<total; i++)); do
      (( i == keep_idx )) && continue
      local p="${current_paths[i]}"
      [[ ! -e "$p" ]] && continue
      if rm -- "$p"; then
        deleted=$((deleted+1))
        parents+=("$(dirname "$p")")
        echo "          ${C_RED}deleted${C_RESET}: $p"
      else
        echo "          ${C_BOLD}${C_RED}rm failed${C_RESET}: $p"
      fi
    done
    echo "    ${C_BOLD}bulk:${C_RESET} ${C_GREEN}kept${C_RESET} $keeper, ${C_RED}deleted $deleted file(s).${C_RESET}"
    local d
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      maybe_prune_empty_dir "$d"
      if (( QUIT == 1 )); then break; fi
    done < <(printf '%s\n' "${parents[@]}" | sort -u)
    return 0
  fi

  for ((i=0; i<total; i++)); do
    if (( skip_group == 1 )); then break; fi
    if (( QUIT == 1 )); then break; fi
    local p="${current_paths[i]}"
    if [[ ! -e "$p" ]]; then continue; fi
    if (( kept_now <= 1 )); then
      echo "    [$((i+1))/$total] $p"
      echo "          (last remaining copy — auto-keep)"
      continue
    fi
    while true; do
      printf '    [%d/%d] %s\n          delete? [y/N/s/q]: ' "$((i+1))" "$total" "$p"
      read -r ans </dev/tty || { QUIT=1; break; }
      case "${ans:-N}" in
        y|Y)
          if rm -- "$p"; then
            kept_now=$((kept_now-1))
            echo "          ${C_RED}deleted.${C_RESET}"
            maybe_prune_empty_dir "$(dirname "$p")"
          else
            echo "          ${C_BOLD}${C_RED}rm failed.${C_RESET}"
          fi
          break ;;
        n|N|"") echo "          ${C_GREEN}kept.${C_RESET}"; break ;;
        s|S)    skip_group=1; echo "          ${C_DIM}skipping rest of group.${C_RESET}"; break ;;
        q|Q|a|A) QUIT=1; echo "          ${C_BOLD}${C_RED}quitting.${C_RESET}"; break ;;
        *)      echo "          (y/N/s/q?)";;
      esac
    done
  done
  return 0
}

if [[ "$QUIT" -eq 0 && "${LOOSE_DUP_GROUPS:-0}" -gt 0 ]]; then
  echo
  echo "${C_BOLD}${C_MAGENTA}=== duplicate loose files ===${C_RESET}"
  echo "${C_DIM}for each file: y=delete, N=keep, s=skip group, q=quit${C_RESET}"

  group_idx=0
  current_hash=""
  current_size=0
  declare -a current_paths

  while IFS=$'\t' read -r col1 col2 col3 col4; do
    if [[ "$col1" == "GROUP" ]]; then
      if [[ -n "$current_hash" ]]; then
        prompt_file_group
        if (( QUIT == 1 )); then break; fi
      fi
      group_idx=$((group_idx + 1))
      current_hash="$col2"
      current_size="$col4"
      current_paths=()
    else
      current_paths+=("$col2")
    fi
  done < "$WORK/loose.groups.txt"

  if [[ "$QUIT" -eq 0 && -n "$current_hash" ]]; then
    prompt_file_group
  fi
fi

echo
echo "done."
