#!/usr/bin/env bash
# lib/clankers.sh — local AI integration for lol
# Requires: ollama (https://ollama.ai), curl, jq

# Defaults — override via ~/.config/lol/config.env or environment
LOL_CLANKERS_MODEL="${LOL_CLANKERS_MODEL:-gemma2:2b}"
LOL_CLANKERS_API="${LOL_CLANKERS_API:-http://localhost:11434}"
_CLANKERS_MAX_CHARS=18000   # context budget (leaves room for prompt overhead + response)

# ── Namespace inference ────────────────────────────────────────────────────
# Maps a single keyword to an OpenShift namespace. Returns empty if no match.
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

# Tokenise the query and return a deduplicated list of inferred namespaces.
clankers_infer_namespaces() {
  local query="${1,,}"
  local -a seen=()

  for word in $query; do
    word="${word//[^a-z0-9-]/}"   # strip punctuation
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

  command -v curl &>/dev/null || { err "clankers requires 'curl'"; return 1; }
  command -v jq   &>/dev/null || { err "clankers requires 'jq'";   return 1; }

  if ! curl -sf "${LOL_CLANKERS_API}/api/tags" &>/dev/null; then
    err "ollama is not reachable at ${LOL_CLANKERS_API}"
    info "Start it with:  ollama serve"
    info "Install from:   https://ollama.ai"
    return 1
  fi

  # Check model is pulled; offer to pull if not
  local available
  available="$(curl -sf "${LOL_CLANKERS_API}/api/tags" \
    | jq -r '.models[].name' 2>/dev/null)" || available=""

  local model_base="${model%%:*}"
  if ! printf '%s\n' "$available" | grep -q "^${model_base}"; then
    warn "Model '${model}' is not pulled locally."
    read -rp "  Pull it now? [y/N] " confirm
    if [[ "${confirm,,}" == "y" ]]; then
      ollama pull "$model" || return 1
    else
      info "Run: ollama pull $model"
      return 1
    fi
  fi
}

# ── Context gathering ──────────────────────────────────────────────────────
# Gather pods, warning events, and logs from problem pods in a namespace.
_clankers_gather_ns() {
  local ns="$1"
  local out=""

  # Pods
  local pods; pods="$(omc get pods -n "$ns" 2>/dev/null)" || pods=""
  [[ -n "$pods" ]] && out+="### Pods — ${ns}\n\`\`\`\n${pods}\n\`\`\`\n\n"

  # Warning events
  local events
  events="$(omc get events -n "$ns" 2>/dev/null \
    | grep -iE 'Warning|Error|CrashLoop|OOMKill|Failed|BackOff|Unhealthy' \
    | head -25)" || events=""
  [[ -n "$events" ]] && out+="### Warning Events — ${ns}\n\`\`\`\n${events}\n\`\`\`\n\n"

  # Logs from non-running pods — most diagnostic for crash issues
  local problem_pods
  problem_pods="$(omc get pods -n "$ns" 2>/dev/null \
    | awk 'NR>1 && $3!="Running" && $3!="Completed" && $3!="Succeeded" {print $1}')" \
    || problem_pods=""

  if [[ -n "$problem_pods" ]]; then
    out+="### Logs from problem pods — ${ns}\n"
    while IFS= read -r pod; do
      [[ -z "$pod" ]] && continue
      local log=""
      # Try current logs, then previous container
      log="$(omc logs -n "$ns" "$pod" --tail=40 2>/dev/null)" \
        || log="$(omc logs -n "$ns" "$pod" --tail=40 -p 2>/dev/null)" \
        || log=""
      if [[ -n "$log" ]]; then
        out+="\n#### ${pod}\n\`\`\`\n${log}\n\`\`\`\n"
      fi
      # Bail if we've already burned through half our budget
      [[ ${#out} -gt $(( _CLANKERS_MAX_CHARS / 2 )) ]] && {
        out+="\n_(remaining pod logs omitted — context budget reached)_\n"
        break
      }
    done <<< "$problem_pods"
    out+="\n"
  fi

  printf '%s' "$out"
}

# Broad cluster-level context when no namespace is inferred.
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

# ── Main entry point ───────────────────────────────────────────────────────
clankers_run() {
  local query="$1"
  local mg_path="$2"
  local model="${3:-$LOL_CLANKERS_MODEL}"

  clankers_check_deps "$model" || return 1

  section "clankers (${model})"
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

  local alerts; alerts="$(omc get alerts -A 2>/dev/null \
    | grep -i 'Firing' | head -20)" || alerts=""
  [[ -n "$alerts" ]] && context+="## Firing Alerts\n\`\`\`\n${alerts}\n\`\`\`\n\n"

  # Namespace or cluster data
  if [[ ${#namespaces[@]} -gt 0 ]]; then
    local per_budget=$(( (_CLANKERS_MAX_CHARS - ${#context}) / ${#namespaces[@]} ))
    for ns in "${namespaces[@]}"; do
      local chunk; chunk="$(_clankers_gather_ns "$ns")"
      # Trim to per-namespace budget
      context+="${chunk:0:$per_budget}"
    done
  else
    local cluster_chunk; cluster_chunk="$(_clankers_gather_cluster)"
    local remaining=$(( _CLANKERS_MAX_CHARS - ${#context} ))
    context+="${cluster_chunk:0:$remaining}"
  fi

  # Build prompt
  local system_prompt
  system_prompt="You are an expert OpenShift/Kubernetes support engineer analyzing a must-gather snapshot. Be concise and technical. Quote specific error messages from the data. State the most likely root cause first, then list actionable next steps."

  local user_prompt
  user_prompt="$(printf '## Question\n%s\n\n## Must-gather Data\n%b\nAnalyse the data and answer the question. If the root cause is visible, state it clearly and quote the relevant log lines or events.' "$query" "$context")"

  info "Context size: ~${#user_prompt} chars"
  echo
  printf "${BOLD}${CYAN}┌─ Analysis ─────────────────────────────────────────────────────${RESET}\n"
  echo

  # Stream response
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
        # Print timing stats from the final message
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

  echo
  printf "${BOLD}${CYAN}└────────────────────────────────────────────────────────────────${RESET}\n"
  echo
}
