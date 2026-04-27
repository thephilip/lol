#!/usr/bin/env bash
# lol — Lots Of Logs inspector for OpenShift must-gathers

set -euo pipefail

# Resolve the real script location, following any symlinks
_lol_src="${BASH_SOURCE[0]}"
while [[ -L "$_lol_src" ]]; do
  _lol_dir="$(cd "$(dirname "$_lol_src")" && pwd)"
  _lol_src="$(readlink "$_lol_src")"
  [[ "$_lol_src" != /* ]] && _lol_src="$_lol_dir/$_lol_src"
done
SCRIPT_DIR="$(cd "$(dirname "$_lol_src")" && pwd)"
unset _lol_src _lol_dir
source "$SCRIPT_DIR/lib/common.sh"

# Load user config before clankers so model/API overrides are in scope
_lol_cfg="${LOL_CONFIG_DIR}/config.env"
[[ -f "$_lol_cfg" ]] && source "$_lol_cfg"
unset _lol_cfg

source "$SCRIPT_DIR/lib/clankers.sh"

VERSION="0.1.0"
CHECKS_DIR="$SCRIPT_DIR/checks"

usage() {
  cat <<EOF
lol v$VERSION — must-gather inspector

Commands:
  use <path>              Set the active must-gather
  check [name,...]        Run checks (no args = all; comma-separated names for specific)
  cluster [-C <id>]       Show cluster summary; -C/--cluster sets cluster via OCM
  context <sub>           Manage named contexts (list / resume / show)
  ready-up                Generate an AI-ready handoff from the active context
  list                    List available checks
  status                  Show active session / context info
  upgrade                 Pull the latest version from origin/main
  version                 Show version, commit, and available releases

ocm commands (require ocm login; logged to ledger when in a named context):
  alerts [--all]          Show firing/pending alerts from the must-gather (--all for inactive too)
  service-log [--size N]  Recent service log entries (default: 20)
  limited-support         Check whether the cluster has limited support reasons

omc passthrough (context-aware; logged to ledger when in a named context):
  get <resource> [flags]  e.g. lol get pods -n openshift-etcd
  describe <resource>     e.g. lol describe node worker-1
  logs [flags] <pod>      e.g. lol logs -n openshift-etcd etcd-0
  top [nodes|pods]
  projects
  extract
  adm

Other:
  reset                   Remove all lol session data and return to factory state
  completion <shell>      Output shell completion script (supported: zsh)

Global flags:
  --context, -c <name>    Named context to create or use
  -h, --help              Show this help
  -v, --version           Show version

Options for check and omc passthrough:
  --no-log                Don't record this run to the context ledger

Options for check:
  --with-clankers "query" Run a local AI analysis against the must-gather
  --clankers-model <name> Model to use (default: gemma2:2b, env: LOL_CLANKERS_MODEL)
                          If no check names are given, AI analysis runs without
                          first running the standard checks.

Options for ready-up:
  --no-redact             Skip PII scrubbing (for internal/self-hosted AI only)
  -o, --output <file>     Write to file instead of stdout

Examples:
  # Anonymous session — no ledger, no persistence beyond the mg path
  lol use /path/to/must-gather
  lol check etcd
  lol get pods -n openshift-etcd

  # Named context — ledger kept, resumable, handoff-ready
  lol -c 04431153-GroupSync use /path/to/must-gather
  lol check etcd,nodes
  lol alerts
  lol get nodes
  lol ready-up -o handoff.md

  # Resume a context in a new session
  lol context resume 04431153-GroupSync
  lol check pdbs
  lol context list
EOF
}

# ── Context storage helpers ────────────────────────────────────────────────
ctx_dir()  { echo "$LOL_CONTEXTS_DIR/$1"; }
ctx_meta() { echo "$LOL_CONTEXTS_DIR/$1/meta.env"; }
ctx_runs() { echo "$LOL_CONTEXTS_DIR/$1/runs"; }
ctx_hist() { echo "$LOL_CONTEXTS_DIR/$1/mg-history.log"; }

ctx_exists() { [[ -f "$(ctx_meta "$1")" ]]; }

ctx_get() {
  local name="$1" key="$2"
  local meta; meta="$(ctx_meta "$name")"
  [[ -f "$meta" ]] && grep "^${key}=" "$meta" | cut -d= -f2- || echo ""
}

ctx_set() {
  local name="$1" key="$2" value="$3"
  local meta; meta="$(ctx_meta "$name")"
  mkdir -p "$(ctx_dir "$name")/runs"
  if [[ -f "$meta" ]] && grep -q "^${key}=" "$meta"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$meta"
  else
    echo "${key}=${value}" >> "$meta"
  fi
}

active_ctx() {
  [[ -f "$LOL_ACTIVE_CTX_FILE" ]] && cat "$LOL_ACTIVE_CTX_FILE" || echo ""
}

# resolve_cluster_id — external UUID of the active cluster
#   Priority: must-gather ClusterVersion → context CLUSTER_ID
resolve_cluster_id() {
  local cluster_id=""

  local mg_path
  if mg_path="$(resolve_mg_path 2>/dev/null)" && [[ -d "$mg_path" ]]; then
    if command omc use "$mg_path" &>/dev/null 2>&1; then
      cluster_id="$(omc get clusterversion version \
        -o jsonpath='{.spec.clusterID}' 2>/dev/null)" || cluster_id=""
    fi
  fi

  if [[ -z "$cluster_id" ]]; then
    local ctx; ctx="$(active_ctx)"
    [[ -n "$ctx" ]] && cluster_id="$(ctx_get "$ctx" "CLUSTER_ID")"
  fi

  if [[ -z "$cluster_id" ]]; then
    err "No cluster ID available."
    info "Tip: lol cluster --cluster <id>  — set a cluster via OCM (no must-gather needed)"
    info "     lol use <must-gather-path>  — set via must-gather"
    return 1
  fi

  echo "$cluster_id"
}

# resolve_ocm_id — OCM internal cluster ID from external UUID
#   Checks context cache first to avoid redundant API calls
resolve_ocm_id() {
  local cluster_id="$1"

  local ctx; ctx="$(active_ctx)"
  if [[ -n "$ctx" ]]; then
    local cached; cached="$(ctx_get "$ctx" "OCM_ID")"
    [[ -n "$cached" ]] && { echo "$cached"; return; }
  fi

  local ocm_id
  ocm_id="$(ocm get /api/clusters_mgmt/v1/clusters \
    --parameter "search=external_id='${cluster_id}'" \
    --parameter size=1 2>/dev/null | jq -r '.items[0].id // empty')"

  if [[ -z "$ocm_id" ]]; then
    err "Could not resolve OCM internal ID for cluster: $cluster_id"
    info "Ensure you are logged in: ocm whoami"
    return 1
  fi

  echo "$ocm_id"
}

# _cluster_find_ctx_by_id — returns the name of any saved context whose
#   CLUSTER_ID matches, excluding the currently active context
_cluster_find_ctx_by_id() {
  local target_id="$1"
  local cur_ctx; cur_ctx="$(active_ctx)"
  [[ ! -d "$LOL_CONTEXTS_DIR" ]] && return
  local dir
  for dir in "$LOL_CONTEXTS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name="$(basename "$dir")"
    [[ "$name" == "$cur_ctx" ]] && continue
    local stored; stored="$(ctx_get "$name" "CLUSTER_ID")"
    [[ "$stored" == "$target_id" ]] && { echo "$name"; return; }
  done
}

set_active_ctx() {
  mkdir -p "$LOL_CONFIG_DIR"
  echo "$1" > "$LOL_ACTIVE_CTX_FILE"
}

clear_active_ctx() { rm -f "$LOL_ACTIVE_CTX_FILE"; }

# ── cmd: use ──────────────────────────────────────────────────────────────
cmd_use() {
  local path="${1:-}"
  [[ -z "$path" ]] && { err "Usage: lol use <must-gather-path>"; exit 1; }
  [[ ! -d "$path" ]] && { err "Not a directory: $path"; exit 1; }

  path="$(realpath "$path")"
  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
  mkdir -p "$LOL_CONFIG_DIR"

  if [[ -n "$LOL_CTX_NAME" ]]; then
    local is_new=false
    ctx_exists "$LOL_CTX_NAME" || is_new=true

    ctx_set "$LOL_CTX_NAME" "NAME"       "$LOL_CTX_NAME"
    ctx_set "$LOL_CTX_NAME" "CURRENT_MG" "$path"
    ctx_set "$LOL_CTX_NAME" "UPDATED"    "$ts"
    $is_new && ctx_set "$LOL_CTX_NAME" "CREATED" "$ts"

    # Append to mg history
    echo "${ts} ${path}" >> "$(ctx_hist "$LOL_CTX_NAME")"

    set_active_ctx "$LOL_CTX_NAME"
    echo "$path" > "$LOL_CONTEXT_FILE"

    $is_new && ok "Context created: $LOL_CTX_NAME" || ok "Context updated: $LOL_CTX_NAME"
  else
    # Anonymous session — explicitly clear any active named context
    clear_active_ctx
    echo "$path" > "$LOL_CONTEXT_FILE"
    ok "Anonymous session — no ledger will be kept"
  fi

  ok "Active must-gather: $path"
}

# ── cmd: status ───────────────────────────────────────────────────────────
cmd_status() {
  local ctx; ctx="$(active_ctx)"

  if [[ -n "$ctx" ]]; then
    header "Named context: $ctx"
    echo -e "  ${BOLD}Created:${RESET}      $(ctx_get "$ctx" "CREATED")"
    echo -e "  ${BOLD}Last updated:${RESET} $(ctx_get "$ctx" "UPDATED")"

    local mg; mg="$(ctx_get "$ctx" "CURRENT_MG")"
    if [[ -d "$mg" ]]; then
      echo -e "  ${BOLD}Must-gather:${RESET}  $mg"
    elif [[ -n "$mg" ]]; then
      warn "  Must-gather path missing: $mg"
    fi

    local cid; cid="$(ctx_get "$ctx" "CLUSTER_ID")"
    [[ -n "$cid" ]] && echo -e "  ${BOLD}Cluster ID:${RESET}   $cid"

    local mg_count=0 run_count=0
    [[ -f "$(ctx_hist "$ctx")" ]] && mg_count="$(wc -l < "$(ctx_hist "$ctx")" | tr -d ' ')"
    [[ -d "$(ctx_runs "$ctx")" ]] && run_count="$(find "$(ctx_runs "$ctx")" -maxdepth 1 -name '*.txt' | wc -l | tr -d ' ')"
    echo -e "  ${BOLD}Must-gathers:${RESET} $mg_count total"
    echo -e "  ${BOLD}Runs logged:${RESET}  $run_count"
  else
    header "Anonymous session"
    if [[ -f "$LOL_CONTEXT_FILE" ]]; then
      local path; path="$(cat "$LOL_CONTEXT_FILE")"
      [[ -d "$path" ]] && echo -e "  ${BOLD}Must-gather:${RESET} $path" \
                       || warn "Must-gather path missing: $path"
    else
      info "No must-gather set. Run: lol use <path>"
    fi
  fi
}

# ── cmd: list ─────────────────────────────────────────────────────────────
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

# ── cmd: context ──────────────────────────────────────────────────────────
cmd_context_list() {
  if [[ ! -d "$LOL_CONTEXTS_DIR" ]] || [[ -z "$(ls -A "$LOL_CONTEXTS_DIR" 2>/dev/null)" ]]; then
    info "No saved contexts. Create one with: lol --context=<name> use <path>"
    return
  fi

  local cur_ctx; cur_ctx="$(active_ctx)"
  echo
  header "Saved contexts:"

  for dir in "$LOL_CONTEXTS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name; name="$(basename "$dir")"
    local updated mg run_count mg_count
    updated="$(ctx_get   "$name" "UPDATED")"
    mg="$(ctx_get        "$name" "CURRENT_MG")"
    run_count=0; mg_count=0
    [[ -d "$dir/runs" ]] && run_count="$(find "$dir/runs" -maxdepth 1 -name '*.txt' | wc -l | tr -d ' ')"
    [[ -f "$(ctx_hist "$name")" ]] && mg_count="$(wc -l < "$(ctx_hist "$name")" | tr -d ' ')"

    local active_marker=""
    [[ "$name" == "$cur_ctx" ]] && active_marker=" ${CYAN}← active${RESET}"

    printf "  ${BOLD}%-38s${RESET} updated:%-22s  runs:%-3s  mgs:%-2s%b\n" \
      "$name" "${updated:-unknown}" "$run_count" "$mg_count" "$active_marker"
  done
  echo
}

cmd_context_resume() {
  local name="${1:-}"
  [[ -z "$name" ]] && { err "Usage: lol context resume <name>"; exit 1; }
  ctx_exists "$name" || { err "Context not found: $name"; info "Run: lol context list"; exit 1; }

  local mg; mg="$(ctx_get "$name" "CURRENT_MG")"
  set_active_ctx "$name"
  mkdir -p "$LOL_CONFIG_DIR"
  echo "$mg" > "$LOL_CONTEXT_FILE"

  ok "Resumed context: $name"
  [[ -d "$mg" ]] && ok "Active must-gather: $mg" || warn "Must-gather path missing: $mg"
}

cmd_context_show() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    name="$(active_ctx)"
    [[ -z "$name" ]] && { err "No active context. Pass a name or run: lol context resume <name>"; exit 1; }
  fi
  ctx_exists "$name" || { err "Context not found: $name"; exit 1; }

  header "Context: $name"
  echo -e "  ${BOLD}Created:${RESET}  $(ctx_get "$name" "CREATED")"
  echo -e "  ${BOLD}Updated:${RESET}  $(ctx_get "$name" "UPDATED")"
  echo

  local hist; hist="$(ctx_hist "$name")"
  if [[ -f "$hist" ]]; then
    header "Must-gather history:"
    local i=0
    while IFS= read -r line; do
      ((i++)) || true
      local ts_entry path_entry
      ts_entry="$(echo "$line" | cut -d' ' -f1)"
      path_entry="$(echo "$line" | cut -d' ' -f2-)"
      local cur_mg; cur_mg="$(ctx_get "$name" "CURRENT_MG")"
      local marker=""; [[ "$path_entry" == "$cur_mg" ]] && marker=" ${CYAN}← current${RESET}"
      printf "  %2d. %s  %b%b\n" "$i" "$ts_entry" "$path_entry" "$marker"
    done < "$hist"
    echo
  fi

  local runs_dir; runs_dir="$(ctx_runs "$name")"
  if [[ -d "$runs_dir" ]] && compgen -G "$runs_dir/*.txt" &>/dev/null; then
    header "Inspection runs:"
    for f in "$runs_dir"/*.txt; do
      [[ -f "$f" ]] || continue
      echo "  $(basename "$f" .txt)"
    done
    echo
  fi
}

cmd_context() {
  local subcmd="${1:-list}"; shift || true
  case "$subcmd" in
    list)   cmd_context_list ;;
    resume) cmd_context_resume "$@" ;;
    show)   cmd_context_show "$@" ;;
    *) err "Unknown context subcommand: '$subcmd'"; usage; exit 1 ;;
  esac
}

# ── cmd: check ────────────────────────────────────────────────────────────
get_all_check_names() {
  local names=()
  for f in "$CHECKS_DIR"/*.sh; do
    [[ -f "$f" ]] || continue
    names+=("$(basename "$f" .sh)")
  done
  echo "${names[@]}"
}

run_checks() {
  local mg_path="$1" log_file="$2"; shift 2
  local -a check_names=("$@")
  local findings=0 errors=0

  print_banner

  local ctx; ctx="$(active_ctx)"
  [[ -n "$ctx" ]] && info "Context:     $ctx" || info "Session:     anonymous (no ledger)"
  info "Must-gather: $mg_path"
  info "Checks:      ${check_names[*]}"
  echo

  if ! command -v omc &>/dev/null; then
    err "'omc' not found in PATH — required for must-gather inspection"
    exit 2
  fi

  [[ -n "$log_file" ]] && printf '# lol check run\n# mg: %s\n# checks: %s\n\n' \
    "$mg_path" "${check_names[*]}" > "$log_file"

  for name in "${check_names[@]}"; do
    local check_file="$CHECKS_DIR/${name}.sh"
    if [[ ! -f "$check_file" ]]; then
      err "Unknown check: '$name'"
      ((errors++)) || true
      continue
    fi

    section "CHECK: $name"
    local rc=0

    if [[ -n "$log_file" ]]; then
      # Capture output to temp file; display with colors, log without ANSI codes
      local tmp_out; tmp_out="$(mktemp)"
      LOL_FORCE_COLOR=1 bash "$check_file" "$mg_path" > "$tmp_out" 2>&1 || rc=$?
      cat "$tmp_out"
      { printf '\n--- CHECK: %s ---\n\n' "$name"
        sed 's/\x1b\[[0-9;]*[mK]//g' "$tmp_out"
        echo
      } >> "$log_file"
      rm -f "$tmp_out"
    else
      bash "$check_file" "$mg_path" || rc=$?
    fi

    echo

    if   [[ $rc -eq 1 ]]; then ((findings++)) || true
    elif [[ $rc -ge 2 ]]; then ((errors++))   || true
    fi
  done

  section "SUMMARY"
  local summary_text
  if [[ $findings -eq 0 && $errors -eq 0 ]]; then
    summary_text="All ${#check_names[@]} check(s) passed — no issues found"
    ok "$summary_text"
  else
    [[ $findings -gt 0 ]] && { summary_text="$findings check(s) reported findings"; warn "$summary_text"; }
    [[ $errors   -gt 0 ]] && { summary_text="${summary_text:+$summary_text, }$errors check(s) errored"; err  "$summary_text"; }
  fi
  echo

  [[ -n "$log_file" ]] && printf '\n--- SUMMARY ---\n%s\n' "$summary_text" >> "$log_file"
}

cmd_check() {
  local -a check_names=()
  local no_log=false
  local clankers_query=""
  local clankers_model="$LOL_CLANKERS_MODEL"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-log)          no_log=true; shift ;;
      --with-clankers)   clankers_query="$2"; shift 2 ;;
      --clankers-model)  clankers_model="$2"; shift 2 ;;
      -*)                err "Unknown option: $1"; usage; exit 1 ;;
      *)                 IFS=',' read -ra _names <<< "$1"; check_names+=("${_names[@]}"); shift ;;
    esac
  done

  local mg_path; mg_path="$(resolve_mg_path)" || exit 1

  # --with-clankers with no explicit check names → AI-only, skip standard checks
  local run_standard=true
  if [[ -n "$clankers_query" && ${#check_names[@]} -eq 0 ]]; then
    run_standard=false
  fi

  if $run_standard && [[ ${#check_names[@]} -eq 0 ]]; then
    read -ra check_names <<< "$(get_all_check_names)"
  fi

  if $run_standard; then
    [[ ${#check_names[@]} -eq 0 ]] && { err "No checks found in $CHECKS_DIR"; exit 1; }

    local log_file=""
    if ! $no_log; then
      local ctx; ctx="$(active_ctx)"
      if [[ -n "$ctx" ]]; then
        local runs_dir ts checks_slug
        runs_dir="$(ctx_runs "$ctx")"
        mkdir -p "$runs_dir"
        ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
        checks_slug="$(IFS=+; echo "${check_names[*]}")"
        log_file="$runs_dir/${ts}-${checks_slug}.txt"
        ctx_set "$ctx" "UPDATED" "$ts"
      fi
    fi

    run_checks "$mg_path" "$log_file" "${check_names[@]}"
    [[ -n "$log_file" ]] && info "Run saved: $log_file"
  else
    print_banner
  fi

  # Run AI analysis if requested
  if [[ -n "$clankers_query" ]]; then
    clankers_run "$clankers_query" "$mg_path" "$clankers_model"
  fi
}

# ── cmd: ready-up ─────────────────────────────────────────────────────────
cmd_ready_up() {
  local no_redact=false out_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-redact)       no_redact=true; shift ;;
      -o|--output)       out_file="$2"; shift 2 ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  local ctx; ctx="$(active_ctx)"
  if [[ -z "$ctx" ]]; then
    err "ready-up requires a named context — no active context found."
    info "Run: lol context resume <name>"
    exit 1
  fi

  local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
  local -a lines=()

  emit() { lines+=("$1"); }

  emit "# Case Handoff: ${ctx}"
  emit ""
  if ! $no_redact; then
    emit "> ⚠️  PII scrubbing applied (IPs, UUIDs, emails, cluster URLs)."
    emit "> **Review this document before sharing with any external service.**"
    emit ""
  fi
  emit "> Generated by lol v${VERSION} at ${ts}"
  emit ""
  emit "## Context"
  emit ""
  emit "- **Case/Context:** \`${ctx}\`"
  emit "- **Created:**      $(ctx_get "$ctx" "CREATED")"
  emit "- **Last updated:** $(ctx_get "$ctx" "UPDATED")"
  emit ""

  local hist; hist="$(ctx_hist "$ctx")"
  if [[ -f "$hist" ]]; then
    emit "### Must-gathers analyzed"
    emit ""
    while IFS= read -r line; do
      local ts_entry path_entry
      ts_entry="$(echo "$line" | cut -d' ' -f1)"
      path_entry="$(echo "$line" | cut -d' ' -f2-)"
      if $no_redact; then
        emit "- \`${path_entry}\` — ${ts_entry}"
      else
        emit "- \`[REDACTED:path]\` — ${ts_entry}"
      fi
    done < "$hist"
    emit ""
  fi

  # Investigation timeline — one section per run log
  local runs_dir; runs_dir="$(ctx_runs "$ctx")"
  if [[ -d "$runs_dir" ]] && compgen -G "$runs_dir/*.txt" &>/dev/null; then
    emit "## Investigation Timeline"
    emit ""
    for f in "$runs_dir"/*.txt; do
      [[ -f "$f" ]] || continue
      emit "### $(basename "$f" .txt)"
      emit ""
      emit '```'
      local content; content="$(cat "$f")"
      $no_redact && emit "$content" || emit "$(scrub_pii "$content")"
      emit '```'
      emit ""
    done

    # Aggregate findings across all runs
    emit "## Findings Summary"
    emit ""
    local all_findings
    all_findings="$(grep -h -E '\[(FINDING|CRITICAL|WARN)\]' "$runs_dir"/*.txt 2>/dev/null \
      | sed 's/\x1b\[[0-9;]*[mK]//g' | sort -u)" || all_findings=""

    if [[ -n "$all_findings" ]]; then
      $no_redact && emit "$all_findings" || emit "$(scrub_pii "$all_findings")"
    else
      emit "_No findings recorded in run logs._"
    fi
    emit ""
  fi

  # Ad-hoc omc commands run during the investigation
  local cmd_log; cmd_log="$(ctx_dir "$ctx")/commands.log"
  if [[ -f "$cmd_log" ]]; then
    emit "## Ad-hoc Commands"
    emit ""
    emit '```'
    local cmd_content; cmd_content="$(cat "$cmd_log")"
    $no_redact && emit "$cmd_content" || emit "$(scrub_pii "$cmd_content")"
    emit '```'
    emit ""
  fi

  emit "## Open Questions"
  emit ""
  emit "_What still needs investigation:_"
  emit ""
  emit "-"
  emit ""
  emit "## Suggested Next Steps"
  emit ""
  emit "_Describe what to investigate next, or ask the AI to suggest based on findings above._"
  emit ""

  local doc
  doc="$(printf '%s\n' "${lines[@]}")"

  if [[ -n "$out_file" ]]; then
    printf '%s\n' "$doc" > "$out_file"
    ok "Handoff written to: $out_file"
    ! $no_redact && warn "Review for any remaining sensitive data before sharing."
  else
    printf '%s\n' "$doc"
    ! $no_redact && echo && warn "Review for any remaining sensitive data before sharing." >&2
  fi
}

# ── OCM cluster helpers ────────────────────────────────────────────────────

# _ocm_lookup_cluster <id-or-name>
#   Accepts: external UUID, OCM internal ID, or cluster name.
#   Prints the cluster JSON object on success; returns 1 if not found.
_ocm_lookup_cluster() {
  local input="$1"
  local json=""

  if [[ "$input" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    json="$(ocm get /api/clusters_mgmt/v1/clusters \
      --parameter "search=external_id='${input}'" \
      --parameter size=1 2>/dev/null | jq -r '.items[0] // empty')"
  fi

  if [[ -z "$json" || "$json" == "null" ]]; then
    local direct
    direct="$(ocm get "/api/clusters_mgmt/v1/clusters/${input}" 2>/dev/null)"
    if [[ -n "$direct" ]] && ! echo "$direct" | jq -e '.kind == "Error"' &>/dev/null; then
      json="$direct"
    fi
  fi

  if [[ -z "$json" || "$json" == "null" ]]; then
    json="$(ocm get /api/clusters_mgmt/v1/clusters \
      --parameter "search=name='${input}'" \
      --parameter size=1 2>/dev/null | jq -r '.items[0] // empty')"
  fi

  [[ -z "$json" || "$json" == "null" ]] && return 1
  echo "$json"
}

# _cluster_display_ocm <cluster-json>
#   Polished cluster summary from OCM data, with coloured state indicator.
_cluster_display_ocm() {
  local json="$1"

  local name external_id ocm_id version state product
  local platform region multi_az api_url console_url
  local master_nodes infra_nodes compute_nodes created_at

  name="$(         echo "$json" | jq -r '.name                          // "unknown"')"
  external_id="$(  echo "$json" | jq -r '.external_id                   // "unknown"')"
  ocm_id="$(       echo "$json" | jq -r '.id                            // "unknown"')"
  version="$(      echo "$json" | jq -r '.openshift_version             // "unknown"')"
  state="$(        echo "$json" | jq -r '.status.state                  // "unknown"')"
  product="$(      echo "$json" | jq -r '.product.id                    // "unknown"')"
  platform="$(     echo "$json" | jq -r '.cloud_provider.id             // "unknown"' | tr '[:lower:]' '[:upper:]')"
  region="$(       echo "$json" | jq -r '.region.id                     // "unknown"')"
  multi_az="$(     echo "$json" | jq -r '.multi_az                      // false')"
  api_url="$(      echo "$json" | jq -r '.api.url                       // "unknown"')"
  console_url="$(  echo "$json" | jq -r '.console.url                   // "unknown"')"
  master_nodes="$( echo "$json" | jq -r '.nodes.master                  // "unknown"')"
  infra_nodes="$(  echo "$json" | jq -r '.nodes.infra                   // "unknown"')"
  compute_nodes="$(echo "$json" | jq -r '.nodes.compute                 // "unknown"')"
  created_at="$(   echo "$json" | jq -r '.creation_timestamp[0:19]      // "unknown"')"

  local state_str
  case "$state" in
    ready)                        state_str="${GREEN}${state}${RESET}" ;;
    installing|updating|pending*) state_str="${YELLOW}${state}${RESET}" ;;
    error|uninstalling|degraded)  state_str="${RED}${state}${RESET}" ;;
    *)                            state_str="${DIM}${state}${RESET}" ;;
  esac

  section "Cluster: $name"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Name:"         "$name"
  printf "  ${BOLD}%-20s${RESET} %s\n" "External ID:"  "$external_id"
  printf "  ${BOLD}%-20s${RESET} %s\n" "OCM ID:"       "$ocm_id"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "Version:"      "$version"
  printf "  ${BOLD}%-20s${RESET} $(echo -e "${state_str}")\n" "State:"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Product:"      "$(echo "$product" | tr '[:lower:]' '[:upper:]')"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "Platform:"     "$platform"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Region:"       "$region"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Multi-AZ:"     "$multi_az"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "API URL:"      "$api_url"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Console:"      "$console_url"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "Master nodes:"  "$master_nodes"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Infra nodes:"   "$infra_nodes"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Compute nodes:" "$compute_nodes"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "Created:"      "$created_at"
  echo
}

# _cluster_set <id-or-name>
#   Full interactive flow for lol cluster --cluster <id>
_cluster_set() {
  local input_id="$1"

  if ! command -v ocm &>/dev/null; then
    err "'ocm' not found in PATH — required for lol cluster --cluster"
    exit 2
  fi
  if ! command -v jq &>/dev/null; then
    err "'jq' not found in PATH — required for lol cluster --cluster"
    exit 2
  fi

  info "Looking up cluster in OCM: $input_id"
  local cluster_json
  cluster_json="$(_ocm_lookup_cluster "$input_id")" || {
    err "Cluster not found in OCM: $input_id"
    info "Try: external UUID, OCM internal ID, or cluster name"
    exit 1
  }

  local external_id ocm_id cluster_name
  external_id="$(  echo "$cluster_json" | jq -r '.external_id // empty')"
  ocm_id="$(       echo "$cluster_json" | jq -r '.id          // empty')"
  cluster_name="$( echo "$cluster_json" | jq -r '.name        // empty')"

  local cur_ctx; cur_ctx="$(active_ctx)"
  local cur_cluster_id=""
  [[ -n "$cur_ctx" ]] && cur_cluster_id="$(ctx_get "$cur_ctx" "CLUSTER_ID")"

  # ── CASE 1: already tracking this cluster in the active context ────────
  if [[ -n "$cur_cluster_id" && "$cur_cluster_id" == "$external_id" ]]; then
    ok "Context '$cur_ctx' already tracks this cluster."
    echo
    _cluster_display_ocm "$cluster_json"
    return
  fi

  # ── CASE 2: another saved context already tracks this cluster ──────────
  local matching_ctx
  matching_ctx="$(_cluster_find_ctx_by_id "$external_id")"

  if [[ -n "$matching_ctx" ]]; then
    echo
    info "Context '${matching_ctx}' already tracks this cluster."
    read -rp "  Resume '${matching_ctx}'? [Y/n] " resp
    if [[ "${resp,,}" != "n" ]]; then
      local mg; mg="$(ctx_get "$matching_ctx" "CURRENT_MG")"
      set_active_ctx "$matching_ctx"
      mkdir -p "$LOL_CONFIG_DIR"
      echo "$mg" > "$LOL_CONTEXT_FILE"
      ok "Resumed context: $matching_ctx"
      echo
      _cluster_display_ocm "$cluster_json"
      return
    fi
    echo
  fi

  # ── CASE 3: active context exists but has no cluster ID yet ────────────
  if [[ -n "$cur_ctx" && -z "$cur_cluster_id" ]]; then
    echo
    info "Active context '${cur_ctx}' has no cluster set."
    echo "  [1] Associate this cluster with '${cur_ctx}'"
    echo "  [2] Create a new context for ${cluster_name}"
    echo "  [3] Show info without saving"
    echo
    read -rp "  Choice [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
      3)
        info "Showing cluster info — not saved to context"
        echo
        _cluster_display_ocm "$cluster_json"
        return
        ;;
      2)
        echo
        read -rp "  Context name [${cluster_name}]: " ctx_input
        ctx_input="${ctx_input:-$cluster_name}"
        local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
        ctx_set "$ctx_input" "NAME"       "$ctx_input"
        ctx_set "$ctx_input" "CLUSTER_ID" "$external_id"
        ctx_set "$ctx_input" "OCM_ID"     "$ocm_id"
        ctx_set "$ctx_input" "CREATED"    "$ts"
        ctx_set "$ctx_input" "UPDATED"    "$ts"
        set_active_ctx "$ctx_input"
        ok "Created and activated context: $ctx_input"
        echo
        _cluster_display_ocm "$cluster_json"
        return
        ;;
      *)
        local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
        ctx_set "$cur_ctx" "CLUSTER_ID" "$external_id"
        ctx_set "$cur_ctx" "OCM_ID"     "$ocm_id"
        ctx_set "$cur_ctx" "UPDATED"    "$ts"
        ok "Cluster associated with context '${cur_ctx}'"
        echo
        _cluster_display_ocm "$cluster_json"
        return
        ;;
    esac
  fi

  # ── CASE 4: no active context — must create one ────────────────────────
  if [[ -z "$cur_ctx" ]]; then
    echo
    read -rp "  Context name [${cluster_name}]: " ctx_input
    ctx_input="${ctx_input:-$cluster_name}"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
    ctx_set "$ctx_input" "NAME"       "$ctx_input"
    ctx_set "$ctx_input" "CLUSTER_ID" "$external_id"
    ctx_set "$ctx_input" "OCM_ID"     "$ocm_id"
    ctx_set "$ctx_input" "CREATED"    "$ts"
    ctx_set "$ctx_input" "UPDATED"    "$ts"
    set_active_ctx "$ctx_input"
    ok "Created and activated context: $ctx_input"
    echo
    _cluster_display_ocm "$cluster_json"
    return
  fi

  # ── CASE 5: active context tracks a different cluster — offer options ──
  echo
  warn "Context '${cur_ctx}' tracks a different cluster (${cur_cluster_id})."
  echo
  echo "  [1] Create a new context for ${cluster_name}"
  echo "  [2] Show info in current context (no changes saved)"
  echo
  read -rp "  Choice [1]: " choice
  choice="${choice:-1}"

  case "$choice" in
    2)
      info "Showing cluster info — not saved to context"
      echo
      _cluster_display_ocm "$cluster_json"
      ;;
    *)
      echo
      read -rp "  Context name [${cluster_name}]: " ctx_input
      ctx_input="${ctx_input:-$cluster_name}"
      local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
      ctx_set "$ctx_input" "NAME"       "$ctx_input"
      ctx_set "$ctx_input" "CLUSTER_ID" "$external_id"
      ctx_set "$ctx_input" "OCM_ID"     "$ocm_id"
      ctx_set "$ctx_input" "CREATED"    "$ts"
      ctx_set "$ctx_input" "UPDATED"    "$ts"
      set_active_ctx "$ctx_input"
      ok "Created and activated context: $ctx_input"
      echo
      _cluster_display_ocm "$cluster_json"
      ;;
  esac
}

# ── cmd: cluster ──────────────────────────────────────────────────────────
cmd_cluster() {
  local set_cluster=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cluster|-C) set_cluster="$2"; shift 2 ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  # ── --cluster flag: interactive OCM set flow ───────────────────────────
  if [[ -n "$set_cluster" ]]; then
    _cluster_set "$set_cluster"
    return
  fi

  # ── No must-gather: fall back to OCM via stored CLUSTER_ID ────────────
  if ! resolve_mg_path &>/dev/null 2>&1; then
    if ! command -v ocm &>/dev/null; then
      err "No must-gather set and 'ocm' not found in PATH."
      info "Tip: lol use <must-gather-path>"
      info "     lol cluster --cluster <id>  — query via OCM (requires ocm login)"
      exit 1
    fi
    local cluster_id
    cluster_id="$(resolve_cluster_id)" || exit 1
    local ocm_id
    ocm_id="$(resolve_ocm_id "$cluster_id")" || exit 1
    local cluster_json
    cluster_json="$(ocm get "/api/clusters_mgmt/v1/clusters/${ocm_id}" 2>/dev/null)" || {
      err "Failed to fetch cluster info from OCM"
      exit 1
    }
    _cluster_display_ocm "$cluster_json"
    info "Tip: lol cluster --cluster <id>  — switch clusters or query without a must-gather"
    return
  fi

  if ! command -v omc &>/dev/null; then
    err "'omc' not found in PATH"
    exit 2
  fi

  local mg_path
  mg_path="$(resolve_mg_path)" || exit 1
  omc_use "$mg_path" || exit 2

  # ── ClusterVersion ────────────────────────────────────────────────────
  local cv_json
  cv_json="$(omc get clusterversion version -o json 2>/dev/null)" || cv_json="{}"

  local cluster_id version channel phase
  cluster_id="$(echo "$cv_json" | jq -r '.spec.clusterID     // "unknown"')"
  version="$(   echo "$cv_json" | jq -r '.status.history[0].version // .status.desired.version // "unknown"')"
  channel="$(   echo "$cv_json" | jq -r '.spec.channel        // "unknown"')"
  phase="$(     echo "$cv_json" | jq -r '.status.history[0].state   // "unknown"')"

  # ── Infrastructure ────────────────────────────────────────────────────
  local infra_json
  infra_json="$(omc get infrastructure cluster -o json 2>/dev/null)" || infra_json="{}"

  local platform infra_name api_url region
  platform="$(   echo "$infra_json" | jq -r '.status.platformStatus.type // "unknown"')"
  infra_name="$( echo "$infra_json" | jq -r '.status.infrastructureName  // "unknown"')"
  api_url="$(    echo "$infra_json" | jq -r '.status.apiServerURL         // "unknown"')"

  region="$(echo "$infra_json" | jq -r '
    .status.platformStatus |
    (
      .aws.region   //
      .gcp.region   //
      .azure.cloudName //
      "n/a"
    )')"

  # ── Console ───────────────────────────────────────────────────────────
  local console_url
  console_url="$(omc get console cluster -o jsonpath='{.status.consoleURL}' 2>/dev/null)" \
    || console_url="unknown"

  # ── Network ───────────────────────────────────────────────────────────
  local net_json network_type cluster_network service_network
  net_json="$(omc get network cluster -o json 2>/dev/null)" || net_json="{}"
  network_type="$(    echo "$net_json" | jq -r '.spec.networkType      // "unknown"')"
  cluster_network="$( echo "$net_json" | jq -r '.spec.clusterNetwork[0].cidr // "unknown"')"
  service_network="$( echo "$net_json" | jq -r '.spec.serviceNetwork[0]      // "unknown"')"

  # ── Output ────────────────────────────────────────────────────────────
  section "Cluster Summary"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Cluster ID:"    "$cluster_id"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Version:"       "$version ($phase)"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Channel:"       "$channel"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "Platform:"      "$platform"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Region:"        "$region"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Infra name:"    "$infra_name"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "API URL:"       "$api_url"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Console:"       "$console_url"
  echo
  printf "  ${BOLD}%-20s${RESET} %s\n" "Network type:"  "$network_type"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Cluster CIDR:"  "$cluster_network"
  printf "  ${BOLD}%-20s${RESET} %s\n" "Service CIDR:"  "$service_network"
  echo
  info "Tip: lol cluster --cluster <id>  — switch clusters or query without a must-gather"
}

# ── cmd: upgrade ──────────────────────────────────────────────────────────
cmd_upgrade() {
  if ! command -v git &>/dev/null; then
    err "git not found in PATH — cannot self-upgrade"
    exit 1
  fi

  local remote="origin"
  local branch="main"

  # Confirm this is a git repo with a remote
  if ! git -C "$SCRIPT_DIR" remote get-url "$remote" &>/dev/null; then
    err "No '$remote' remote found. Is this a git clone?"
    exit 1
  fi

  # Warn if there are local modifications
  if ! git -C "$SCRIPT_DIR" diff --quiet || ! git -C "$SCRIPT_DIR" diff --cached --quiet; then
    warn "You have local modifications — upgrade may conflict."
    read -rp "Continue anyway? [y/N] " confirm
    [[ "${confirm,,}" == "y" ]] || { info "Upgrade cancelled."; exit 0; }
  fi

  local before
  before="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD)"

  info "Fetching from $remote/$branch ..."
  git -C "$SCRIPT_DIR" fetch "$remote" "$branch" --quiet

  local after
  after="$(git -C "$SCRIPT_DIR" rev-parse --short "$remote/$branch")"

  if [[ "$before" == "$after" ]]; then
    ok "Already up to date ($before)"
    return
  fi

  info "Updating $before → $after"
  git -C "$SCRIPT_DIR" merge --ff-only "$remote/$branch" --quiet

  ok "Upgraded to $after"
  echo
  info "Changes:"
  git -C "$SCRIPT_DIR" log --oneline "${before}..HEAD"
}

# ── omc passthrough ───────────────────────────────────────────────────────
# Ensures omc context matches lol's active must-gather, then delegates.
# When a named context is active, the command + output are appended to
# commands.log inside the context directory for later reference / ready-up.
cmd_omc_passthrough() {
  local subcmd="$1"; shift

  if ! command -v omc &>/dev/null; then
    err "'omc' not found in PATH"
    exit 2
  fi

  # Strip --no-log from args before handing the rest to omc
  local no_log=false
  local -a omc_args=()
  for arg in "$@"; do
    [[ "$arg" == "--no-log" ]] && no_log=true || omc_args+=("$arg")
  done

  local mg_path
  mg_path="$(resolve_mg_path)" || exit 1
  omc_use "$mg_path" || exit 2

  local ctx; ctx="$(active_ctx)"
  local rc=0

  if ! $no_log && [[ -n "$ctx" ]]; then
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
    local cmd_log; cmd_log="$(ctx_dir "$ctx")/commands.log"
    local tmp_out; tmp_out="$(mktemp)"

    omc "$subcmd" "${omc_args[@]}" >"$tmp_out" 2>&1 || rc=$?
    cat "$tmp_out"

    {
      printf '[%s] $ omc %s %s\n' "$ts" "$subcmd" "${omc_args[*]:-}"
      sed 's/\x1b\[[0-9;]*[mK]//g' "$tmp_out"
      printf '\n'
    } >> "$cmd_log"

    rm -f "$tmp_out"
  else
    omc "$subcmd" "${omc_args[@]}" || rc=$?
  fi

  return $rc
}

# cmd: alerts — show firing/pending alerts from the active must-gather
# Uses omc prometheus alertrule, which reads monitoring/alerts.json or
# monitoring/prometheus/rules.json from the must-gather snapshot.
# Pass --all to include inactive alerts. Extra args are forwarded to omc.
cmd_alerts() {
  local no_log=false all=false
  local -a extra_args=()
  for arg in "$@"; do
    case "$arg" in
      --no-log) no_log=true ;;
      --all)    all=true ;;
      *)        extra_args+=("$arg") ;;
    esac
  done

  local mg_path
  if ! mg_path="$(resolve_mg_path 2>/dev/null)" || [[ ! -d "$mg_path" ]]; then
    err "lol alerts requires an active must-gather."
    info "Tip: lol use <must-gather-path>  — load a must-gather to view alerts"
    info "     lol service-log              — view Red Hat service log entries via OCM"
    exit 1
  fi

  if ! command -v omc &>/dev/null; then
    err "'omc' not found in PATH"
    exit 2
  fi

  omc_use "$mg_path" || exit 2

  local -a omc_cmd=(omc prometheus alertrule)
  $all || omc_cmd+=(-s firing,pending)
  [[ ${#extra_args[@]} -gt 0 ]] && omc_cmd+=("${extra_args[@]}")

  local ctx; ctx="$(active_ctx)"
  local rc=0

  if ! $no_log && [[ -n "$ctx" ]]; then
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
    local cmd_log; cmd_log="$(ctx_dir "$ctx")/commands.log"
    local tmp_out; tmp_out="$(mktemp)"

    "${omc_cmd[@]}" >"$tmp_out" 2>&1 || rc=$?
    cat "$tmp_out"

    {
      printf '[%s] $ %s\n' "$ts" "${omc_cmd[*]}"
      sed 's/\x1b\[[0-9;]*[mK]//g' "$tmp_out"
      printf '\n'
    } >> "$cmd_log"

    rm -f "$tmp_out"
  else
    "${omc_cmd[@]}" || rc=$?
  fi

  return $rc
}

# ── cmd: service-log ─────────────────────────────────────────────────────
cmd_service_log() {
  if ! command -v ocm &>/dev/null; then
    err "'ocm' not found in PATH — required for lol service-log"
    exit 2
  fi

  local cluster_id
  cluster_id="$(resolve_cluster_id)" || exit 1

  local no_log=false size=20
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-log) no_log=true; shift ;;
      --size)   size="$2"; shift 2 ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  local ctx; ctx="$(active_ctx)"
  local rc=0
  local tmp_out; tmp_out="$(mktemp)"

  section "Service Log: $cluster_id"

  ocm get /api/service_logs/v1/cluster_logs \
    --parameter "search=cluster_uuid='${cluster_id}'" \
    --parameter "orderBy=timestamp desc" \
    --parameter "size=${size}" >"$tmp_out" 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] && command -v jq &>/dev/null; then
    local total; total="$(jq -r '.total // 0' "$tmp_out")"
    info "Showing ${size} of ${total} total entries (newest first)"
    echo
    jq -r '.items[]? |
      "[\(.timestamp[0:19])] [\(.severity)] \(.service_name)\n  \(.summary)\n"' "$tmp_out"
  else
    cat "$tmp_out"
  fi

  if ! $no_log && [[ -n "$ctx" ]]; then
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
    local cmd_log; cmd_log="$(ctx_dir "$ctx")/commands.log"
    {
      printf '[%s] $ lol service-log (cluster: %s, size: %s)\n' "$ts" "$cluster_id" "$size"
      scrub_pii "$(sed 's/\x1b\[[0-9;]*[mK]//g' "$tmp_out")"
      printf '\n'
    } >> "$cmd_log"
  fi

  rm -f "$tmp_out"
  return $rc
}

# ── cmd: limited-support ──────────────────────────────────────────────────
cmd_limited_support() {
  if ! command -v ocm &>/dev/null; then
    err "'ocm' not found in PATH — required for lol limited-support"
    exit 2
  fi

  local cluster_id
  cluster_id="$(resolve_cluster_id)" || exit 1

  local no_log=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-log) no_log=true; shift ;;
      *) err "Unknown option: $1"; exit 1 ;;
    esac
  done

  local ocm_id
  ocm_id="$(resolve_ocm_id "$cluster_id")" || exit 1

  local ctx; ctx="$(active_ctx)"
  local rc=0
  local tmp_out; tmp_out="$(mktemp)"

  section "Limited Support: $cluster_id"

  ocm get "/api/clusters_mgmt/v1/clusters/${ocm_id}/limited_support_reasons" \
    >"$tmp_out" 2>&1 || rc=$?

  if [[ $rc -eq 0 ]] && command -v jq &>/dev/null; then
    local total; total="$(jq -r '.total // 0' "$tmp_out")"
    if [[ "$total" -eq 0 ]]; then
      ok "No limited support reasons — cluster is in full support"
    else
      warn "$total limited support reason(s) on record"
      echo
      jq -r '.items[]? |
        "[\(.detection_type // "manual")] \(.summary)\n  \(.details // "(no details)")\n"' "$tmp_out"
    fi
  else
    cat "$tmp_out"
  fi

  if ! $no_log && [[ -n "$ctx" ]]; then
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
    local cmd_log; cmd_log="$(ctx_dir "$ctx")/commands.log"
    {
      printf '[%s] $ lol limited-support (cluster: %s)\n' "$ts" "$cluster_id"
      scrub_pii "$(sed 's/\x1b\[[0-9;]*[mK]//g' "$tmp_out")"
      printf '\n'
    } >> "$cmd_log"
  fi

  rm -f "$tmp_out"
  return $rc
}

# ── cmd: version ─────────────────────────────────────────────────────────
cmd_version() {
  print_banner

  section "Version info"
  printf "  ${BOLD}%-18s${RESET} v%s\n" "Version:" "$VERSION"

  if command -v git &>/dev/null && \
     git -C "$SCRIPT_DIR" rev-parse --git-dir &>/dev/null 2>&1; then

    local commit branch
    commit="$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null)" || commit="unknown"
    branch="$(git -C "$SCRIPT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)" || branch="unknown"
    printf "  ${BOLD}%-18s${RESET} %s\n" "Commit:" "$commit ($branch)"

    # Tagged releases — no network call, shows locally known tags
    local tags
    tags="$(git -C "$SCRIPT_DIR" tag --sort=-version:refname 2>/dev/null)" || tags=""

    if [[ -n "$tags" ]]; then
      echo
      section "Available releases"
      while IFS= read -r tag; do
        if [[ "$tag" == "v$VERSION" || "$tag" == "$VERSION" ]]; then
          printf "  ${GREEN}%s${RESET}  ${DIM}← installed${RESET}\n" "$tag"
        else
          printf "  %s\n" "$tag"
        fi
      done <<< "$tags"
    fi

    # Check for upstream updates
    echo
    info "Checking for updates..."
    git -C "$SCRIPT_DIR" fetch origin main --quiet 2>/dev/null || true

    local behind
    behind="$(git -C "$SCRIPT_DIR" rev-list "HEAD..origin/main" --count 2>/dev/null)" || behind=0
    if [[ "$behind" -gt 0 ]]; then
      warn "$behind commit(s) available upstream — run: lol upgrade"
    else
      ok "Up to date"
    fi
  fi

  echo
}

# ── cmd: completion ───────────────────────────────────────────────────────
cmd_completion() {
  local shell="${1:-}"
  case "$shell" in
    zsh)
      local comp="$SCRIPT_DIR/completions/_lol"
      if [[ ! -f "$comp" ]]; then
        err "Completion file not found: $comp"
        exit 1
      fi
      cat "$comp"
      ;;
    ""|--help|-h)
      echo "Usage: lol completion <shell>"
      echo "Supported shells: zsh"
      echo
      echo "Examples:"
      echo "  lol completion zsh > ~/.zfunc/_lol"
      echo "  source <(lol completion zsh)"
      ;;
    *)
      err "Unsupported shell: '$shell' (supported: zsh)"
      exit 1
      ;;
  esac
}

# ── cmd: reset ────────────────────────────────────────────────────────────
cmd_reset() {
  warn "This will permanently delete all lol session data:"
  echo -e "  ${BOLD}${LOL_CONFIG_DIR}${RESET}"
  echo -e "  (contexts, check runs, command logs, active session)"
  echo
  read -rp "  Are you sure? [y/N] " confirm
  [[ "${confirm,,}" != "y" ]] && { info "Reset cancelled."; exit 0; }

  rm -rf "$LOL_CONFIG_DIR"
  ok "lol reset to factory state"
}

# ── Main ──────────────────────────────────────────────────────────────────
main() {
  [[ $# -eq 0 ]] && { usage; exit 0; }

  # Extract global flags before dispatching subcommands
  LOL_CTX_NAME=""
  local -a remaining=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --context=*) LOL_CTX_NAME="${1#--context=}"; shift ;;
      --context|-c) LOL_CTX_NAME="$2"; shift 2 ;;
      --help|-h)    usage; exit 0 ;;
      --version|-v) echo "lol v$VERSION"; exit 0 ;;
      *) remaining+=("$1"); shift ;;
    esac
  done
  export LOL_CTX_NAME

  # If --context was given without a 'use', auto-resume that context
  if [[ -n "$LOL_CTX_NAME" ]] && [[ "${remaining[0]:-}" != "use" ]]; then
    if ctx_exists "$LOL_CTX_NAME"; then
      local mg; mg="$(ctx_get "$LOL_CTX_NAME" "CURRENT_MG")"
      set_active_ctx "$LOL_CTX_NAME"
      mkdir -p "$LOL_CONFIG_DIR"
      echo "$mg" > "$LOL_CONTEXT_FILE"
    fi
  fi

  local cmd="${remaining[0]:-}"
  local -a cmd_args=("${remaining[@]:1}")

  case "$cmd" in
    "")       if [[ -n "$LOL_CTX_NAME" ]]; then cmd_status; else usage; fi ;;
    use)      cmd_use      "${cmd_args[@]}" ;;
    check)    cmd_check    "${cmd_args[@]}" ;;
    cluster)  cmd_cluster  "${cmd_args[@]}" ;;
    context)  cmd_context  "${cmd_args[@]}" ;;
    ready-up) cmd_ready_up "${cmd_args[@]}" ;;
    list)     cmd_list ;;
    status)   cmd_status ;;
    upgrade)  cmd_upgrade ;;
    version)  cmd_version ;;
    help)     usage ;;
    # omc passthrough
    get|describe|logs|extract|adm|projects|top)
              cmd_omc_passthrough "$cmd" "${cmd_args[@]}" ;;
    alerts)          cmd_alerts         "${cmd_args[@]}" ;;
    service-log)     cmd_service_log    "${cmd_args[@]}" ;;
    limited-support) cmd_limited_support "${cmd_args[@]}" ;;
    reset)           cmd_reset          "${cmd_args[@]}" ;;
    completion)      cmd_completion     "${cmd_args[@]}" ;;
    *) err "Unknown command: '$cmd'"; echo; usage; exit 1 ;;
  esac
}

main "$@"
