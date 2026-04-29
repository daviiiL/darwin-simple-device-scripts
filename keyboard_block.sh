#!/usr/bin/env bash
# System-wide keyboard sink. Type `start` to begin; press ESC 5x consecutively
# (each within 1s of the last) to release. Backed by a Swift CGEventTap helper
# that requires Accessibility permission on first run.

set -euo pipefail

readonly ESC_TARGET=5
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SWIFT_SRC="${SCRIPT_DIR}/kbsink.swift"
readonly SWIFT_BIN="${SCRIPT_DIR}/kbsink"

# ANSI styling
readonly C_BOX=$'\033[38;5;81m'
readonly C_TITLE=$'\033[1;97m'
readonly C_DIM=$'\033[38;5;240m'
readonly C_OK=$'\033[1;32m'
readonly C_WARN=$'\033[1;33m'
readonly C_DONE=$'\033[1;35m'
readonly C_ERR=$'\033[1;31m'
readonly C_RST=$'\033[0m'

build_helper() {
    [[ -f "$SWIFT_SRC" ]] || {
        printf '%serror:%s %s missing\n' "$C_ERR" "$C_RST" "$SWIFT_SRC" >&2
        exit 1
    }
    if [[ ! -x "$SWIFT_BIN" || "$SWIFT_SRC" -nt "$SWIFT_BIN" ]]; then
        printf 'Compiling kbsink helper...\n'
        if ! swiftc -O "$SWIFT_SRC" -o "$SWIFT_BIN"; then
            printf '%serror:%s swiftc failed (install Xcode CLI tools: xcode-select --install)\n' \
                "$C_ERR" "$C_RST" >&2
            exit 1
        fi
    fi
}

render() {
    local count=$1 i bar=''
    for ((i = 0; i < ESC_TARGET; i++)); do
        if (( i < count )); then
            bar+="${C_OK}█${C_RST}"
        else
            bar+="${C_DIM}░${C_RST}"
        fi
    done

    local status_color=$C_WARN status_text='ACTIVE  '
    if (( count >= ESC_TARGET )); then
        status_color=$C_DONE
        status_text='RELEASED'
    fi

    printf '\033[H'
    printf '%s┌──────────────────────────────────────────┐%s\n' "$C_BOX" "$C_RST"
    printf '%s│%s           %sKEEB BLOCK CLEANING%s            %s│%s\n' \
        "$C_BOX" "$C_RST" "$C_TITLE" "$C_RST" "$C_BOX" "$C_RST"
    printf '%s├──────────────────────────────────────────┤%s\n' "$C_BOX" "$C_RST"
    printf '%s│%s                                          %s│%s\n' "$C_BOX" "$C_RST" "$C_BOX" "$C_RST"
    printf '%s│%s  Status    %s%s%s                      %s│%s\n' \
        "$C_BOX" "$C_RST" "$status_color" "$status_text" "$C_RST" "$C_BOX" "$C_RST"
    printf '%s│%s  Progress  %s  %d / %d                  %s│%s\n' \
        "$C_BOX" "$C_RST" "$bar" "$count" "$ESC_TARGET" "$C_BOX" "$C_RST"
    printf '%s│%s                                          %s│%s\n' "$C_BOX" "$C_RST" "$C_BOX" "$C_RST"
    printf '%s│%s  %sPress ESC %d× within 1s gaps to release%s  %s│%s\n' \
        "$C_BOX" "$C_RST" "$C_DIM" "$ESC_TARGET" "$C_RST" "$C_BOX" "$C_RST"
    printf '%s│%s                                          %s│%s\n' "$C_BOX" "$C_RST" "$C_BOX" "$C_RST"
    printf '%s└──────────────────────────────────────────┘%s\n' "$C_BOX" "$C_RST"
}

build_helper

read -rp 'Type "start" to begin blocking input: ' trigger
[[ "$trigger" == "start" ]] || { echo "Aborted."; exit 1; }

swift_pid=
fifo=
released=0

restore() {
    if [[ -n "$swift_pid" ]] && kill -0 "$swift_pid" 2>/dev/null; then
        kill "$swift_pid" 2>/dev/null || true
        wait "$swift_pid" 2>/dev/null || true
    fi
    [[ -n "$fifo" && -p "$fifo" ]] && rm -f "$fifo"
    printf '\033[?25h'
    if (( released )); then
        printf '\n%sKeyboard released.%s\n' "$C_DONE" "$C_RST"
    else
        printf '\n%skbsink exited before release.%s If permission was just granted, re-run.\n' \
            "$C_ERR" "$C_RST"
        printf '%sAccessibility permission lives at:%s %s\n' "$C_DIM" "$C_RST" "$SWIFT_BIN"
    fi
}
trap restore EXIT INT TERM

fifo="$(mktemp -u "${TMPDIR:-/tmp}/kbsink.XXXXXX").fifo"
mkfifo "$fifo"

printf '\033[?25l\033[2J'
render 0

"$SWIFT_BIN" > "$fifo" 2>&1 &
swift_pid=$!

while IFS= read -r line; do
    case "$line" in
        ready)
            ;;
        count=*)
            render "${line#count=}"
            ;;
        released)
            released=1
            render "$ESC_TARGET"
            break
            ;;
        *)
            printf '%s%s%s\n' "$C_ERR" "$line" "$C_RST" >&2
            ;;
    esac
done < "$fifo"
