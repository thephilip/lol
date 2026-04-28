#!/usr/bin/env bash
# lib/clankers.sh — AI integration for lol
# Supports: ollama (local), Claude API, OpenAI-compatible endpoints

# Defaults — override via ~/.config/lol/config.env or environment
LOL_CLANKERS_BACKEND="${LOL_CLANKERS_BACKEND:-ollama}"
LOL_CLANKERS_MODEL="${LOL_CLANKERS_MODEL:-gemma2:2b}"
LOL_CLANKERS_API="${LOL_CLANKERS_API:-http://localhost:11434}"
LOL_CLANKERS_API_KEY="${LOL_CLANKERS_API_KEY:-}"
_CLANKERS_MAX_CHARS=18000   # context budget (leaves room for prompt overhead + response)

# ── Namespace inference ────────────────────────────────────────────────────
_clankers_ns_for_keyword() {
  case "${1,,}" in
    marketplace|catalogsource|catalog|packagemanifest)
                                        echo "openshift-marketplace" ;;
    etcd)                               echo "openshift-etcd" ;;
    dns|coredns)                        echo "openshift-dns" ;;
    ingress|router)                     echo "openshift-ingress" ;;
    ingress-operator)                   echo "openshift-ingress-operator" ;;
    monitoring|prometheus|alertmanager|grafana|thanos)
                                        echo "openshift-monitoring" ;;
    logging|loki|elasticsearch|kibana|fluentd)
                                        echo "openshift-logging" ;;
    storage|csi|pv|pvc|volumesnapshot) echo "openshift-cluster-csi-drivers" ;;
    auth|authentication|oauth)          echo "openshift-authentication" ;;
    console)                            echo "openshift-console" ;;
    machine|machineapi|machineset|machineconfig)
                                        echo "openshift-machine-api" ;;
    mco|mcp|machineconfig-operator)     echo "openshift-machine-config-operator" ;;
    ovn|ovnkubernetes|ovs)             echo "openshift-ovn-kubernetes" ;;
    sdn)                                echo "openshift-sdn" ;;
    image|registry|imagestream)         echo "openshift-image-registry" ;;
    olm|operators|catalogoperator|subscription)
                                        echo "openshift-operator-lifecycle-manager" ;;
    apiserver|kube-apiserver)           echo "openshift-kube-apiserver" ;;
    scheduler|kube-scheduler)          echo "openshift-kube-scheduler" ;;
    controller|kube-controller)        echo "openshift-kube-controller-manager" ;;
    cloud|cco|credential)              echo "openshift-cloud-credential-operator" ;;
    samples)                           echo "openshift-cluster-samples-operator" ;;
    network|multus|whereabouts)        echo "openshift-network-diagnostics" ;;
    *) echo "" ;;
  esac
}

clankers_infer_namespaces() {
  local query="${1,,}"
  local -a seen=()

  for word in $query; do
    word="${word//[^a-z0-9-]/}"
    [[ -z "$word" ]] && continue
    local ns; ns="$(_clankers_ns_for_keyword "$word")"
    [[ -z "$ns" ]] && continue
    printf '%s\n' "${seen[@]:-}" | grep -qx "$ns" || seen+=("$ns")
  done

  printf '%s\n' "${seen[@]:-}"
}

# ── Dependency checks ──────────────────────────────────────────────────────
clankers_check_deps() {
  local model="$1"
  local backend="${LOL_CLANKERS_BACKEND:-ollama}"

  command -v curl &>/dev/null || { err "clankers requires 'curl'"; return 1; }
  command -v jq   &>/dev/null || { err "clankers requires 'jq'";   return 1; }

  case "$backend" in
    claude)
      [[ -n "$LOL_CLANKERS_API_KEY" ]] || {
        err "Claude API requires LOL_CLANKERS_API_KEY to be set."
        info "Run: lol config  or set it in ~/.config/lol/config.env"
        return 1
      }
      ;;
    openai)
      [[ -n "$LOL_CLANKERS_API_KEY" ]] || {
        err "OpenAI-compatible API requires LOL_CLANKERS_API_KEY to be set."
        info "Run: lol config  or set it in ~/.config/lol/config.env"
        return 1
      }
      ;;
    ollama|*)
      if ! curl -sf "${LOL_CLANKERS_API}/api/tags" &>/dev/null; then
        err "ollama is not reachable at ${LOL_CLANKERS_API}"
        info "Start it with:  ollama serve"
        info "Install from:   https://ollama.ai"
        return 1
      fi

      local available
      available="$(curl -sf "${LOL_CLANKERS_API}/api/tags" \
        | jq -r '.models[].name' 2>/dev/null)" || available=""

      local model_base="${model%%:*}"
      if ! printf '%s\n' "$available" | grep -q "^${model_base}"; then
        warn "Model '${model}' is not pulled locally."
        _tui_confirm "Pull it now?" || { info "Run: ollama pull $model"; return 1; }
        ollama pull "$model" || return 1
      fi
      ;;
  esac
}

# ── Context gathering ──────────────────────────────────────────────────────
_clankers_gather_ns() {
  local ns="$1"
  local out=""

  local pods; pods="$(omc get pods -n "$ns" 2>/dev/null)" || pods=""
  [[ -n "$pods" ]] && out+="### Pods — ${ns}\n\`\`\`\n${pods}\n\`\`\`\n\n"

  local events
  events="$(omc get events -n "$ns" 2>/dev/null \
    | grep -iE 'Warning|Error|CrashLoop|OOMKill|Failed|BackOff|Unhealthy' \
    | head -25)" || events=""
  [[ -n "$events" ]] && out+="### Warning Events — ${ns}\n\`\`\`\n${events}\n\`\`\`\n\n"

  local problem_pods
  problem_pods="$(omc get pods -n "$ns" 2>/dev/null \
    | awk 'NR>1 && $3!="Running" && $3!="Completed" && $3!="Succeeded" {print $1}')" \
    || problem_pods=""

  if [[ -n "$problem_pods" ]]; then
    out+="### Logs from problem pods — ${ns}\n"
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      local log=""
      log="$(omc logs -n "$ns" "$pod" --tail=40 2>/dev/null)" \
        || log="$(omc logs -n "$ns" "$pod" --tail=40 -p 2>/dev/null)" \
        || log=""
      if [[ -n "$log" ]]; then
        out+="\n#### ${pod}\n\`\`\`\n${log}\n\`\`\`\n"
      fi
      [[ ${#out} -gt $(( _CLANKERS_MAX_CHARS / 2 )) ]] && {
        out+="\n_(remaining pod logs omitted — context budget reached)_\n"
        break
      }
    done <<< "$problem_pods"
    out+="\n"
  fi

  printf '%s' "$out"
}

_clankers_gather_cluster() {
  local out=""

  local co; co="$(omc get co 2>/dev/null \
    | awk 'NR==1 || $3!="True" || $4!="False" || $5!="False"')" || co=""
  [[ -n "$co" ]] && out+="### Cluster Operators (degraded/progressing)\n\`\`\`\n${co}\n\`\`\`\n\n"

  local nodes; nodes="$(omc get nodes 2>/dev/null)" || nodes=""
  [[ -n "$nodes" ]] && out+="### Nodes\n\`\`\`\n${nodes}\n\`\`\`\n\n"

  local events; events="$(omc get events -A 2>/dev/null \
    | grep -iE 'Warning|Error|CrashLoop|Failed' | head -30)" || events=""
  [[ -n "$events" ]] && out+="### Cluster-wide Warning Events\n\`\`\`\n${events}\n\`\`\`\n\n"

  printf '%s' "$out"
}

# ── Backend send functions ─────────────────────────────────────────────────

# ollama — local model via Ollama REST API
_clankers_send_ollama() {
  local model="$1" system_prompt="$2" user_prompt="$3"

  curl -sN "${LOL_CLANKERS_API}/api/generate" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
          --arg model  "$model" \
          --arg system "$system_prompt" \
          --arg prompt "$user_prompt" \
          '{model: $model, system: $system, prompt: $prompt, stream: true}'
    )" \
  | while IFS= read -r line; do
      local done_flag token
      done_flag="$(printf '%s' "$line" | jq -r '.done' 2>/dev/null)"
      if [[ "$done_flag" == "true" ]]; then
        local eval_count eval_dur
        eval_count="$(printf '%s' "$line" | jq -r '.eval_count // 0')"
        eval_dur="$(  printf '%s' "$line" | jq -r '.eval_duration // 0')"
        if [[ "$eval_dur" -gt 0 ]]; then
          local tps; tps=$(( eval_count * 1000000000 / eval_dur ))
          printf "\n\n${DIM}%d tokens · %d tok/s${RESET}\n" "$eval_count" "$tps"
        fi
      else
        token="$(printf '%s' "$line" | jq -r '.response // empty' 2>/dev/null)"
        printf '%s' "$token"
      fi
    done
}

# Claude API — Anthropic messages endpoint with prompt caching
# The system prompt (which includes the omc skill) is cached to save tokens
# on repeated invocations within the cache TTL (5 minutes).
_clankers_send_claude() {
  local model="$1" system_prompt="$2" user_prompt="$3"

  local payload
  payload="$(jq -n \
    --arg model   "$model" \
    --arg system  "$system_prompt" \
    --arg content "$user_prompt" \
    '{
      model: $model,
      max_tokens: 2048,
      system: [{"type": "text", "text": $system, "cache_control": {"type": "ephemeral"}}],
      messages: [{"role": "user", "content": $content}],
      stream: true
    }')"

  curl -sN "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${LOL_CLANKERS_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: prompt-caching-2024-07-31" \
    -H "content-type: application/json" \
    -d "$payload" \
  | while IFS= read -r line; do
      [[ "$line" == data:* ]] || continue
      local json="${line#data: }"
      local type; type="$(printf '%s' "$json" | jq -r '.type // empty' 2>/dev/null)"
      case "$type" in
        content_block_delta)
          local token; token="$(printf '%s' "$json" | jq -r '.delta.text // empty' 2>/dev/null)"
          printf '%s' "$token"
          ;;
        message_delta)
          local out_tok; out_tok="$(printf '%s' "$json" | jq -r '.usage.output_tokens // 0' 2>/dev/null)"
          printf "\n\n${DIM}%s output tokens${RESET}\n" "$out_tok"
          ;;
      esac
    done
}

# OpenAI-compatible — works with any endpoint using the chat/completions API
_clankers_send_openai() {
  local model="$1" system_prompt="$2" user_prompt="$3"
  local base_url="${LOL_CLANKERS_API:-https://api.openai.com}"

  local payload
  payload="$(jq -n \
    --arg model   "$model" \
    --arg system  "$system_prompt" \
    --arg content "$user_prompt" \
    '{
      model: $model,
      messages: [
        {"role": "system", "content": $system},
        {"role": "user",   "content": $content}
      ],
      stream: true
    }')"

  curl -sN "${base_url}/v1/chat/completions" \
    -H "Authorization: Bearer ${LOL_CLANKERS_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
  | while IFS= read -r line; do
      [[ "$line" == data:* ]] || continue
      local json="${line#data: }"
      [[ "$json" == "[DONE]" ]] && break
      local token; token="$(printf '%s' "$json" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)"
      [[ -n "$token" ]] && printf '%s' "$token"
    done
}

# Dispatcher — routes to the appropriate backend
_clankers_send() {
  local backend="${LOL_CLANKERS_BACKEND:-ollama}"
  case "$backend" in
    claude) _clankers_send_claude "$@" ;;
    openai) _clankers_send_openai "$@" ;;
    *)      _clankers_send_ollama "$@" ;;
  esac
}

# ── Main entry point ───────────────────────────────────────────────────────
clankers_run() {
  local query="$1"
  local mg_path="$2"
  local model="${3:-$LOL_CLANKERS_MODEL}"

  clankers_check_deps "$model" || return 1

  local backend="${LOL_CLANKERS_BACKEND:-ollama}"
  section "clankers (${backend} · ${model})"
  info "Query: ${query}"
  echo

  omc_use "$mg_path" || return 2

  # Infer scope
  local -a namespaces=()
  while IFS= read -r ns; do
    [[ -n "$ns" ]] && namespaces+=("$ns")
  done < <(clankers_infer_namespaces "$query")

  if [[ ${#namespaces[@]} -gt 0 ]]; then
    info "Scope inferred: ${namespaces[*]}"
  else
    info "No specific component inferred — using cluster-wide context"
  fi
  echo

  # Always include version + firing alerts
  local cv_version platform
  cv_version="$(omc get clusterversion version \
    -o jsonpath='{.status.history[0].version}' 2>/dev/null)" || cv_version="unknown"
  platform="$(omc get infrastructure cluster \
    -o jsonpath='{.status.platformStatus.type}' 2>/dev/null)" || platform="unknown"

  local context=""
  context+="## Cluster\n- OCP: ${cv_version}\n- Platform: ${platform}\n\n"

  local alerts; alerts="$(omc prometheus alertrule -s firing 2>/dev/null \
    | head -20)" || alerts=""
  [[ -n "$alerts" ]] && context+="## Firing Alerts\n\`\`\`\n${alerts}\n\`\`\`\n\n"

  # Namespace or cluster data
  if [[ ${#namespaces[@]} -gt 0 ]]; then
    local per_budget=$(( (_CLANKERS_MAX_CHARS - ${#context}) / ${#namespaces[@]} ))
    for ns in "${namespaces[@]}"; do
      local chunk; chunk="$(_clankers_gather_ns "$ns")"
      context+="${chunk:0:$per_budget}"
    done
  else
    local cluster_chunk; cluster_chunk="$(_clankers_gather_cluster)"
    local remaining=$(( _CLANKERS_MAX_CHARS - ${#context} ))
    context+="${cluster_chunk:0:$remaining}"
  fi

  # Build system prompt — prepend omc skill excerpt if available.
  # For cloud backends (claude/openai), include more of the skill since
  # context windows are larger. For ollama, cap at 2500 chars.
  local skill_prefix=""
  local _omc_skill="${SCRIPT_DIR}/skills/omc.md"
  if [[ -f "$_omc_skill" ]]; then
    local skill_cap=2500
    [[ "$backend" != "ollama" ]] && skill_cap=0  # 0 = no cap for cloud backends
    if [[ "$skill_cap" -gt 0 ]]; then
      skill_prefix="$(head -c "$skill_cap" "$_omc_skill")"$'\n\n'"---"$'\n\n'
    else
      skill_prefix="$(cat "$_omc_skill")"$'\n\n'"---"$'\n\n'
    fi
  fi

  local system_prompt
  system_prompt="${skill_prefix}You are an expert OpenShift/Kubernetes support engineer analyzing a must-gather snapshot. Be concise and technical. Quote specific error messages from the data. State the most likely root cause first, then list actionable next steps. When suggesting next steps, include specific omc commands to run."

  local user_prompt
  user_prompt="$(printf '## Question\n%s\n\n## Must-gather Data\n%b\nAnalyse the data and answer the question. If the root cause is visible, state it clearly and quote the relevant log lines or events.' "$query" "$context")"

  info "Backend: ${backend} · Context: ~${#user_prompt} chars"
  echo
  printf "${BOLD}${CYAN}┌─ Analysis ─────────────────────────────────────────────────────${RESET}\n"
  echo

  _clankers_send "$model" "$system_prompt" "$user_prompt"

  echo
  printf "${BOLD}${CYAN}└────────────────────────────────────────────────────────────────${RESET}\n"
  echo
}
