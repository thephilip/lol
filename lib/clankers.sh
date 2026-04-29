#!/usr/bin/env bash
# lib/clankers.sh — AI integration for lol
# Supports: ollama (local), Claude API, OpenAI-compatible endpoints

# Defaults — override via ~/.config/lol/config.env or environment
LOL_CLANKERS_BACKEND="${LOL_CLANKERS_BACKEND:-ollama}"
LOL_CLANKERS_MODEL="${LOL_CLANKERS_MODEL:-gemma2:2b}"
LOL_CLANKERS_API="${LOL_CLANKERS_API:-http://localhost:11434}"
LOL_CLANKERS_API_KEY="${LOL_CLANKERS_API_KEY:-}"
LOL_VERTEX_PROJECT="${LOL_VERTEX_PROJECT:-${ANTHROPIC_VERTEX_PROJECT_ID:-}}"
LOL_VERTEX_REGION="${LOL_VERTEX_REGION:-${ANTHROPIC_VERTEX_REGION:-us-east5}}"
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

# ── Connectivity test ─────────────────────────────────────────────────────
# clankers_test <backend> <model> <api> <api_key> [vertex_project] [vertex_region]
#   Tests reachability and auth for the given backend config.
#   Returns 0 on success, 1 on failure. Prints status with ok/warn/err.
clankers_test() {
  local backend="$1" model="$2" api="$3" api_key="$4"
  local vertex_project="${5:-$LOL_VERTEX_PROJECT}"
  local vertex_region="${6:-$LOL_VERTEX_REGION}"

  command -v curl &>/dev/null || { err "curl is required but not found"; return 1; }
  command -v jq   &>/dev/null || { err "jq is required but not found";   return 1; }

  case "$backend" in
    claude)
      if [[ -z "$api_key" ]]; then
        err "No API key configured"; return 1
      fi
      info "Testing Claude API connectivity..."
      local resp http_code
      resp="$(curl -sw "%{http_code}" -o /tmp/_lol_ctest.json \
        "https://api.anthropic.com/v1/models" \
        -H "x-api-key: ${api_key}" \
        -H "anthropic-version: 2023-06-01" 2>/dev/null)"
      http_code="${resp: -3}"
      case "$http_code" in
        200)
          local models; models="$(jq -r '.data[].id' /tmp/_lol_ctest.json 2>/dev/null | head -5 | tr '\n' ' ')"
          ok "Claude API reachable — available models: ${models}"
          if jq -r '.data[].id' /tmp/_lol_ctest.json 2>/dev/null | grep -qx "$model"; then
            ok "Model '${model}' is available"
          else
            warn "Model '${model}' not found in your account — check the model ID"
          fi
          ;;
        401) err "Authentication failed — check your API key"; return 1 ;;
        403) err "Forbidden — your key may not have access to this resource"; return 1 ;;
        *)   err "Unexpected response (HTTP ${http_code}) from Claude API"; return 1 ;;
      esac
      rm -f /tmp/_lol_ctest.json
      ;;

    openai)
      if [[ -z "$api_key" ]]; then
        err "No API key configured"; return 1
      fi
      local base="${api:-https://api.openai.com}"
      info "Testing OpenAI-compatible endpoint: ${base}"
      local resp http_code
      resp="$(curl -sw "%{http_code}" -o /tmp/_lol_ctest.json \
        "${base}/v1/models" \
        -H "Authorization: Bearer ${api_key}" 2>/dev/null)"
      http_code="${resp: -3}"
      case "$http_code" in
        200)
          local count; count="$(jq '.data | length' /tmp/_lol_ctest.json 2>/dev/null)"
          ok "Endpoint reachable — ${count} model(s) available"
          if jq -r '.data[].id' /tmp/_lol_ctest.json 2>/dev/null | grep -qx "$model"; then
            ok "Model '${model}' is available"
          else
            warn "Model '${model}' not listed — it may still work, or check the model ID"
          fi
          ;;
        401) err "Authentication failed — check your API key"; return 1 ;;
        404) err "Endpoint not found — check the API URL (${base})"; return 1 ;;
        *)   err "Unexpected response (HTTP ${http_code}) from ${base}"; return 1 ;;
      esac
      rm -f /tmp/_lol_ctest.json
      ;;

    vertex)
      if ! command -v gcloud &>/dev/null; then
        err "gcloud CLI not found — required for Vertex AI backend"
        info "Install: https://cloud.google.com/sdk/docs/install"
        return 1
      fi
      info "Testing Vertex AI connectivity..."

      local token
      token="$(gcloud auth application-default print-access-token 2>/dev/null)" || {
        err "Could not get GCP access token"
        info "Run: gcloud auth application-default login"
        return 1
      }
      ok "GCP credentials valid"

      local proj="${vertex_project:-$(gcloud config get-value project 2>/dev/null)}"
      if [[ -z "$proj" || "$proj" == "(unset)" ]]; then
        err "No GCP project set"
        info "Run: gcloud config set project <project-id>"
        return 1
      fi
      ok "GCP project: ${proj}"

      local region="${vertex_region:-us-east5}"
      local endpoint="https://${region}-aiplatform.googleapis.com/v1/projects/${proj}/locations/${region}/publishers/anthropic/models/${model}:rawPredict"

      info "Testing model '${model}' in ${region}..."
      local http_code
      http_code="$(curl -s -o /tmp/_lol_ctest.json -w "%{http_code}" \
        "$endpoint" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "{\"anthropic_version\":\"vertex-2023-10-16\",\"max_tokens\":1,\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}" \
        2>/dev/null)"
      case "$http_code" in
        200|400) ok "Model '${model}' is accessible on Vertex AI" ;;
        401|403) err "Auth failed — ensure Vertex AI API is enabled and your account has access"
                 info "Enable API: gcloud services enable aiplatform.googleapis.com"
                 rm -f /tmp/_lol_ctest.json; return 1 ;;
        404)     err "Model or region not found — check model ID and region"
                 info "Available regions: us-east5, europe-west1, asia-southeast1"
                 rm -f /tmp/_lol_ctest.json; return 1 ;;
        *)       err "Unexpected response (HTTP ${http_code}) from Vertex AI"
                 rm -f /tmp/_lol_ctest.json; return 1 ;;
      esac
      rm -f /tmp/_lol_ctest.json
      ;;

    ollama|*)
      local endpoint="${api:-http://localhost:11434}"
      info "Testing ollama at ${endpoint}..."
      if ! curl -sf "${endpoint}/api/tags" &>/dev/null; then
        err "ollama is not reachable at ${endpoint}"
        info "Start it with: ollama serve"
        return 1
      fi
      ok "ollama is reachable"

      local available
      available="$(curl -sf "${endpoint}/api/tags" | jq -r '.models[].name' 2>/dev/null)"
      local model_base="${model%%:*}"
      if printf '%s\n' "$available" | grep -q "^${model_base}"; then
        ok "Model '${model}' is pulled and ready"
      else
        warn "Model '${model}' is not pulled locally"
        info "Run: ollama pull ${model}"
        return 1
      fi
      ;;
  esac
}

# ── Model listing ─────────────────────────────────────────────────────────
# _clankers_list_models <backend> <api> <api_key>
#   Prints available model IDs on stdout, one per line.
#   Returns 1 (prints nothing) if the list cannot be fetched.
_clankers_list_models() {
  local backend="$1" api="$2" api_key="$3"

  case "$backend" in
    ollama)
      curl -sf "${api:-http://localhost:11434}/api/tags" 2>/dev/null \
        | jq -r '.models[].name' 2>/dev/null | sort
      ;;
    claude)
      [[ -z "$api_key" ]] && return 1
      curl -sf "https://api.anthropic.com/v1/models" \
        -H "x-api-key: ${api_key}" \
        -H "anthropic-version: 2023-06-01" 2>/dev/null \
        | jq -r '.data[].id' 2>/dev/null | sort
      ;;
    vertex)
      # Vertex AI has no publisher-model listing API for Anthropic models.
      # These are confirmed Claude-on-Vertex model IDs as of the last lol release.
      # For the current list, check the Vertex AI Model Garden:
      #   https://console.cloud.google.com/vertex-ai/model-garden
      printf '%s\n' \
        "claude-sonnet-4-6" \
        "claude-sonnet-4-5" \
        "claude-3-5-sonnet-v2@20241022" \
        "claude-3-5-haiku@20241022" \
        "claude-3-opus@20240229" \
        "claude-3-haiku@20240307"
      ;;
    openai)
      [[ -z "$api_key" ]] && return 1
      local base="${api:-https://api.openai.com}"
      curl -sf "${base}/v1/models" \
        -H "Authorization: Bearer ${api_key}" 2>/dev/null \
        | jq -r '.data[].id' 2>/dev/null | sort
      ;;
  esac
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
    vertex)
      command -v gcloud &>/dev/null || {
        err "gcloud CLI not found — required for Vertex AI backend"
        info "Install: https://cloud.google.com/sdk/docs/install"
        return 1
      }
      local proj="${LOL_VERTEX_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
      if [[ -z "$proj" || "$proj" == "(unset)" ]]; then
        err "No GCP project set — run: gcloud config set project <id>  or set LOL_VERTEX_PROJECT"
        return 1
      fi
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

# Vertex AI — Claude via Google Cloud, uses Application Default Credentials.
# SSE response format is identical to the Claude API.
_clankers_send_vertex() {
  local model="$1" system_prompt="$2" user_prompt="$3"
  local proj="${LOL_VERTEX_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
  local region="${LOL_VERTEX_REGION:-us-east5}"

  local token
  token="$(gcloud auth application-default print-access-token 2>/dev/null)" || {
    err "Could not get GCP access token — run: gcloud auth application-default login"
    return 1
  }

  local endpoint="https://${region}-aiplatform.googleapis.com/v1/projects/${proj}/locations/${region}/publishers/anthropic/models/${model}:streamRawPredict"

  local payload
  payload="$(jq -n \
    --arg system  "$system_prompt" \
    --arg content "$user_prompt" \
    '{
      anthropic_version: "vertex-2023-10-16",
      max_tokens: 2048,
      system: $system,
      messages: [{"role": "user", "content": $content}],
      stream: true
    }')"

  curl -sN "$endpoint" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
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
    claude)  _clankers_send_claude  "$@" ;;
    vertex)  _clankers_send_vertex  "$@" ;;
    openai)  _clankers_send_openai  "$@" ;;
    *)       _clankers_send_ollama  "$@" ;;
  esac
}

# ── Tool-use loop (Claude and Vertex only) ────────────────────────────────

_CLANKERS_TOOLS='[{
  "name": "run_omc",
  "description": "Run an omc command against the active must-gather snapshot and return its output. The must-gather is a read-only offline archive — all commands are safe. Use this to investigate cluster state: pod status, logs, operator conditions, events, prometheus alerts, etc. Prefer running commands over suggesting them. Pipes and grep are supported, e.g. \"get pods -A | grep -v Running\".",
  "input_schema": {
    "type": "object",
    "properties": {
      "command": {
        "type": "string",
        "description": "Everything after \"omc\". Pipes are supported, e.g. \"get pods -A | grep -v Running\" or \"get events -n openshift-etcd --sort-by=.lastTimestamp | tail -20\""
      }
    },
    "required": ["command"]
  }
}]'

# Execute a single tool call. Prints result to stdout.
_clankers_run_tool() {
  local name="$1" input_json="$2"
  case "$name" in
    run_omc)
      local cmd_str; cmd_str="$(printf '%s' "$input_json" | jq -r '.command // empty' 2>/dev/null)"
      [[ -z "$cmd_str" ]] && { printf '(error: empty command)'; return; }
      # Guard: if the model accidentally passed a JSON object as the command
      # value (double-encoding), unwrap one level.
      if [[ "$cmd_str" == "{"* ]]; then
        local _unwrapped; _unwrapped="$(printf '%s' "$cmd_str" | jq -r '.command // empty' 2>/dev/null)"
        [[ -n "$_unwrapped" ]] && cmd_str="$_unwrapped"
      fi
      local out rc=0
      # Run via bash so the AI can use pipes, grep, awk, python3, etc.
      # omc must be the first command — enforced by the tool description.
      out="$(bash -c "omc $cmd_str" 2>&1)" || rc=$?
      [[ -z "$out" ]] && out="(no output)"
      [[ ${#out} -gt 6000 ]] && out="${out:0:6000}"$'\n''...(truncated to 6000 chars)'
      printf '%s' "$out"
      ;;
    *) printf '(unknown tool: %s)' "$name" ;;
  esac
}

# _clankers_parse_and_execute msgs_file [curl-args...]
# Streams one API response: prints text to stdout, accumulates tool calls,
# executes them, appends all turns to msgs_file.
# Returns 0 when stop_reason=end_turn, 1 when tools were executed (caller should loop).
_clankers_parse_and_execute() {
  local msgs_file="$1"; shift

  local in_tool=false stop_reason=""
  local cur_id="" cur_name="" cur_input="" cur_text=""
  local asst_content='[]'
  local -a tool_queue=()

  while IFS= read -r line; do
    [[ "$line" == data:* ]] || continue
    local j="${line#data: }"
    local t; t="$(printf '%s' "$j" | jq -r '.type // empty' 2>/dev/null)"
    case "$t" in
      content_block_start)
        local bt; bt="$(printf '%s' "$j" | jq -r '.content_block.type // empty' 2>/dev/null)"
        if [[ "$bt" == tool_use ]]; then
          in_tool=true
          cur_id="$(  printf '%s' "$j" | jq -r '.content_block.id'   2>/dev/null)"
          cur_name="$(printf '%s' "$j" | jq -r '.content_block.name' 2>/dev/null)"
          cur_input=""
        else
          in_tool=false; cur_text=""
        fi
        ;;
      content_block_delta)
        if $in_tool; then
          cur_input+="$(printf '%s' "$j" | jq -r '.delta.partial_json // empty' 2>/dev/null)"
        else
          local tok; tok="$(printf '%s' "$j" | jq -r '.delta.text // empty' 2>/dev/null)"
          [[ -n "$tok" ]] && { printf '%s' "$tok"; cur_text+="$tok"; }
        fi
        ;;
      content_block_stop)
        if $in_tool; then
          tool_queue+=("${cur_id}|${cur_name}|${cur_input}")
          # Validate cur_input is parseable JSON before using --argjson.
          # If not (e.g. truncated stream), fall back to wrapping as raw string.
          local inp_json="${cur_input:-{}}"
          if ! printf '%s' "$inp_json" | jq -e . &>/dev/null 2>&1; then
            inp_json="$(jq -n --arg raw "$cur_input" '{"command":$raw}')"
          fi
          local new_ac
          new_ac="$(printf '%s' "${asst_content:-[]}" | jq \
            --arg id "$cur_id" --arg nm "$cur_name" \
            --argjson inp "$inp_json" \
            '. + [{"type":"tool_use","id":$id,"name":$nm,"input":$inp}]' 2>/dev/null)"
          [[ -n "$new_ac" ]] && asst_content="$new_ac"
          in_tool=false
        elif [[ -n "$cur_text" ]]; then
          local new_ac
          new_ac="$(printf '%s' "${asst_content:-[]}" | jq \
            --arg tx "$cur_text" '. + [{"type":"text","text":$tx}]' 2>/dev/null)"
          [[ -n "$new_ac" ]] && asst_content="$new_ac"
          cur_text=""
        fi
        ;;
      message_delta)
        stop_reason="$(printf '%s' "$j" | jq -r '.delta.stop_reason // empty' 2>/dev/null)"
        ;;
    esac
  done < <("$@")

  # Commit assistant turn
  jq --argjson c "$asst_content" '. + [{"role":"assistant","content":$c}]' \
    "$msgs_file" > "${msgs_file}.tmp" && mv "${msgs_file}.tmp" "$msgs_file"

  [[ "$stop_reason" != "tool_use" || ${#tool_queue[@]} -eq 0 ]] && return 0

  # Execute tools and print output inline
  local results='[]'
  for entry in "${tool_queue[@]}"; do
    local tid="${entry%%|*}" rest="${entry#*|}"
    local tname="${rest%%|*}" tinput="${rest#*|}"
    local cmd_display; cmd_display="$(printf '%s' "$tinput" | jq -r '.command // ""' 2>/dev/null)"
    printf "\n${DIM}[running: omc %s]${RESET}\n" "$cmd_display"
    local out; out="$(_clankers_run_tool "$tname" "$tinput")"
    printf '%s\n' "$out"
    results="$(printf '%s' "$results" | jq \
      --arg id "$tid" --arg o "$out" \
      '. + [{"type":"tool_result","tool_use_id":$id,"content":$o}]')"
  done

  # Commit tool results as next user turn
  jq --argjson c "$results" '. + [{"role":"user","content":$c}]' \
    "$msgs_file" > "${msgs_file}.tmp" && mv "${msgs_file}.tmp" "$msgs_file"

  echo  # blank line before the next response segment
  return 1
}

# Tool-use chat for Claude API. Loops until end_turn.
_clankers_chat_claude_tools() {
  local model="$1" system="$2" msgs_file="$3"
  until
    local payload
    payload="$(jq -n \
      --arg m "$model" --arg s "$system" \
      --argjson msgs "$(cat "$msgs_file")" \
      --argjson tools "$_CLANKERS_TOOLS" \
      '{model:$m,max_tokens:4096,
        system:[{"type":"text","text":$s,"cache_control":{"type":"ephemeral"}}],
        messages:$msgs,tools:$tools,stream:true}')"
    _clankers_parse_and_execute "$msgs_file" \
      curl -sN "https://api.anthropic.com/v1/messages" \
        -H "x-api-key: ${LOL_CLANKERS_API_KEY}" \
        -H "anthropic-version: 2023-06-01" \
        -H "anthropic-beta: prompt-caching-2024-07-31" \
        -H "content-type: application/json" \
        -d "$payload"
  do :; done
}

# Tool-use chat for Vertex AI. Loops until end_turn.
_clankers_chat_vertex_tools() {
  local model="$1" system="$2" msgs_file="$3"
  local proj="${LOL_VERTEX_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
  local region="${LOL_VERTEX_REGION:-us-east5}"
  until
    local token
    token="$(gcloud auth application-default print-access-token 2>/dev/null)" || return 1
    local endpoint="https://${region}-aiplatform.googleapis.com/v1/projects/${proj}/locations/${region}/publishers/anthropic/models/${model}:streamRawPredict"
    local payload
    payload="$(jq -n \
      --arg s "$system" \
      --argjson msgs "$(cat "$msgs_file")" \
      --argjson tools "$_CLANKERS_TOOLS" \
      '{"anthropic_version":"vertex-2023-10-16","max_tokens":4096,
        "system":$s,"messages":$msgs,"tools":$tools,"stream":true}')"
    _clankers_parse_and_execute "$msgs_file" \
      curl -sN "$endpoint" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        -d "$payload"
  do :; done
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

  # Build system prompt — prepend skill docs. Cloud backends get full content;
  # ollama caps at 2500 chars per skill. Also loads private skills from
  # $LOL_CONFIG_DIR/skills/ (never committed to the public repo).
  local skill_prefix=""
  local skill_cap=2500
  [[ "$backend" != "ollama" ]] && skill_cap=0  # 0 = no cap for cloud backends

  local -a _run_skills=()
  for _f in "$SCRIPT_DIR/skills/"*.md; do [[ -f "$_f" ]] && _run_skills+=("$_f"); done
  for _f in "$LOL_CONFIG_DIR/skills/"*.md; do [[ -f "$_f" ]] && _run_skills+=("$_f"); done

  for _sf in "${_run_skills[@]}"; do
    if [[ "$skill_cap" -gt 0 ]]; then
      skill_prefix+="$(head -c "$skill_cap" "$_sf")"$'\n\n---\n\n'
    else
      skill_prefix+="$(cat "$_sf")"$'\n\n---\n\n'
    fi
  done

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

# ── Multi-turn chat functions ──────────────────────────────────────────────
# These mirror the _clankers_send_* functions but accept a full messages
# JSON array instead of a single prompt, enabling conversation history.

# ollama — /api/chat for multi-turn; system goes in messages array
_clankers_chat_ollama() {
  local model="$1" system="$2" messages="$3"
  local full_messages
  full_messages="$(printf '%s' "$messages" | jq --arg s "$system" \
    '[{"role":"system","content":$s}] + .')"

  curl -sN "${LOL_CLANKERS_API}/api/chat" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg m "$model" --argjson msgs "$full_messages" \
          '{model:$m, messages:$msgs, stream:true}')" \
  | while IFS= read -r line; do
      local done_flag; done_flag="$(printf '%s' "$line" | jq -r '.done' 2>/dev/null)"
      if [[ "$done_flag" == "true" ]]; then
        local eval_count eval_dur
        eval_count="$(printf '%s' "$line" | jq -r '.eval_count // 0')"
        eval_dur="$(  printf '%s' "$line" | jq -r '.eval_duration // 0')"
        if [[ "$eval_dur" -gt 0 ]]; then
          local tps; tps=$(( eval_count * 1000000000 / eval_dur ))
          printf "\n\n${DIM}%d tokens · %d tok/s${RESET}\n" "$eval_count" "$tps"
        fi
      else
        local token; token="$(printf '%s' "$line" | jq -r '.message.content // empty' 2>/dev/null)"
        [[ -n "$token" ]] && printf '%s' "$token"
      fi
    done
}

# Claude API — cached system prompt, messages array for history
_clankers_chat_claude() {
  local model="$1" system="$2" messages="$3"
  local payload
  payload="$(jq -n \
    --arg m "$model" --arg s "$system" --argjson msgs "$messages" \
    '{
      model: $m, max_tokens: 2048,
      system: [{"type":"text","text":$s,"cache_control":{"type":"ephemeral"}}],
      messages: $msgs, stream: true
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
          printf '%s' "$(printf '%s' "$json" | jq -r '.delta.text // empty' 2>/dev/null)"
          ;;
        message_delta)
          local t; t="$(printf '%s' "$json" | jq -r '.usage.output_tokens // 0' 2>/dev/null)"
          printf "\n\n${DIM}%s output tokens${RESET}\n" "$t"
          ;;
      esac
    done
}

# Vertex AI — Claude via Google Cloud, messages array
_clankers_chat_vertex() {
  local model="$1" system="$2" messages="$3"
  local proj="${LOL_VERTEX_PROJECT:-$(gcloud config get-value project 2>/dev/null)}"
  local region="${LOL_VERTEX_REGION:-us-east5}"
  local token
  token="$(gcloud auth application-default print-access-token 2>/dev/null)" || {
    err "Could not get GCP access token — run: gcloud auth application-default login"
    return 1
  }
  local endpoint="https://${region}-aiplatform.googleapis.com/v1/projects/${proj}/locations/${region}/publishers/anthropic/models/${model}:streamRawPredict"
  local payload
  payload="$(jq -n \
    --arg s "$system" --argjson msgs "$messages" \
    '{"anthropic_version":"vertex-2023-10-16","max_tokens":2048,"system":$s,"messages":$msgs,"stream":true}')"

  curl -sN "$endpoint" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
  | while IFS= read -r line; do
      [[ "$line" == data:* ]] || continue
      local json="${line#data: }"
      local type; type="$(printf '%s' "$json" | jq -r '.type // empty' 2>/dev/null)"
      case "$type" in
        content_block_delta)
          printf '%s' "$(printf '%s' "$json" | jq -r '.delta.text // empty' 2>/dev/null)"
          ;;
        message_delta)
          local t; t="$(printf '%s' "$json" | jq -r '.usage.output_tokens // 0' 2>/dev/null)"
          printf "\n\n${DIM}%s output tokens${RESET}\n" "$t"
          ;;
      esac
    done
}

# OpenAI-compatible — messages array with system prepended
_clankers_chat_openai() {
  local model="$1" system="$2" messages="$3"
  local base="${LOL_CLANKERS_API:-https://api.openai.com}"
  local full_messages
  full_messages="$(printf '%s' "$messages" | jq --arg s "$system" \
    '[{"role":"system","content":$s}] + .')"
  local payload
  payload="$(jq -n --arg m "$model" --argjson msgs "$full_messages" \
    '{model:$m, messages:$msgs, stream:true}')"

  curl -sN "${base}/v1/chat/completions" \
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

# Dispatcher for multi-turn chat
_clankers_chat() {
  local backend="${LOL_CLANKERS_BACKEND:-ollama}"
  case "$backend" in
    claude)  _clankers_chat_claude  "$@" ;;
    vertex)  _clankers_chat_vertex  "$@" ;;
    openai)  _clankers_chat_openai  "$@" ;;
    *)       _clankers_chat_ollama  "$@" ;;
  esac
}

# ── clankers_ask ───────────────────────────────────────────────────────────
# Main entry point for lol ask.
# Args: question (empty = interactive), model, no_log flag
clankers_ask() {
  local question="$1"
  local model="${2:-$LOL_CLANKERS_MODEL}"
  local no_log="${3:-false}"

  clankers_check_deps "$model" || return 1

  local backend="${LOL_CLANKERS_BACKEND:-ollama}"

  # ── Build system prompt ─────────────────────────────────────────────────
  # Skills: full content for cloud backends, capped for ollama
  local system_prompt=""
  local skill_cap=3000
  [[ "$backend" != "ollama" ]] && skill_cap=0

  local -a _ask_skills=()
  for _f in "$SCRIPT_DIR/skills/"*.md; do [[ -f "$_f" ]] && _ask_skills+=("$_f"); done
  for _f in "$LOL_CONFIG_DIR/skills/"*.md; do [[ -f "$_f" ]] && _ask_skills+=("$_f"); done

  for _skill in "${_ask_skills[@]}"; do
    if [[ "$skill_cap" -gt 0 ]]; then
      system_prompt+="$(head -c "$skill_cap" "$_skill")"
    else
      system_prompt+="$(cat "$_skill")"
    fi
    system_prompt+=$'\n\n---\n\n'
  done

  # Cluster context: must-gather + cluster ID
  local cluster_context=""
  local mg_path; mg_path="$(resolve_mg_path 2>/dev/null)" || mg_path=""
  if [[ -n "$mg_path" && -d "$mg_path" ]]; then
    if command omc use "$mg_path" &>/dev/null 2>&1; then
      local version; version="$(omc get clusterversion version \
        -o jsonpath='{.status.history[0].version}' 2>/dev/null)" || version=""
      cluster_context+="## Active must-gather\nPath: ${mg_path}\n"
      [[ -n "$version" ]] && cluster_context+="OCP version: ${version}\n"
      local alerts; alerts="$(omc prometheus alertrule -s firing 2>/dev/null | head -10)" || alerts=""
      [[ -n "$alerts" ]] && cluster_context+="### Firing alerts\n\`\`\`\n${alerts}\n\`\`\`\n"
    fi
  fi
  local cluster_id; cluster_id="$(resolve_cluster_id 2>/dev/null)" || cluster_id=""
  [[ -n "$cluster_id" && -z "$cluster_context" ]] && \
    cluster_context+="## Cluster\nID: ${cluster_id}\n"

  [[ -n "$cluster_context" ]] && \
    system_prompt+="$(printf '## Current session context\n%b' "$cluster_context")"$'\n\n---\n\n'

  if [[ "$backend" == "claude" || "$backend" == "vertex" ]]; then
    system_prompt+="You are an expert OpenShift and Red Hat support engineer. You have access to a run_omc tool — use it proactively to run omc commands against the must-gather and incorporate the real output into your analysis. Don't just suggest commands; run them and summarise what you find. Answer concisely and technically."
  else
    system_prompt+="You are an expert OpenShift and Red Hat support engineer. Answer concisely and technically. When recommending investigation steps, provide specific omc or ocm commands and explain what to look for in the output."
  fi

  # ── Session header ──────────────────────────────────────────────────────
  section "lol ask (${backend} · ${model})"
  [[ -n "$mg_path" ]]    && info "Must-gather: ${mg_path}"
  [[ -n "$cluster_id" ]] && info "Cluster ID:  ${cluster_id}"
  [[ -z "$mg_path" && -z "$cluster_id" ]] && \
    info "No cluster context set — answering from skills only"
  echo

  local ctx; ctx="$(active_ctx)"
  local cmd_log=""
  if ! $no_log && [[ -n "$ctx" ]]; then
    cmd_log="$(ctx_dir "$ctx")/commands.log"
    local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
    printf '[%s] $ lol ask session start (backend: %s, model: %s)\n' \
      "$ts" "$backend" "$model" >> "$cmd_log"
  fi

  # ── Conversation loop ───────────────────────────────────────────────────
  # Claude and Vertex use file-based message history to support content arrays
  # produced by the tool-use loop. Ollama and OpenAI use a simple string variable.
  local use_tools=false msgs_file=""
  local messages='[]'
  if [[ "$backend" == "claude" || "$backend" == "vertex" ]]; then
    use_tools=true
    msgs_file="$(mktemp)"
    printf '[]' > "$msgs_file"
  fi

  local turn=0

  while true; do
    local user_input=""

    if [[ $turn -eq 0 && -n "$question" ]]; then
      user_input="$question"
    else
      echo
      if command -v gum &>/dev/null; then
        user_input="$(gum input \
          --placeholder "Ask a question (empty or 'exit' to quit)" \
          --prompt "You: " \
          --width 80)"
      else
        read -rp "You: " user_input
      fi
      [[ -z "$user_input" || "${user_input,,}" =~ ^(exit|quit|q)$ ]] && break
    fi

    # Add user message to history
    if $use_tools; then
      jq --arg c "$user_input" '. + [{"role":"user","content":$c}]' \
        "$msgs_file" > "${msgs_file}.tmp" && mv "${msgs_file}.tmp" "$msgs_file"
    else
      messages="$(printf '%s' "$messages" | \
        jq --arg c "$user_input" '. + [{"role":"user","content":$c}]')"
    fi

    # Stream response, capturing text to temp file for logging
    echo
    printf "${BOLD}${CYAN}┌─ Response ─────────────────────────────────────────────────────${RESET}\n"
    echo

    local resp_file; resp_file="$(mktemp)"
    if $use_tools; then
      "_clankers_chat_${backend}_tools" "$model" "$system_prompt" "$msgs_file" \
        | tee "$resp_file"
    else
      _clankers_chat "$model" "$system_prompt" "$messages" | tee "$resp_file"
    fi
    echo
    printf "${BOLD}${CYAN}└────────────────────────────────────────────────────────────────${RESET}\n"

    # Capture clean text for logging (strip ANSI, tool output lines, stats)
    local assistant_response
    assistant_response="$(sed 's/\x1b\[[0-9;]*[mK]//g' "$resp_file" \
      | grep -v " output tokens" | grep -v "tok/s" \
      | grep -v '^\[running:' | sed '/^[[:space:]]*$/d')"
    rm -f "$resp_file"

    # Non-tool backends: add assistant response to history manually
    if ! $use_tools; then
      messages="$(printf '%s' "$messages" | \
        jq --arg c "$assistant_response" '. + [{"role":"assistant","content":$c}]')"
    fi
    # Tool backends: msgs_file already updated by _clankers_chat_*_tools

    # Log this turn to commands.log
    if [[ -n "$cmd_log" ]]; then
      local ts; ts="$(date -u +%Y-%m-%dT%H:%M:%S)"
      {
        printf '[%s] You: %s\n' "$ts" "$user_input"
        printf 'Assistant: %s\n\n' "$assistant_response"
      } >> "$cmd_log"
    fi

    (( turn++ )) || true
    # Exit after first response in single-shot mode
    [[ -n "$question" ]] && break
  done

  [[ -n "$msgs_file" ]] && rm -f "$msgs_file" "${msgs_file}.tmp"
  [[ -n "$cmd_log" ]] && \
    printf '[%s] $ lol ask session end (%d turn(s))\n\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%S)" "$turn" >> "$cmd_log"
}
