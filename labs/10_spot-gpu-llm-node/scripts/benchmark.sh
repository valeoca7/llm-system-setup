#!/bin/bash
# lab02 - reproducible LLM benchmark from the laptop: ./benchmark.sh [endpoints.json] [prompts.txt] [instance_label] -> results/bench_results.csv
# tokens/s: ollama = pure generation (eval_duration); openai/bedrock = wall-clock based, not directly comparable.
# TODO: compare TypeSafe Jev (hosted only) vs gpt-oss:20b / qwen3.8:27b as judge with a separate decision-accuracy harness.
set -euo pipefail

# --- config (env overrides win) ---

ENDPOINTS_FILE="${1:-${ENDPOINTS_FILE:-bench_endpoints.json}}"
PROMPTS_FILE="${2:-${PROMPTS_FILE:-bench_prompts.txt}}"
INSTANCE_LABEL="${3:-${INSTANCE_LABEL:-unlabeled}}"

RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../results" && pwd)}"
OUTPUT_CSV="${OUTPUT_CSV:-${RESULTS_DIR}/bench_results.csv}"

REPS="${REPS:-3}"                     # timed repetitions per (endpoint, prompt)
WARMUP_REPS="${WARMUP_REPS:-1}"       # untimed repetitions per (endpoint, prompt), run first
TEMPERATURE="${TEMPERATURE:-0}"       # pinned decoding param, recorded on every row
SEED="${SEED:-42}"                    # pinned decoding param, recorded on every row
NUM_PREDICT="${NUM_PREDICT:-256}"     # max tokens to generate, recorded on every row
REQUEST_TIMEOUT_S="${REQUEST_TIMEOUT_S:-120}"

# --- setup ---
for dep in curl jq awk; do
  command -v "$dep" >/dev/null 2>&1 || { echo "ERROR: '$dep' is required but not found on PATH." >&2; exit 1; }
done
# aws is checked lazily in call_bedrock

[[ -f "$ENDPOINTS_FILE" ]] || { echo "ERROR: endpoints file not found: ${ENDPOINTS_FILE} (copy bench_endpoints.example.json and edit it)" >&2; exit 1; }
[[ -f "$PROMPTS_FILE" ]]   || { echo "ERROR: prompts file not found: ${PROMPTS_FILE}" >&2; exit 1; }

mkdir -p "$RESULTS_DIR"
if [[ ! -f "$OUTPUT_CSV" ]]; then
  echo "timestamp_utc,run_id,endpoint_name,api_style,model,instance_label,prompt_id,rep,temperature,seed,num_predict,http_status,wall_clock_s,ttft_s,prompt_tokens,completion_tokens,tokens_per_sec,load_duration_s,error" > "$OUTPUT_CSV"
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

# Load prompts: one per non-empty, non-comment line.
PROMPTS=()
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  PROMPTS+=("$line")
done < "$PROMPTS_FILE"

if [[ ${#PROMPTS[@]} -eq 0 ]]; then
  echo "ERROR: no prompts loaded from ${PROMPTS_FILE}" >&2
  exit 1
fi

# Request helpers echo: http_status|wall_clock_s|prompt_tokens|completion_tokens|tokens_per_sec|load_duration_s|error
call_ollama() {
  local base_url="$1" model="$2" prompt="$3"
  local body_file http_code wall_clock_s body
  body_file=$(mktemp)

  local payload
  payload=$(jq -n --arg model "$model" --arg prompt "$prompt" \
    --argjson temperature "$TEMPERATURE" --argjson seed "$SEED" --argjson num_predict "$NUM_PREDICT" \
    '{model:$model, prompt:$prompt, stream:false, options:{temperature:$temperature, seed:$seed, num_predict:$num_predict}}')

  local curl_output
  # || true: curl still prints its -w output on connection failure
  curl_output=$(curl -sS -m "$REQUEST_TIMEOUT_S" -o "$body_file" -w '%{http_code} %{time_total}' \
    -X POST "${base_url}/api/generate" -H "Content-Type: application/json" -d "$payload" 2>/dev/null || true)
  if [[ -z "$curl_output" ]]; then
    http_code="000"; wall_clock_s="0"
  else
    read -r http_code wall_clock_s <<< "$curl_output"
  fi

  body=$(cat "$body_file"); rm -f "$body_file"

  if [[ "$http_code" == "200" ]]; then
    local eval_count eval_duration_ns load_duration_ns prompt_eval_count tokens_per_sec load_duration_s
    eval_count=$(echo "$body" | jq -r '.eval_count // 0')
    eval_duration_ns=$(echo "$body" | jq -r '.eval_duration // 0')
    load_duration_ns=$(echo "$body" | jq -r '.load_duration // 0')
    prompt_eval_count=$(echo "$body" | jq -r '.prompt_eval_count // 0')
    load_duration_s=$(awk -v d="$load_duration_ns" 'BEGIN { printf "%.4f", d / 1000000000 }')
    if [[ "$eval_duration_ns" -gt 0 ]]; then
      tokens_per_sec=$(awk -v c="$eval_count" -v d="$eval_duration_ns" 'BEGIN { printf "%.2f", c / (d / 1000000000) }')
    else
      tokens_per_sec="0"
    fi
    echo "${http_code}|${wall_clock_s}|${prompt_eval_count}|${eval_count}|${tokens_per_sec}|${load_duration_s}|"
  else
    local err
    err=$(echo "$body" | jq -r '.error // "request failed"' 2>/dev/null | tr ',|\n' ' ')
    echo "${http_code}|${wall_clock_s}|0|0|0|0|${err:-request failed}"
  fi
}

call_openai() {
  local base_url="$1" model="$2" prompt="$3" api_key_env="$4"
  local body_file http_code wall_clock_s body api_key
  body_file=$(mktemp)

  local payload
  payload=$(jq -n --arg model "$model" --arg prompt "$prompt" \
    --argjson temperature "$TEMPERATURE" --argjson seed "$SEED" --argjson max_tokens "$NUM_PREDICT" \
    '{model:$model, messages:[{role:"user", content:$prompt}], temperature:$temperature, seed:$seed, max_tokens:$max_tokens}')

  local curl_args=(-sS -m "$REQUEST_TIMEOUT_S" -o "$body_file" -w '%{http_code} %{time_total}' \
    -X POST "${base_url}/v1/chat/completions" -H "Content-Type: application/json")
  if [[ -n "$api_key_env" ]]; then
    api_key="${!api_key_env:-}"
    [[ -n "$api_key" ]] && curl_args+=(-H "Authorization: Bearer ${api_key}")
  fi
  curl_args+=(-d "$payload")

  local curl_output
  curl_output=$(curl "${curl_args[@]}" 2>/dev/null || true)
  if [[ -z "$curl_output" ]]; then
    http_code="000"; wall_clock_s="0"
  else
    read -r http_code wall_clock_s <<< "$curl_output"
  fi

  body=$(cat "$body_file"); rm -f "$body_file"

  if [[ "$http_code" == "200" ]]; then
    local prompt_tokens completion_tokens tokens_per_sec
    prompt_tokens=$(echo "$body" | jq -r '.usage.prompt_tokens // 0')
    completion_tokens=$(echo "$body" | jq -r '.usage.completion_tokens // 0')
    if awk -v w="$wall_clock_s" 'BEGIN { exit !(w > 0) }'; then
      tokens_per_sec=$(awk -v c="$completion_tokens" -v w="$wall_clock_s" 'BEGIN { printf "%.2f", c / w }')
    else
      tokens_per_sec="0"
    fi
    echo "${http_code}|${wall_clock_s}|${prompt_tokens}|${completion_tokens}|${tokens_per_sec}|n/a|"
  else
    local err
    err=$(echo "$body" | jq -r '.error.message // "request failed"' 2>/dev/null | tr ',|\n' ' ')
    echo "${http_code}|${wall_clock_s}|0|0|0|n/a|${err:-request failed}"
  fi
}

call_bedrock() {
  local model="$1" prompt="$2" region="$3" aws_profile="$4"

  if ! command -v aws >/dev/null 2>&1; then
    echo "ERR|0|0|0|0|n/a|aws CLI not found on PATH (required for api_style bedrock)"
    return
  fi
  if [[ -z "$region" ]]; then
    echo "ERR|0|0|0|0|n/a|endpoint is missing required 'region' field for api_style bedrock"
    return
  fi

  local messages_file inference_file out_file err_file start_s end_s wall_clock_s
  messages_file=$(mktemp); inference_file=$(mktemp); out_file=$(mktemp); err_file=$(mktemp)

  jq -n --arg prompt "$prompt" '[{role:"user", content:[{text:$prompt}]}]' > "$messages_file"
  jq -n --argjson max_tokens "$NUM_PREDICT" --argjson temperature "$TEMPERATURE" \
    '{maxTokens:$max_tokens, temperature:$temperature}' > "$inference_file"
  # Converse has no seed param; SEED is only recorded.

  local aws_args=(bedrock-runtime converse --region "$region" --model-id "$model"
    --messages "file://${messages_file}" --inference-config "file://${inference_file}" --output json)
  [[ -n "$aws_profile" ]] && aws_args+=(--profile "$aws_profile")

  start_s=$(date +%s.%N)
  if aws "${aws_args[@]}" >"$out_file" 2>"$err_file"; then
    end_s=$(date +%s.%N)
    wall_clock_s=$(awk -v s="$start_s" -v e="$end_s" 'BEGIN { printf "%.3f", e - s }')

    local prompt_tokens completion_tokens tokens_per_sec
    prompt_tokens=$(jq -r '.usage.inputTokens // 0' "$out_file")
    completion_tokens=$(jq -r '.usage.outputTokens // 0' "$out_file")
    if awk -v w="$wall_clock_s" 'BEGIN { exit !(w > 0) }'; then
      tokens_per_sec=$(awk -v c="$completion_tokens" -v w="$wall_clock_s" 'BEGIN { printf "%.2f", c / w }')
    else
      tokens_per_sec="0"
    fi
    rm -f "$messages_file" "$inference_file" "$out_file" "$err_file"
    echo "200|${wall_clock_s}|${prompt_tokens}|${completion_tokens}|${tokens_per_sec}|n/a|"
  else
    end_s=$(date +%s.%N)
    wall_clock_s=$(awk -v s="$start_s" -v e="$end_s" 'BEGIN { printf "%.3f", e - s }')
    local err
    err=$(tr ',|\n' ' ' < "$err_file" | cut -c1-300)
    rm -f "$messages_file" "$inference_file" "$out_file" "$err_file"
    echo "ERR|${wall_clock_s}|0|0|0|n/a|${err:-request failed}"
  fi
}

# --- main: endpoints x prompts x (warm-up + REPS) ---
while IFS= read -r endpoint_json; do
  name=$(echo "$endpoint_json" | jq -r '.name')
  base_url=$(echo "$endpoint_json" | jq -r '.base_url')
  api_style=$(echo "$endpoint_json" | jq -r '.api_style')
  model=$(echo "$endpoint_json" | jq -r '.model')
  api_key_env=$(echo "$endpoint_json" | jq -r '.api_key_env // empty')
  region=$(echo "$endpoint_json" | jq -r '.region // empty')
  aws_profile=$(echo "$endpoint_json" | jq -r '.aws_profile // empty')

  echo "=== ${name} (${api_style}, model=${model}) ==="

  for i in "${!PROMPTS[@]}"; do
    prompt_id="p$((i + 1))"
    prompt="${PROMPTS[$i]}"

    for ((w = 0; w < WARMUP_REPS; w++)); do
      echo "  [${prompt_id}] warm-up $((w + 1))/${WARMUP_REPS}..."
      case "$api_style" in
        ollama) call_ollama "$base_url" "$model" "$prompt" >/dev/null ;;
        openai) call_openai "$base_url" "$model" "$prompt" "$api_key_env" >/dev/null ;;
        bedrock) call_bedrock "$model" "$prompt" "$region" "$aws_profile" >/dev/null ;;
        *) echo "ERROR: unknown api_style '${api_style}' for endpoint '${name}' (expected ollama|openai|bedrock)" >&2; exit 1 ;;
      esac
    done

    for ((r = 1; r <= REPS; r++)); do
      echo "  [${prompt_id}] rep ${r}/${REPS}..."
      result_line=""
      case "$api_style" in
        ollama) result_line=$(call_ollama "$base_url" "$model" "$prompt") ;;
        openai) result_line=$(call_openai "$base_url" "$model" "$prompt" "$api_key_env") ;;
        bedrock) result_line=$(call_bedrock "$model" "$prompt" "$region" "$aws_profile") ;;
      esac

      IFS='|' read -r http_status wall_clock_s prompt_tokens completion_tokens tokens_per_sec load_duration_s error <<< "$result_line"
      timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

      echo "${timestamp_utc},${RUN_ID},${name},${api_style},${model},${INSTANCE_LABEL},${prompt_id},${r},${TEMPERATURE},${SEED},${NUM_PREDICT},${http_status},${wall_clock_s},,${prompt_tokens},${completion_tokens},${tokens_per_sec},${load_duration_s},${error}" >> "$OUTPUT_CSV"

      if [[ "$http_status" != "200" ]]; then
        echo "    WARNING: request failed (http ${http_status}): ${error}" >&2
      fi
    done
  done
done < <(jq -c '.[]' "$ENDPOINTS_FILE")

echo
echo "Done. Results appended to: ${OUTPUT_CSV}"
echo "Run ID for this invocation: ${RUN_ID}"
