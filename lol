#!/usr/bin/env bash
# lol — Lots Of Logs inspector for OpenShift must-gathers

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

VERSION="0.1.0"
CHECKS_DIR="$SCRIPT_DIR/checks"

usage() {
  cat <<EOF
lol v$VERSION — must-gather inspector

Commands:
  use <path>              Set the active must-gather
  inspect [-c <checks>]   Run checks against the active must-gather
  list                    List available checks
  status                  Show active must-gather path

Options:
  -c, --check <name,...>  Checks to run (default: all). Used with inspect.
  -h, --help              Show this help
  -v, --version           Show version

Examples:
  lol use /path/to/must-gather
  lol inspect
  lol inspect -c etcd
  lol inspect -c etcd,nodes,pdbs
  lol list
  lol status
EOF
}

get_all_check_names() {
  local names=()
  for f in "$CHECKS_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    names+=("$(basename "$f" .sh)")
  done
  echo "${names[@]}"
}

cmd_use() {
  local path="${1:-}"
  if [[ -z "$path" ]]; then
    err "Usage: lol use <must-gather-path>"
    exit 1
  fi
  if [[ ! -d "$path" ]]; then
    err "Not a directory: $path"
    exit 1
  fi
  mkdir -p "$(dirname "$LOL_CONTEXT_FILE")"
  echo "$path" > "$LOL_CONTEXT_FILE"
  ok "Active must-gather: $path"
}

cmd_status() {
  if [[ ! -f "$LOL_CONTEXT_FILE" ]]; then
    info "No must-gather set. Run: lol use <path>"
    return
  fi
  local path
  path="$(cat "$LOL_CONTEXT_FILE")"
  if [[ -d "$path" ]]; then
    ok "Active must-gather: $path"
  else
    warn "Active must-gather (directory missing): $path"
  fi
}

cmd_list() {
  echo
  header "Available checks:"
  for f in "$CHECKS_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    local name desc
    name="$(basename "$f" .sh)"
    desc="$(grep -m1 '^# DESC:' "$f" | sed 's/^# DESC: *//')" || desc="(no description)"
    printf "  ${BOLD}%-20s${RESET} %s\n" "$name" "$desc"
  done
  echo
}

run_checks() {
  local mg_path="$1"; shift
  local -a check_names=("$@")
  local findings=0 errors=0

  print_banner
  info "Must-gather: $mg_path"
  info "Checks:      ${check_names[*]}"
  echo

  if ! command -v omc &>/dev/null; then
    err "'omc' not found in PATH — required for must-gather inspection"
    exit 2
  fi

  for name in "${check_names[@]}"; do
    local check_file="$CHECKS_DIR/${name}.sh"
    if [[ ! -f "$check_file" ]]; then
      err "Unknown check: '$name'"
      ((errors++)) || true
      continue
    fi

    section "CHECK: $name"
    local rc=0
    bash "$check_file" "$mg_path" || rc=$?
    echo

    if   [[ $rc -eq 1 ]]; then ((findings++)) || true
    elif [[ $rc -ge 2 ]]; then ((errors++))   || true
    fi
  done

  section "SUMMARY"
  if [[ $findings -eq 0 && $errors -eq 0 ]]; then
    ok "All ${#check_names[@]} check(s) passed — no issues found"
  else
    [[ $findings -gt 0 ]] && warn "$findings check(s) reported findings"
    [[ $errors   -gt 0 ]] && err  "$errors check(s) encountered errors"
  fi
  echo
}

cmd_inspect() {
  local -a check_names=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--check) IFS=',' read -ra check_names <<< "$2"; shift 2 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done

  local mg_path
  mg_path="$(resolve_mg_path)" || exit 1

  if [[ ${#check_names[@]} -eq 0 ]]; then
    read -ra check_names <<< "$(get_all_check_names)"
  fi

  if [[ ${#check_names[@]} -eq 0 ]]; then
    err "No checks found in $CHECKS_DIR"
    exit 1
  fi

  run_checks "$mg_path" "${check_names[@]}"
}

main() {
  if [[ $# -eq 0 ]]; then
    usage; exit 0
  fi

  local cmd="$1"; shift

  case "$cmd" in
    use)              cmd_use "$@" ;;
    inspect)          cmd_inspect "$@" ;;
    list)             cmd_list ;;
    status)           cmd_status ;;
    version|--version|-v) echo "lol v$VERSION" ;;
    help|--help|-h)   usage ;;
    *) err "Unknown command: '$cmd'"; echo; usage; exit 1 ;;
  esac
}

main "$@"
