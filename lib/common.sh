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
