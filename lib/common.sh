#!/usr/bin/env bash
# Shared utilities for lol — source this, don't run directly

# ── Colors (disabled automatically when not a terminal) ───────────────────
if [[ -t 1 ]]; then
  RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
  RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; DIM=''; RESET=''
fi

# ── Paths ──────────────────────────────────────────────────────────────────
_LOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNATURES_DIR="$_LOL_ROOT/signatures"
LOL_CONTEXT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/lol/context"

# ── Output helpers ─────────────────────────────────────────────────────────
print_banner() {
  echo -e "${BOLD}${CYAN}"
  cat <<'BANNER'
  _         _
 | |       | |
 | |  ___  | |   Lots Of Logs inspector
 | | / _ \ | |   OpenShift must-gather edition
 | || (_) || |
 |_| \___/ |_|
BANNER
  echo -e "${RESET}"
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
# resolve_mg_path [optional-path]
#   Returns a must-gather path — from the argument if given, otherwise from the
#   stored context file. Exits non-zero with an error message on failure.
resolve_mg_path() {
  local path="${1:-}"

  if [[ -z "$path" ]]; then
    if [[ ! -f "$LOL_CONTEXT_FILE" ]]; then
      err "No must-gather set. Run: lol use <path>"
      return 1
    fi
    path="$(cat "$LOL_CONTEXT_FILE")"
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

# ── Signature matching ─────────────────────────────────────────────────────
# match_signatures <category_prefix> <text>
#   Scans signatures/<category_prefix>*.sig for any whose PATTERN lines match
#   <text>. Prints the matched issue name, summary, and remediation steps.
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
