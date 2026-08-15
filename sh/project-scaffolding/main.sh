#!/usr/bin/env bash
# main.sh — menu front-end for the project scaffolds.
#
# Collects the information every scaffold needs (which template, project name,
# where to put it, whether to init git), then hands off to the matching script
# in scaffolds/, which creates the actual files and folders.
#
# Usage:
#   ./main.sh                         # interactive menu
#   ./main.sh metal-cpp               # pick the scaffold up front
#   ./main.sh metal-cpp --name foo --dir ~/code --yes
#   ./main.sh --list
#
# Adding a scaffold: drop a script in scaffolds/ with these header comments:
#   # scaffold-name: Human readable name
#   # scaffold-description: One line shown in the menu.
#   # scaffold-default-name: default_project_name
# It is picked up automatically — no edits to this file.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCAFFOLDS_DIR="$SCRIPT_DIR/scaffolds"
LIB_DIR="$SCRIPT_DIR/lib"

# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"

usage() {
    cat <<EOF
${C_BOLD}project-scaffolding${C_RESET} — generate a ready-to-build project skeleton.

${C_BOLD}Usage${C_RESET}
  ./main.sh [scaffold] [options]

${C_BOLD}Options${C_RESET}
  --name NAME     Project name (also the directory name)
  --dir DIR       Parent directory to create the project in (default: cwd)
  --no-git        Skip 'git init'
  -y, --yes       Accept all defaults, never prompt
  -l, --list      List available scaffolds and exit
  -h, --help      Show this help

${C_BOLD}Examples${C_RESET}
  ./main.sh
  ./main.sh metal-cpp --name particles --dir ~/code
EOF
}

# ------------------------------------------------- discover the scaffolds ---

meta_field() { sed -n "s/^# $1:[[:space:]]*//p" "$2" | head -1; }

SCAFFOLD_KEYS=()
SCAFFOLD_PATHS=()
SCAFFOLD_NAMES=()
SCAFFOLD_DESCS=()

discover_scaffolds() {
    [ -d "$SCAFFOLDS_DIR" ] || die "No scaffolds directory at $SCAFFOLDS_DIR"
    local f key name desc
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        key="$(basename "$f" .sh)"
        name="$(meta_field "scaffold-name" "$f")"
        desc="$(meta_field "scaffold-description" "$f")"
        [ -n "$name" ] || name="$key"
        SCAFFOLD_KEYS+=("$key")
        SCAFFOLD_PATHS+=("$f")
        SCAFFOLD_NAMES+=("$name")
        SCAFFOLD_DESCS+=("$desc")
    done < <(find "$SCAFFOLDS_DIR" -maxdepth 1 -type f -name '*.sh' | sort)

    [ "${#SCAFFOLD_KEYS[@]}" -gt 0 ] || die "No scaffolds found in $SCAFFOLDS_DIR"
}

list_scaffolds() {
    local i
    for i in $(seq 0 $(( ${#SCAFFOLD_KEYS[@]} - 1 ))); do
        printf '  %s%d%s) %s%s%s  %s(%s)%s\n' \
            "$C_BOLD" "$((i + 1))" "$C_RESET" \
            "$C_BOLD" "${SCAFFOLD_NAMES[$i]}" "$C_RESET" \
            "$C_DIM" "${SCAFFOLD_KEYS[$i]}" "$C_RESET"
        [ -n "${SCAFFOLD_DESCS[$i]}" ] && printf '     %s%s%s\n' "$C_DIM" "${SCAFFOLD_DESCS[$i]}" "$C_RESET"
    done
}

# Resolve a key or a menu number to an index; echoes the index or returns 1.
resolve_scaffold() {
    local want="$1" i
    case "$want" in
        ''|*[!0-9]*) ;;
        *)
            if [ "$want" -ge 1 ] && [ "$want" -le "${#SCAFFOLD_KEYS[@]}" ]; then
                printf '%s\n' "$((want - 1))"
                return 0
            fi
            return 1 ;;
    esac
    for i in $(seq 0 $(( ${#SCAFFOLD_KEYS[@]} - 1 ))); do
        if [ "${SCAFFOLD_KEYS[$i]}" = "$want" ]; then
            printf '%s\n' "$i"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------- args ---

OPT_SCAFFOLD=""
OPT_NAME=""
OPT_DIR=""
OPT_GIT=1

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -l|--list) discover_scaffolds; banner "Available scaffolds"; list_scaffolds; exit 0 ;;
        -y|--yes)  SCAFFOLD_ASSUME_YES=1 ;;
        --no-git)  OPT_GIT=0 ;;
        --name)    shift; [ $# -gt 0 ] || die "--name needs a value"; OPT_NAME="$1" ;;
        --dir)     shift; [ $# -gt 0 ] || die "--dir needs a value"; OPT_DIR="$1" ;;
        --name=*)  OPT_NAME="${1#--name=}" ;;
        --dir=*)   OPT_DIR="${1#--dir=}" ;;
        -*)        die "Unknown option: $1 (try --help)" ;;
        *)
            [ -z "$OPT_SCAFFOLD" ] || die "Unexpected argument: $1"
            OPT_SCAFFOLD="$1" ;;
    esac
    shift
done
export SCAFFOLD_ASSUME_YES="${SCAFFOLD_ASSUME_YES:-0}"

discover_scaffolds

# ------------------------------------------------------------------- menu ---

banner "Project scaffolding"

if [ -n "$OPT_SCAFFOLD" ]; then
    idx="$(resolve_scaffold "$OPT_SCAFFOLD")" || die "Unknown scaffold: $OPT_SCAFFOLD (try --list)"
else
    printf 'Which project scaffold would you like to generate?\n\n'
    list_scaffolds
    printf '\n'
    if ! is_interactive; then
        idx=0
        log_info "Non-interactive: defaulting to ${SCAFFOLD_NAMES[0]}"
    else
        idx=""
        while [ -z "$idx" ]; do
            choice="$(ask "Selection (number, name, or q to quit)" "1")"
            case "$choice" in
                q|Q|quit|exit) printf 'Nothing generated.\n'; exit 0 ;;
            esac
            if ! idx="$(resolve_scaffold "$choice")"; then
                log_warn "'$choice' is not one of the options."
                idx=""
            fi
        done
    fi
fi

SELECTED_PATH="${SCAFFOLD_PATHS[$idx]}"
SELECTED_NAME="${SCAFFOLD_NAMES[$idx]}"
DEFAULT_NAME="$(meta_field "scaffold-default-name" "$SELECTED_PATH")"
[ -n "$DEFAULT_NAME" ] || DEFAULT_NAME="my_project"

log_info "Scaffold: ${C_BOLD}${SELECTED_NAME}${C_RESET}"

# ------------------------------------------------------- common questions ---

project_name="$OPT_NAME"
while :; do
    [ -n "$project_name" ] || project_name="$(ask "Project name" "$DEFAULT_NAME")"
    if valid_project_name "$project_name"; then
        break
    fi
    log_warn "Use letters, digits, '.', '_' or '-', and don't start with '-' or '.'."
    project_name=""
    is_interactive || die "Invalid project name."
done

parent_dir="$OPT_DIR"
[ -n "$parent_dir" ] || parent_dir="$(ask "Create it inside which directory" "$PWD")"
parent_dir="$(expand_path "$parent_dir")"

if [ ! -d "$parent_dir" ]; then
    ask_yes_no "$parent_dir does not exist. Create it?" "y" \
        || die "Aborted — parent directory does not exist."
    mkdir -p "$parent_dir" || die "Could not create $parent_dir"
fi
parent_dir="$(cd -- "$parent_dir" && pwd)"

target_dir="$parent_dir/$project_name"
if [ -e "$target_dir" ]; then
    if [ -d "$target_dir" ] && [ -z "$(ls -A "$target_dir" 2>/dev/null)" ]; then
        log_info "$target_dir exists but is empty — using it."
    else
        log_warn "$target_dir already exists and is not empty."
        ask_yes_no "Write into it anyway? Existing files with the same names will be overwritten." "n" \
            || die "Aborted — pick another name or directory."
    fi
fi

git_init=0
if [ "$OPT_GIT" -eq 1 ] && have_cmd git; then
    if [ -d "$target_dir/.git" ]; then
        log_info "Already a git repository — skipping 'git init'."
    elif ask_yes_no "Initialize a git repository?" "y"; then
        git_init=1
    fi
fi

# ------------------------------------------------------------- handoff -----

export SCAFFOLD_PROJECT_NAME="$project_name"
export SCAFFOLD_TARGET_DIR="$target_dir"
export SCAFFOLD_GIT_INIT="$git_init"
export SCAFFOLD_LIB_DIR="$LIB_DIR"

bash "$SELECTED_PATH" || die "Scaffold '$SELECTED_NAME' failed."

if [ "$git_init" -eq 1 ]; then
    git -C "$target_dir" init -q && log_ok "Initialized empty git repository."
fi

printf '\n%s %s\n' "${C_GREEN}${C_BOLD}Done.${C_RESET}" "Project created at ${C_BOLD}${target_dir}${C_RESET}"
