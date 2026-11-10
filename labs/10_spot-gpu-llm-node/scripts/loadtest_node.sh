#!/bin/bash
# lab02 - fixed LLM workload via lab02-meter, recorded as a lab02-metrics run: ./lab02.sh loadtest <label> <model> [conc] [tokens] [short|long]
set -euo pipefail
LABEL="${1:?label}"; MODEL="${2:?model}"; CONC="${3:-2}"; NPRED="${4:-400}"; SET="${5:-short}"
URL="http://${METER_LISTEN:-127.0.0.1:18080}/api/generate"
export HOME="${HOME:-/root}"

PROMPTS=(
  "A web service returns HTTP 502 for 3% of requests right after a deploy. Nginx logs show 'upstream prematurely closed connection'. List the five most likely root causes, ordered by probability, and how to verify each one."
  "Summarize the incident in these logs and name the root cause: 12:00:01 app=api level=INFO msg=deploy v2.4.1 started; 12:00:40 app=api level=WARN msg=db pool exhausted size=20 waiting=57; 12:00:41 app=api level=ERROR msg=timeout acquiring connection 5000ms; 12:01:05 app=db level=WARN msg=too many connections 500/500; 12:01:30 app=api level=ERROR msg=request failed status=503; 12:02:10 app=api level=INFO msg=rollback to v2.4.0; 12:02:55 app=db level=INFO msg=connections 180/500."
  "A spot GPU node costs 1.55 USD per hour and generates 60 tokens per second per request with 2 requests in parallel. How many million output tokens per dollar is that, and how does it change at 10 tokens per second? Show the calculation step by step."
)

# long set: ~1.5k-token Terraform inputs; unique first line per request defeats the prefix cache
tf_doc() {  # variant
  local v="$1" i
  echo "File: modules/service_${v}/main.tf"
  for i in 1 2 3 4 5 6; do cat <<TF
resource "aws_security_group" "svc_${v}_${i}" {
  name        = "\${var.env}-svc-${v}-${i}-sg"
  description = "Service ${v} tier ${i} security group"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = $((8000 + i))
    to_port         = $((8000 + i))
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_${v}.id]
    description     = "ALB to service ${v} port $((8000 + i))"
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(var.shared_tags, { Name = "\${var.env}-svc-${v}-${i}", tier = "${i}" })
}
resource "aws_iam_role_policy" "svc_${v}_${i}_s3" {
  name   = "svc-${v}-${i}-s3"
  role   = aws_iam_role.svc_${v}.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow",
    Action = ["s3:GetObject", "s3:PutObject"], Resource = ["arn:aws:s3:::\${var.bucket}/svc-${v}/${i}/*"] }] })
}
TF
  done
}

if [[ "$SET" == "long" ]]; then
  PROMPTS=()
  for v in alpha beta gamma; do
    PROMPTS+=("Summarize this Terraform file for a knowledge base entry: purpose, resources created, inputs, security-relevant settings and risks. Under 250 words.
$(tf_doc "$v")")
  done
fi
N=0

req() {  # prompt
  N=$((N + 1))
  jq -n --arg m "$MODEL" --arg p "req ${N}-$(date +%s%N)-${BASHPID}
$1" --argjson n "$NPRED" \
    '{model:$m, prompt:$p, stream:true, options:{temperature:0, seed:42, num_predict:$n}}' \
    | curl -s -m 1800 "$URL" -d @- > /dev/null
}

echo "[loadtest] warm-up ${MODEL}..."
jq -n --arg m "$MODEL" '{model:$m, prompt:"hi", stream:false, options:{num_predict:1}}' | curl -s -m 900 "$URL" -d @- > /dev/null

lab02-metrics start "$LABEL" 1 > /dev/null
echo "[loadtest] ${LABEL}: prompt set ${SET}, 3 sequential"
for p in "${PROMPTS[@]}"; do req "$p"; done
echo "[loadtest] ${LABEL}: 2 rounds x ${CONC} parallel"
for round in 1 2; do
  for ((i = 0; i < CONC; i++)); do req "${PROMPTS[$(( (round + i) % ${#PROMPTS[@]} ))]}" & done
  wait
done
sleep 2
echo "[loadtest] ollama ps at end:"; ollama ps | tail -n +2
lab02-metrics stop 2>/dev/null | jq -c '{run, model: "'"$MODEL"'",
  reqs: .requests.requests, failed: .requests.failed,
  gen_tps_p50: .requests.gen_tps_p50, gen_tps_p05: .requests.gen_tps_p05,
  ttft_p50_s: .requests.ttft_p50_s, lat_p95_s: .requests.latency_p95_s,
  throughput_tps: .requests.throughput_completion_tps, peak_tps: .load.completion_tps_peak,
  gpu_util_avg: .load.gpu_util_avg, vram_max_mib: .load.gpu_mem_max_mib, cpu_util_avg: .load.cpu_util_avg}'
