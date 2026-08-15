#!/usr/bin/env bash
# common.sh — shared helpers for the project scaffolding scripts.
# Sourced by main.sh and by every script in scaffolds/.
# Targets bash 3.2 (the macOS system bash): no associative arrays, no mapfile,
# no ${var,,}.

# ---------------------------------------------------------------- output ----

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_DIM=$'\033[2m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

log_info()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
log_ok()    { printf '%s\n' "${C_GREEN} ok${C_RESET} $*"; }
log_warn()  { printf '%s\n' "${C_YELLOW}  ! ${C_RESET}$*" >&2; }
log_err()   { printf '%s\n' "${C_RED}  x ${C_RESET}$*" >&2; }
log_add()   { printf '%s\n' "${C_DIM}  + ${C_RESET}$*"; }
log_step()  { printf '\n%s\n' "${C_BOLD}$*${C_RESET}"; }
log_hint()  { printf '%s\n' "${C_DIM}    $*${C_RESET}" >&2; }

banner() {
    printf '\n%s\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"
    printf '%s\n' "${C_DIM}$(printf '%*s' "${#1}" '' | tr ' ' '-')${C_RESET}"
}

die() { log_err "$*"; exit 1; }

# ---------------------------------------------------------------- prompts ---

# Only --yes turns prompting off. A pipe or a redirect still feeds the reads,
# and every read below falls back to its default on EOF, so a run with no
# stdin at all cannot hang.
is_interactive() {
    [ "${SCAFFOLD_ASSUME_YES:-0}" != "1" ]
}

# ask "Question" "default" -> echoes the answer on stdout
# Prompts go to stderr so the result can be captured with $( ).
ask() {
    _q="$1"; _default="${2:-}"; _ans=""
    if ! is_interactive; then
        printf '%s\n' "$_default"
        return 0
    fi
    if [ -n "$_default" ]; then
        printf '%s' "${C_BOLD}?${C_RESET} $_q ${C_DIM}[$_default]${C_RESET}: " >&2
    else
        printf '%s' "${C_BOLD}?${C_RESET} $_q: " >&2
    fi
    IFS= read -r _ans || _ans=""
    [ -n "$_ans" ] || _ans="$_default"
    printf '%s\n' "$_ans"
}

# ask_yes_no "Question" "y|n"  -> returns 0 for yes, 1 for no
ask_yes_no() {
    _q="$1"; _default="${2:-y}"; _hint="Y/n"; _ans=""
    [ "$_default" = "y" ] || _hint="y/N"
    if ! is_interactive; then
        [ "$_default" = "y" ]
        return $?
    fi
    while :; do
        printf '%s' "${C_BOLD}?${C_RESET} $_q ${C_DIM}[$_hint]${C_RESET}: " >&2
        IFS= read -r _ans || _ans=""
        [ -n "$_ans" ] || _ans="$_default"
        case "$(printf '%s' "$_ans" | tr '[:upper:]' '[:lower:]')" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) log_warn "Please answer y or n." ;;
        esac
    done
}

# -------------------------------------------------------------- utilities ---

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Expand a leading ~ in a user-supplied path.
expand_path() {
    case "$1" in
        "~")   printf '%s\n' "$HOME" ;;
        "~/"*) printf '%s\n' "$HOME/${1#\~/}" ;;
        *)     printf '%s\n' "$1" ;;
    esac
}

# Project names that are safe as a directory name and as a Make target.
valid_project_name() {
    case "$1" in
        ""|*[!A-Za-z0-9._-]*|-*|.*) return 1 ;;
        *) return 0 ;;
    esac
}

# ---------------------------------------------------- dependency checking ---
#
# Dependencies are reported, never installed. check_dep records what is
# missing; dep_report() prints the summary and the exact install commands.

DEPS_MISSING=0
DEPS_HINTS=""
DEP_OK=1   # result of the most recent check_dep, for callers that need it

# check_dep <label> <test command> <install hint> [required|optional]
# Always returns 0 so a missing dependency never trips `set -e`; inspect
# $DEP_OK afterwards if the caller cares.
check_dep() {
    _label="$1"; _test="$2"; _hint="$3"; _kind="${4:-required}"
    if eval "$_test" >/dev/null 2>&1; then
        log_ok "$_label"
        DEP_OK=1
        return 0
    fi
    DEP_OK=0
    if [ "$_kind" = "optional" ]; then
        log_warn "$_label — missing (optional)"
    else
        log_err "$_label — missing"
        DEPS_MISSING=$((DEPS_MISSING + 1))
    fi
    DEPS_HINTS="${DEPS_HINTS}${_label}"$'\n'"    ${_hint}"$'\n'
    return 0
}

dep_report() {
    if [ -z "$DEPS_HINTS" ]; then
        log_ok "All dependencies satisfied."
        return 0
    fi
    printf '\n%s\n' "${C_YELLOW}Missing dependencies — install with:${C_RESET}" >&2
    printf '%s' "$DEPS_HINTS" | while IFS= read -r _line; do
        printf '  %s\n' "$_line" >&2
    done
    printf '\n' >&2
    log_warn "The project will still be generated; install the above before building."
    return 0
}

# write_file <path> — reads content from stdin, creates parent dirs, logs it.
write_file() {
    _path="$1"
    mkdir -p "$(dirname "$_path")"
    cat > "$_path"
    log_add "${_path#"$SCAFFOLD_TARGET_DIR"/}"
}
