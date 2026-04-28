#!/usr/bin/env bash
# Shared utilities for lol — source this, don't run directly

# ── Colors ─────────────────────────────────────────────────────────────────
# LOL_FORCE_COLOR=1 enables colors even when stdout is not a terminal
# (used internally when capturing check output to a temp file for logging)
if [[ -t 1 ]] || [[ "${LOL_FORCE_COLOR:-}" == "1" ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ── Paths ──────────────────────────────────────────────────────────────────
_LOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNATURES_DIR="$_LOL_ROOT/signatures"
LOL_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lol"
LOL_CONTEXT_FILE="$LOL_CONFIG_DIR/context"          # active mg path (anon or named)
LOL_ACTIVE_CTX_FILE="$LOL_CONFIG_DIR/active_context" # name of active named context
LOL_CONTEXTS_DIR="$LOL_CONFIG_DIR/contexts"          # named context ledgers

# ── Output helpers ─────────────────────────────────────────────────────────
print_banner() {
  # Plain fallback when color is not available
  if [[ -z "$CYAN" ]]; then
    printf '\nlol — Lots Of Logs inspector\n\n'
    return
  fi

  local R='\033[0m' B='\033[1m'

  # L columns: neon cyan → electric blue (top → bottom)
  local l1='\033[38;5;51m'  l2='\033[38;5;45m'  l3='\033[38;5;39m'
  local l4='\033[38;5;33m'  l5='\033[38;5;27m'  l6='\033[38;5;21m'

  # O column: hot pink → deep purple (top → bottom)
  local o1='\033[38;5;213m' o2='\033[38;5;207m' o3='\033[38;5;171m'
  local o4='\033[38;5;135m' o5='\033[38;5;129m' o6='\033[38;5;93m'

  printf '\n'
  printf "  ${B}${l1}██╗     ${R}${B}${o1} ██████╗ ${R}${B}${l1}██╗     ${R}\n"
  printf "  ${B}${l2}██║     ${R}${B}${o2}██╔═══██╗${R}${B}${l2}██║     ${R}\n"
  printf "  ${B}${l3}██║     ${R}${B}${o3}██║   ██║${R}${B}${l3}██║     ${R}\n"
  printf "  ${B}${l4}██║     ${R}${B}${o4}██║   ██║${R}${B}${l4}██║     ${R}\n"
  printf "  ${B}${l5}███████╗${R}${B}${o5}╚██████╔╝${R}${B}${l5}███████╗${R}\n"
  printf "  ${B}${l6}╚══════╝${R}${B}${o6} ╚═════╝ ${R}${B}${l6}╚══════╝${R}\n"
  printf '\n'
  printf '  \033[38;5;245m\033[2mLots Of Logs  ·  OpenShift must-gather inspector\033[0m\n'
  printf '\n'
}

header()   { echo -e "${BOLD}==> $*${RESET}"; }
section()  { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${RESET}"; }
ok()       { echo -e "${GREEN}[  OK  ]${RESET} $*"; }
warn()     { echo -e "${YELLOW}[ WARN  ]${RESET} $*"; }
err()      { echo -e "${RED}[  ERR  ]${RESET} $*" >&2; }
info()     { echo -e "${DIM}[ INFO  ]${RESET} $*"; }
finding()  { echo -e "${YELLOW}[FINDING]${RESET} $*"; }
critical() { echo -e "${RED}[CRITICAL]${RESET} $*"; }

# ── Context resolution ─────────────────────────────────────────────────────
# resolve_mg_path [optional-explicit-path]
#   Priority: explicit arg > active named context > anonymous session
resolve_mg_path() {
  local path="${1:-}"

  if [[ -z "$path" ]]; then
    if [[ -f "$LOL_ACTIVE_CTX_FILE" ]]; then
      local ctx
      ctx="$(cat "$LOL_ACTIVE_CTX_FILE")"
      local meta="$LOL_CONTEXTS_DIR/$ctx/meta.env"
      if [[ -f "$meta" ]]; then
        path="$(grep '^CURRENT_MG=' "$meta" | cut -d= -f2-)"
      fi
    fi
    if [[ -z "$path" ]] && [[ -f "$LOL_CONTEXT_FILE" ]]; then
      path="$(cat "$LOL_CONTEXT_FILE")"
    fi
    if [[ -z "$path" ]]; then
      err "No must-gather set. Run: lol use <path>"
      return 1
    fi
  fi

  if [[ ! -d "$path" ]]; then
    err "Must-gather directory not found: $path"
    return 1
  fi

  echo "$path"
}

# ── omc context ────────────────────────────────────────────────────────────
omc_use() {
  local path="$1"
  if ! command omc use "$path" &>/dev/null; then
    err "Failed to load must-gather with omc: $path"
    return 2
  fi
}

# ── PII scrubbing ──────────────────────────────────────────────────────────
# scrub_pii <text>
#   Best-effort redaction of common PII patterns. Not guaranteed to catch
#   everything — always review handoff documents before sharing externally.
scrub_pii() {
  echo "$1" \
    | sed -E 's/\b([0-9]{1,3}\.){3}[0-9]{1,3}\b/[REDACTED:ipv4]/g' \
    | sed -E 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[REDACTED:uuid]/g' \
    | sed -E 's/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[REDACTED:email]/g' \
    | sed -E 's/(console-openshift-console\.apps\.|api\.)[a-zA-Z0-9._-]+/[REDACTED:cluster-url]/g'
}

# ── TUI helpers (gum with plain-shell fallback) ────────────────────────────

# _tui_confirm <prompt>
#   Returns 0 (yes) or 1 (no/cancel).
_tui_confirm() {
  local prompt="${1:-Are you sure?}"
  if command -v gum &>/dev/null; then
    gum confirm "$prompt"
  else
    local _r
    read -rp "  ${prompt} [y/N] " _r
    [[ "${_r,,}" == "y" ]]
  fi
}

# _tui_input <prompt> [placeholder]
#   Prints the entered value on stdout.
_tui_input() {
  local prompt="$1" placeholder="${2:-}"
  if command -v gum &>/dev/null; then
    gum input --placeholder "${placeholder}" --prompt "${prompt}: "
  else
    local _r
    read -rp "  ${prompt}${placeholder:+ [${placeholder}]}: " _r
    echo "${_r:-${placeholder}}"
  fi
}

# _tui_choose <header> <option>...
#   Prints the selected option on stdout.
_tui_choose() {
  local header="$1"; shift
  if command -v gum &>/dev/null; then
    gum choose --header "$header" "$@"
  else
    local _i=1
    for _opt in "$@"; do
      printf "  [%d] %s\n" "$_i" "$_opt"
      ((_i++)) || true
    done
    local _r; read -rp "  Choice [1]: " _r
    _r="${_r:-1}"
    local _arr=("$@")
    echo "${_arr[$(( _r - 1 ))]:-}"
  fi
}

# _tui_filter [placeholder]
#   Reads lines from stdin; prints the selected line on stdout.
#   Falls back to fzf, then to a plain numbered list.
_tui_filter() {
  local placeholder="${1:-Type to filter...}"
  if command -v gum &>/dev/null; then
    gum filter --placeholder "$placeholder"
  elif command -v fzf &>/dev/null; then
    fzf --prompt "$placeholder "
  else
    local -a _items=()
    while IFS= read -r _line; do _items+=("$_line"); done
    local _i=1
    for _item in "${_items[@]}"; do
      printf "  [%d] %s\n" "$_i" "$_item"
      ((_i++)) || true
    done
    local _r; read -rp "  Choice: " _r
    echo "${_items[$(( _r - 1 ))]:-}"
  fi
}

# ── Signature matching ─────────────────────────────────────────────────────
# match_signatures <category_prefix> <text>
#   Prints any matching known-issue signatures with remediation steps.
#   Always returns 0 — informational only; callers own their FINDINGS counter.
match_signatures() {
  local category="$1"
  local text="$2"

  for sig_file in "$SIGNATURES_DIR"/${category}*.sig; do
    [[ -f "$sig_file" ]] || continue

    local name severity summary remediation
    name="$(        grep '^NAME='        "$sig_file" | cut -d= -f2-)"
    severity="$(    grep '^SEVERITY='    "$sig_file" | cut -d= -f2-)"
    summary="$(     grep '^SUMMARY='     "$sig_file" | cut -d= -f2-)"
    remediation="$( grep '^REMEDIATION=' "$sig_file" | cut -d= -f2-)"

    local hit=false
    while IFS= read -r pattern; do
      if echo "$text" | grep -qE "$pattern" 2>/dev/null; then
        hit=true; break
      fi
    done < <(grep '^PATTERN=' "$sig_file" | cut -d= -f2-)

    if $hit; then
      echo
      case "$severity" in
        critical) critical "KNOWN ISSUE → $name" ;;
        warning)  warn     "KNOWN ISSUE → $name" ;;
        *)        finding  "KNOWN ISSUE → $name" ;;
      esac
      echo -e "  ${BOLD}What:${RESET}   $summary"
      echo -e "  ${BOLD}Action:${RESET} $remediation"
    fi
  done

  return 0
}
