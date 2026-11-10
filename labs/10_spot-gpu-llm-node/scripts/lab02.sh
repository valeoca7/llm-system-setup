#!/bin/bash
# lab02 - local control CLI for one spot GPU LLM node (AL2023 + Ollama), AWS API + SSM only; ./lab02.sh help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${LAB02_VALUES:-${SCRIPT_DIR}/values.export}"
# shellcheck disable=SC1090
[[ -f "$VALUES_FILE" ]] && source "$VALUES_FILE"

# --- config (defaults mirror values.export) ---
AWS_REGION="${AWS_REGION:-us-west-2}"
AWS_PROFILE="${AWS_PROFILE:-default}"

SUBNET_MAP="${SUBNET_MAP:-}"                               # "az=subnet-id ...", see values.export
LAUNCH_AZS="${LAUNCH_AZS:-}"                               # empty = every AZ in SUBNET_MAP, in map order
SUBNET_ID="${SUBNET_ID:-}"                                 # legacy pin: set = only this subnet is tried
LAUNCH_ROUNDS="${LAUNCH_ROUNDS:-3}"                        # passes over all AZs before giving up
LAUNCH_RETRY_DELAY_S="${LAUNCH_RETRY_DELAY_S:-30}"         # pause between passes
SECURITY_GROUP_ID="${SECURITY_GROUP_ID:-}"                 # empty = look up SECURITY_GROUP_NAME
SECURITY_GROUP_NAME="${SECURITY_GROUP_NAME:-lab02-serving-host}"
IAM_INSTANCE_PROFILE="${IAM_INSTANCE_PROFILE:-}"
KEY_NAME="${KEY_NAME:-}"                                   # optional, SSM needs none

INSTANCE_TYPE="${INSTANCE_TYPE:-g7e.8xlarge}"
INSTANCE_NAME="${INSTANCE_NAME:-lab02-llm}"
PROJECT_TAG="${PROJECT_TAG:-lab02}"
AMI_ID="${AMI_ID:-}"                                       # empty = latest base AL2023 (bake flow)
BASE_AMI_SSM_PARAM="${BASE_AMI_SSM_PARAM:-/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64}"
ROOT_VOLUME_GB="${ROOT_VOLUME_GB:-30}"                     # OS + driver + Ollama only; models on NVMe
MAX_SPOT_PRICE="${MAX_SPOT_PRICE:-2.50}"                   # empty = capped at on-demand price
TTL_HOURS="${TTL_HOURS:-8}"                                # node powers off (= terminates) after this; 0 = off

S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-lab02}"

MODELS="${MODELS:-gpt-oss:20b}"
OLLAMA_VERSION="${OLLAMA_VERSION:-}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-4}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-2}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-65536}"
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-}"                # "" = f16, q8_0 = half KV memory
OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"           # required for a quantized KV cache
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"
TEST_PROMPT="${TEST_PROMPT:-Explain what a spot instance is, in two sentences.}"

METER_PORT="${METER_PORT:-18080}"                          # lab02-meter proxy on the node (node_metering.sh)
TUNNEL_TARGET="${TUNNEL_TARGET:-meter}"                    # meter = metered (default) | backend = Ollama port directly
NODE_SCRIPTS="provision_node.sh node_tools.sh node_metering.sh loadtest_node.sh"
SET_ENV_KEYS="OLLAMA_CONTEXT_LENGTH OLLAMA_NUM_PARALLEL OLLAMA_KV_CACHE_TYPE OLLAMA_MAX_LOADED_MODELS OLLAMA_KEEP_ALIVE OLLAMA_FLASH_ATTENTION"
LOCAL_PORT="${LOCAL_PORT:-21434}"                          # not 11434 - avoids clashing with a local Ollama
PROVISION_TIMEOUT_S="${PROVISION_TIMEOUT_S:-7200}"
READY_TIMEOUT_S="${READY_TIMEOUT_S:-1800}"
SSM_OUTPUT_LINES="${SSM_OUTPUT_LINES:-80}"
DRY_RUN="${DRY_RUN:-0}"                                    # 1 = run-instances --dry-run only
FORCE="${FORCE:-0}"                                        # 1 = skip confirmations

NODE_SCRIPTS_S3="s3://${S3_BUCKET}/${S3_PREFIX}/scripts"

# --- helpers ---
TMP_FILES=()
cleanup() { [[ ${#TMP_FILES[@]} -eq 0 ]] || rm -rf "${TMP_FILES[@]}"; }
trap cleanup EXIT

aws_cli() { aws --region "$AWS_REGION" --profile "$AWS_PROFILE" "$@"; }
log() { echo "$*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_tools() {
  local t
  for t in aws jq "$@"; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is required on PATH"
  done
}

require_config() {
  local v missing=""
  for v in "$@"; do [[ -n "${!v}" ]] || missing+=" ${v}"; done
  [[ -z "$missing" ]] || die "not set (values.export or env):${missing}"
}

confirm() {
  [[ "$FORCE" == "1" ]] && return 0
  local answer
  read -r -p "$1 [y/N] " answer </dev/tty
  [[ "$answer" == "y" || "$answer" == "Y" ]]
}

# Echoes the id of the live lab02 instance (by Name tag), or nothing.
find_instance_id() {
  aws_cli ec2 describe-instances \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[] | sort_by(@, &LaunchTime)[-1].InstanceId' --output text
}

require_instance() {
  INSTANCE_ID="${INSTANCE_ID:-$(find_instance_id)}"
  [[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || die "no live instance named ${INSTANCE_NAME} (run: $0 launch)"
}

# Echoes "az subnet" lines to try, in order.
launch_plan() {
  local pair az
  [[ -n "${SUBNET_ID}${SUBNET_MAP}" ]] || die "not set (values.export or env): SUBNET_MAP or SUBNET_ID"
  if [[ -n "$SUBNET_ID" ]]; then
    az=$(aws_cli ec2 describe-subnets --subnet-ids "$SUBNET_ID" --query 'Subnets[0].AvailabilityZone' --output text)
    echo "$az $SUBNET_ID"
    return
  fi
  if [[ -z "$LAUNCH_AZS" ]]; then
    for pair in $SUBNET_MAP; do echo "${pair%%=*} ${pair#*=}"; done
    return
  fi
  for az in $LAUNCH_AZS; do
    for pair in $SUBNET_MAP; do
      [[ "${pair%%=*}" == "$az" ]] && { echo "$az ${pair#*=}"; continue 2; }
    done
    die "AZ ${az} (LAUNCH_AZS) has no subnet in SUBNET_MAP"
  done
}

first_subnet() { launch_plan | awk 'NR==1 {print $2}'; }

# Current spot price of INSTANCE_TYPE in one AZ, or empty if the AZ does not offer it.
current_spot_price() {
  aws_cli ec2 describe-spot-price-history --instance-types "$INSTANCE_TYPE" --product-descriptions Linux/UNIX \
    --availability-zone "$1" --start-time "$(date -u +%Y-%m-%dT%H:%M:%S)" \
    --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null | grep -v None || true
}

price_above_cap() {
  [[ -n "$MAX_SPOT_PRICE" && -n "$1" ]] && awk -v p="$1" -v c="$MAX_SPOT_PRICE" 'BEGIN { exit !(p > c) }'
}

resolve_security_group() {
  if [[ -n "$SECURITY_GROUP_ID" ]]; then echo "$SECURITY_GROUP_ID"; return; fi
  local vpc_id sg
  vpc_id=$(aws_cli ec2 describe-subnets --subnet-ids "$(first_subnet)" --query 'Subnets[0].VpcId' --output text)
  sg=$(aws_cli ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" "Name=group-name,Values=${SECURITY_GROUP_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text)
  [[ -n "$sg" && "$sg" != "None" ]] || die "security group ${SECURITY_GROUP_NAME} not found in ${vpc_id} (set SECURITY_GROUP_ID)"
  echo "$sg"
}

resolve_ami() {
  if [[ -n "$AMI_ID" ]]; then echo "$AMI_ID"; return; fi
  aws_cli ssm get-parameter --name "$BASE_AMI_SSM_PARAM" --query 'Parameter.Value' --output text
}

wait_ssm_online() {
  local i ping
  log "Waiting for the SSM agent to come online..."
  for ((i = 0; i < 60; i++)); do
    ping=$(aws_cli ssm describe-instance-information --filters "Key=InstanceIds,Values=${INSTANCE_ID}" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)
    if [[ "$ping" == "Online" ]]; then log "SSM: Online"; return 0; fi
    sleep 10
  done
  die "SSM agent not online after 10 min - check the instance profile has AmazonSSMManagedInstanceCore and the subnet has an internet route"
}

# Uploads node scripts to S3; prints "sha256 name" lines for user-data.
upload_node_scripts() {
  local f
  for f in $NODE_SCRIPTS; do
    aws_cli s3 cp "${SCRIPT_DIR}/${f}" "${NODE_SCRIPTS_S3}/${f}" --only-show-errors >&2
    echo "$(shasum -a 256 "${SCRIPT_DIR}/${f}" | awk '{print $1}') ${f}"
  done
}

# Shell lines that fetch the node scripts from S3 into /opt/lab02 (used by provision/set-env).
fetch_node_scripts_cmd() {
  local f
  echo "mkdir -p /opt/lab02"
  for f in $NODE_SCRIPTS; do
    echo "aws s3 cp ${NODE_SCRIPTS_S3}/${f} /opt/lab02/${f} --region ${AWS_REGION} --only-show-errors"
  done
  echo "chmod 755 /opt/lab02/*.sh"
}

instance_alive() {
  local st
  st=$(aws_cli ec2 describe-instances --instance-ids "$1" --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo unknown)
  [[ "$st" == "running" || "$st" == "pending" ]]
}

# Human-readable reason an instance stopped: EC2 state reason + spot request status.
termination_reason() {
  local reason spot
  reason=$(aws_cli ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].[State.Name,StateReason.Message,StateTransitionReason]' --output text 2>/dev/null | tr '\t' ' ')
  spot=$(aws_cli ec2 describe-spot-instance-requests --filters "Name=instance-id,Values=$1" \
    --query 'SpotInstanceRequests[0].Status.[Code,Message]' --output text 2>/dev/null | tr '\t' ' ' | grep -v '^None' || true)
  echo "${reason}${spot:+ | spot: ${spot}}"
}

# Runs a script on the node as root via SSM; full output in S3 ssm-logs/, SSM_QUIET=1 = stdout only.
ssm_run() {
  local script="$1" timeout_s="${2:-600}" comment="${3:-lab02}"
  local params cmd_id status last="" result out err polls=0
  # SSM RunShellScript starts without HOME - the ollama CLI (and aws cli config) panic/fail without it.
  script="export HOME=\${HOME:-/root}
${script}"
  params=$(jq -n --arg c "$script" --arg t "$timeout_s" '{commands: ($c | split("\n")), executionTimeout: [$t]}')
  cmd_id=$(aws_cli ssm send-command \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --comment "${comment:0:100}" \
    --parameters "$params" \
    --output-s3-bucket-name "$S3_BUCKET" \
    --output-s3-key-prefix "${S3_PREFIX}/ssm-logs" \
    --query 'Command.CommandId' --output text)
  [[ "${SSM_QUIET:-0}" == "1" ]] || log "SSM command ${cmd_id} (${comment})"

  while true; do
    status=$(aws_cli ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    if [[ "$status" != "$last" && "${SSM_QUIET:-0}" != "1" ]]; then log "  status: ${status}"; fi
    last="$status"
    case "$status" in Success|Failed|Cancelled|TimedOut) break ;; esac
    # instance gone (spot interruption / TTL / terminate) -> SSM would report InProgress until timeout
    if (( ++polls % 6 == 0 )) && ! instance_alive "$INSTANCE_ID"; then
      log "  instance ${INSTANCE_ID} is no longer running - $(termination_reason "$INSTANCE_ID")"
      return 1
    fi
    sleep 5
  done

  result=$(aws_cli ssm get-command-invocation --command-id "$cmd_id" --instance-id "$INSTANCE_ID" --output json)
  out=$(jq -r '.StandardOutputContent' <<<"$result")
  err=$(jq -r '.StandardErrorContent' <<<"$result")
  if [[ "${SSM_QUIET:-0}" == "1" ]]; then
    echo "$out"
  else
    echo "$out" | tail -n "$SSM_OUTPUT_LINES"
    [[ -n "$err" ]] && { log "--- stderr (tail) ---"; echo "$err" | tail -n 20 >&2; }
    log "Full output: s3://${S3_BUCKET}/${S3_PREFIX}/ssm-logs/${cmd_id}/${INSTANCE_ID}/awsrunShellScript/"
  fi
  [[ "$status" == "Success" ]]
}

# user-data: node config, TTL watchdog, spot watcher, script refresh, boot service start.
render_user_data() {
  cat <<EOF
#!/bin/bash
# lab02 user-data - rendered by lab02.sh launch
set -u
mkdir -p /etc/lab02
cat > /etc/lab02/node.env <<'ENVEOF'
$(for v in AWS_REGION S3_BUCKET S3_PREFIX MODELS OLLAMA_VERSION OLLAMA_PORT OLLAMA_NUM_PARALLEL \
           OLLAMA_MAX_LOADED_MODELS OLLAMA_CONTEXT_LENGTH OLLAMA_KV_CACHE_TYPE OLLAMA_FLASH_ATTENTION OLLAMA_KEEP_ALIVE TEST_PROMPT; do
    printf '%s=%q\n' "$v" "${!v}"
  done)
ENVEOF
EOF
  if [[ "$TTL_HOURS" != "0" ]]; then
    echo "echo \$(( \$(date +%s) + ${TTL_HOURS} * 3600 )) > /etc/lab02/deadline"
  fi
  printf "cat > /etc/lab02/scripts.sha256 <<'SHAEOF'\n%s\nSHAEOF\n" "${NODE_SCRIPTS_SHA:-}"
  cat <<'EOF'

# Prefer IPv4: subnets with DNS64 but no NAT64 resolve IPv4-only S3/STS to dead 64:ff9b:: addresses.
grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

# TTL watchdog: deadline file checked every 5 min; poweroff = terminate for one-time spot.
cat > /usr/local/sbin/lab02-ttl-check <<'TTLEOF'
#!/bin/bash
f=/etc/lab02/deadline
[ -f "$f" ] || exit 0
if [ "$(date +%s)" -ge "$(cat "$f")" ]; then
  logger -t lab02-ttl "deadline reached - powering off"
  systemctl poweroff
fi
TTLEOF
chmod 755 /usr/local/sbin/lab02-ttl-check
cat > /etc/systemd/system/lab02-ttl.service <<'UNITEOF'
[Unit]
Description=lab02 TTL deadline check
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/lab02-ttl-check
UNITEOF
cat > /etc/systemd/system/lab02-ttl.timer <<'UNITEOF'
[Unit]
Description=lab02 TTL deadline check every 5 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
[Install]
WantedBy=timers.target
UNITEOF

# Spot watcher (IMDSv2, 5s): rebalance -> log; interruption -> save models to S3, upload node log.
cat > /usr/local/sbin/lab02-spot-watch <<'SPOTEOF'
#!/bin/bash
set -u
export HOME=/root
[ -f /etc/lab02/node.env ] && { set -a; . /etc/lab02/node.env; set +a; }
MD=http://169.254.169.254/latest
LOG=/var/log/lab02-node.log
note() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] SPOT: $*" | tee -a "$LOG" | logger -t lab02-spot; }
token=""; token_at=0; rebalance_seen=0
while true; do
  now=$(date +%s)
  if [ $((now - token_at)) -gt 18000 ] || [ -z "$token" ]; then
    token=$(curl -s -m 2 -X PUT "$MD/api/token" -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600'); token_at=$now
  fi
  if [ "$rebalance_seen" = 0 ]; then
    r=$(curl -s -m 2 -f -H "X-aws-ec2-metadata-token: $token" "$MD/meta-data/events/recommendations/rebalance" || true)
    if [ -n "$r" ]; then note "rebalance recommendation (elevated interruption risk): $r"; rebalance_seen=1; fi
  fi
  a=$(curl -s -m 2 -f -H "X-aws-ec2-metadata-token: $token" "$MD/meta-data/spot/instance-action" || true)
  if [ -n "$a" ]; then
    note "INTERRUPTION NOTICE: $a"
    mkdir -p /run/lab02; echo interrupting > /run/lab02/status; echo "$a" > /run/lab02/spot-interruption
    iid=$(curl -s -m 2 -H "X-aws-ec2-metadata-token: $token" "$MD/meta-data/instance-id")
    if [ -n "${S3_BUCKET:-}" ] && [ -d /data/ollama-models ]; then
      note "saving completed models to s3://$S3_BUCKET/${S3_PREFIX:-lab02}/models/ollama/ (<=100s)"
      timeout 100 aws s3 sync /data/ollama-models/ "s3://$S3_BUCKET/${S3_PREFIX:-lab02}/models/ollama/" \
        --region "${AWS_REGION:-us-west-2}" --only-show-errors --exclude '*-partial*' \
        && note "models saved" || note "model save incomplete (timeout/error) - next boot pulls what is missing"
    fi
    if [ -n "${S3_BUCKET:-}" ]; then
      timeout 10 aws s3 cp "$LOG" "s3://$S3_BUCKET/${S3_PREFIX:-lab02}/node-logs/$(date -u +%Y%m%dT%H%M%SZ)-${iid}.log" \
        --region "${AWS_REGION:-us-west-2}" --only-show-errors || true
    fi
    note "done - waiting for termination"
    sleep infinity
  fi
  sleep 5
done
SPOTEOF
chmod 755 /usr/local/sbin/lab02-spot-watch
cat > /etc/systemd/system/lab02-spot-watch.service <<'UNITEOF'
[Unit]
Description=lab02 spot interruption watcher (IMDS instance-action / rebalance)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/sbin/lab02-spot-watch
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now lab02-ttl.timer lab02-spot-watch.service

# Install node scripts from S3 only if sha256 matches the launch-time value.
export HOME=/root
set -a; . /etc/lab02/node.env; set +a
mkdir -p /opt/lab02 /tmp/lab02-dl
while read -r sum name; do
  [ -n "$name" ] || continue
  if aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/scripts/${name}" "/tmp/lab02-dl/${name}" --region "$AWS_REGION" --only-show-errors \
     && echo "${sum}  /tmp/lab02-dl/${name}" | sha256sum -c --status; then
    install -m 755 "/tmp/lab02-dl/${name}" "/opt/lab02/${name}" && logger -t lab02 "script updated: ${name}"
  else
    logger -t lab02 "WARN: ${name} not updated (download failed or sha256 mismatch) - keeping existing copy"
  fi
done < /etc/lab02/scripts.sha256
rm -rf /tmp/lab02-dl

# Baked AMI: metering proxy (current version) + boot service -> mount NVMe, restore models, serve.
if [ -f /etc/systemd/system/lab02-boot.service ]; then
  [ -f /opt/lab02/node_metering.sh ] && bash /opt/lab02/node_metering.sh > /var/log/lab02-metering-install.log 2>&1
  systemctl start --no-block lab02-boot.service
fi
EOF
}

# --- subcommands ---
cmd_launch() {
  local existing sg ami root_dev user_data_file market bdm plan
  require_config IAM_INSTANCE_PROFILE
  existing=$(find_instance_id)
  [[ -z "$existing" || "$existing" == "None" ]] || die "instance ${existing} (${INSTANCE_NAME}) is already live - terminate it first or set INSTANCE_NAME"

  plan=$(launch_plan)
  sg=$(resolve_security_group)
  ami=$(resolve_ami)
  root_dev=$(aws_cli ec2 describe-images --image-ids "$ami" --query 'Images[0].RootDeviceName' --output text)

  log "Uploading node scripts to ${NODE_SCRIPTS_S3}/ (user-data installs them if sha256 matches)"
  NODE_SCRIPTS_SHA=$(upload_node_scripts)
  user_data_file=$(mktemp)
  TMP_FILES+=("$user_data_file")
  render_user_data > "$user_data_file"

  market=$(jq -cn --arg p "$MAX_SPOT_PRICE" '{MarketType:"spot", SpotOptions:({SpotInstanceType:"one-time", InstanceInterruptionBehavior:"terminate"} + (if $p == "" then {} else {MaxPrice:$p} end))}')
  bdm=$(jq -cn --arg d "$root_dev" --argjson s "$ROOT_VOLUME_GB" '[{DeviceName:$d, Ebs:{VolumeSize:$s, VolumeType:"gp3", DeleteOnTermination:true, Encrypted:true}}]')

  log "Launching ${INSTANCE_TYPE} spot, cap \$${MAX_SPOT_PRICE:-on-demand}/h, AZs: $(echo "$plan" | awk '{print $1}' | tr '\n' ' ')"
  log "  AMI ${ami} ($([[ -n "$AMI_ID" ]] && echo baked || echo "base AL2023")), SG ${sg}, profile ${IAM_INSTANCE_PROFILE}, TTL ${TTL_HOURS}h"
  log "  models: ${MODELS}"

  # subnet is appended per attempt
  local args=(ec2 run-instances
    --image-id "$ami"
    --instance-type "$INSTANCE_TYPE"
    --security-group-ids "$sg"
    --associate-public-ip-address
    --iam-instance-profile "Name=${IAM_INSTANCE_PROFILE}"
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled,HttpPutResponseHopLimit=2"
    --block-device-mappings "$bdm"
    --instance-market-options "$market"
    --instance-initiated-shutdown-behavior terminate
    --user-data "file://${user_data_file}"
    --tag-specifications
      "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=project,Value=${PROJECT_TAG}}]"
      "ResourceType=volume,Tags=[{Key=Name,Value=${INSTANCE_NAME}-root},{Key=project,Value=${PROJECT_TAG}}]"
      "ResourceType=spot-instances-request,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=project,Value=${PROJECT_TAG}}]"
    --count 1
    --query 'Instances[0].InstanceId' --output text)
  [[ -n "$KEY_NAME" ]] && args+=(--key-name "$KEY_NAME")

  if [[ "$DRY_RUN" == "1" ]]; then
    local out
    out=$(aws_cli "${args[@]}" --subnet-id "$(first_subnet)" --dry-run 2>&1 || true)
    [[ "$out" == *DryRunOperation* ]] && { log "DRY RUN OK: request is valid and permitted (capacity/price not checked)."; return; }
    die "dry run failed: ${out}"
  fi

# Round-robin over AZs: capacity/price errors -> next AZ, others -> stop; this loop is the retry.
  local round az subnet price out skip=" "
  INSTANCE_ID=""
  for ((round = 1; round <= LAUNCH_ROUNDS; round++)); do
    while read -r az subnet; do
      [[ "$skip" == *" ${az} "* ]] && continue
      price=$(current_spot_price "$az")
      if [[ -z "$price" ]]; then
        log "  [${round}/${LAUNCH_ROUNDS}] ${az}: ${INSTANCE_TYPE} not offered - skipping this AZ"
        skip+="${az} "; continue
      fi
      if price_above_cap "$price"; then
        log "  [${round}/${LAUNCH_ROUNDS}] ${az}: spot \$${price} > cap \$${MAX_SPOT_PRICE} - skip"
        continue
      fi
      log "  [${round}/${LAUNCH_ROUNDS}] ${az} (${subnet}, spot \$${price}): requesting..."
      if out=$(AWS_MAX_ATTEMPTS=1 aws_cli "${args[@]}" --subnet-id "$subnet" 2>&1); then
        INSTANCE_ID="$out"
        log "  ${az}: fulfilled -> ${INSTANCE_ID}"
        break 2
      fi
      case "$out" in
        *InsufficientInstanceCapacity*|*InsufficientCapacity*|*SpotMaxPriceTooLow*|*InsufficientFreeAddressesInSubnet*)
          log "  ${az}: $(grep -oE '\(([A-Za-z]+)\)' <<<"$out" | head -1 | tr -d '()') - next AZ" ;;
        *Unsupported*)
          log "  ${az}: Unsupported - skipping this AZ"; skip+="${az} " ;;
        *) die "run-instances failed in ${az} (not a capacity error, stopping): ${out}" ;;
      esac
    done <<<"$plan"
    if ((round < LAUNCH_ROUNDS)); then
      log "  no capacity this pass - retrying in ${LAUNCH_RETRY_DELAY_S}s"
      sleep "$LAUNCH_RETRY_DELAY_S"
    fi
  done
  [[ -n "$INSTANCE_ID" ]] || die "no spot capacity for ${INSTANCE_TYPE} under \$${MAX_SPOT_PRICE:-on-demand}/h in any AZ after ${LAUNCH_ROUNDS} passes (try another INSTANCE_TYPE, a higher MAX_SPOT_PRICE, or later)"

  aws_cli ec2 wait instance-running --instance-ids "$INSTANCE_ID"
  wait_ssm_online
  cmd_status

  log ""
  if [[ -n "$AMI_ID" ]]; then
    log "Next: $0 wait-ready && $0 tunnel"
  else
    log "Next (bake flow): $0 provision    # live log in another terminal: $0 logs"
  fi
}

cmd_provision() {
  local step="${1:-all}"
  require_instance
  log "Uploading ${NODE_SCRIPTS} to ${NODE_SCRIPTS_S3}/"
  upload_node_scripts >/dev/null
  log "Running provision_node.sh ${step} on ${INSTANCE_ID} (may reboot once for the driver; live log: $0 logs)"
  [[ "$step" == "all" ]] && log "  'all' includes metering (lab02-meter/lab02-metrics) and tools (node_tools.sh)"
  # Re-fetched on every (re)run - also after the driver reboot (SSM exit 194 re-runs the command).
  ssm_run "export LAB02_SSM=1
$(fetch_node_scripts_cmd)
/opt/lab02/provision_node.sh ${step}" "$PROVISION_TIMEOUT_S" "lab02 provision ${step}"
}

cmd_wait_ready() {
  require_instance
  local start status
  start=$(date +%s)
  log "Waiting for node status 'ready' (NVMe mount + S3 model restore + GPU load)..."
  while true; do
    status=$(SSM_QUIET=1 ssm_run "cat /run/lab02/status 2>/dev/null || echo none" 60 "lab02 status" | tail -1 || true)
    log "  $(( $(date +%s) - start ))s: ${status:-unknown}"
    case "$status" in
      ready)  log "Node ready. Next: $0 tunnel"; return 0 ;;
      failed) die "node boot failed - see: $0 logs   (or $0 exec 'journalctl -u lab02-boot --no-pager | tail -50')" ;;
      interrupting) die "spot interruption notice received - node terminates in ~2 min: relaunch with: $0 launch" ;;
    esac
    (( $(date +%s) - start < READY_TIMEOUT_S )) || die "timed out after ${READY_TIMEOUT_S}s"
    sleep 15
  done
}

cmd_status() {
  local id
  id="${INSTANCE_ID:-$(find_instance_id)}"
  if [[ -z "$id" || "$id" == "None" ]]; then
    log "No live instance named ${INSTANCE_NAME}."
    id=$(aws_cli ec2 describe-instances --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
      --query 'Reservations[].Instances[] | sort_by(@, &LaunchTime)[-1].InstanceId' --output text 2>/dev/null || true)
    [[ -n "$id" && "$id" != "None" ]] && log "Last: ${id} - $(termination_reason "$id")"
    return 0
  fi
  aws_cli ec2 describe-instances --instance-ids "$id" --output table \
    --query 'Reservations[0].Instances[0].{Id:InstanceId,State:State.Name,Type:InstanceType,AZ:Placement.AvailabilityZone,PublicIp:PublicIpAddress,Ami:ImageId,Lifecycle:InstanceLifecycle,Launched:LaunchTime}'
  log "SSM ping: $(aws_cli ssm describe-instance-information --filters "Key=InstanceIds,Values=${id}" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || echo unknown)"
}

cmd_node_status() {
  require_instance
  SSM_QUIET=1 ssm_run "/opt/lab02/provision_node.sh status 2>/dev/null || cat /run/lab02/status 2>/dev/null || echo 'not provisioned'" 120 "lab02 node-status"
}

cmd_exec() {
  [[ $# -gt 0 ]] || die "usage: $0 exec '<shell command>'"
  require_instance
  ssm_run "$*" "${EXEC_TIMEOUT_S:-600}" "lab02 exec"
}

cmd_shell() {
  require_tools session-manager-plugin
  require_instance
  aws_cli ssm start-session --target "$INSTANCE_ID"
}

cmd_logs() {
  require_tools session-manager-plugin
  require_instance
  aws_cli ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartInteractiveCommand \
    --parameters '{"command":["sudo tail -n 200 -F /var/log/lab02-node.log"]}'
}

cmd_tunnel() {
  local lp="${1:-$LOCAL_PORT}"
  require_tools session-manager-plugin
  require_instance
  if lsof -nP -iTCP:"$lp" -sTCP:LISTEN >/dev/null 2>&1; then die "local port ${lp} is already in use"; fi
  local rp="$METER_PORT"
  [[ "$TUNNEL_TARGET" == "backend" ]] && rp="$OLLAMA_PORT"
  log "Tunnel localhost:${lp} -> ${INSTANCE_ID}:${rp} (${TUNNEL_TARGET}; Ctrl-C to close)"
  [[ "$TUNNEL_TARGET" == "meter" ]] && log "  metered via lab02-meter -> backend; unmetered: TUNNEL_TARGET=backend $0 tunnel"
  log "  Ollama API:        http://localhost:${lp}           (curl http://localhost:${lp}/api/tags)"
  log "  OpenAI-compatible: http://localhost:${lp}/v1        (OPENAI_BASE_URL, any OPENAI_API_KEY)"
  log "  Benchmark:         ./benchmark.sh bench_endpoints.json bench_prompts.txt ${INSTANCE_TYPE}-spot-${AWS_REGION}"
  aws_cli ssm start-session --target "$INSTANCE_ID" --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"${rp}\"],\"localPortNumber\":[\"${lp}\"]}"
}

cmd_set_models() {
  local list="${1:-}"
  [[ -n "$list" ]] || die "usage: $0 set-models '<model:tag> [model:tag ...]'"
  [[ "$list" =~ ^[A-Za-z0-9._:/,\ -]+$ ]] || die "unexpected characters in model list"
  require_instance
  local line
  line=$(printf 'MODELS=%q' "$list")
  log "Switching node models to: ${list} (restore from S3 or pull, then load)"
  ssm_run "sed -i '/^MODELS=/d' /etc/lab02/node.env
echo '${line}' >> /etc/lab02/node.env
/opt/lab02/provision_node.sh models
/opt/lab02/provision_node.sh warm" "$PROVISION_TIMEOUT_S" "lab02 set-models"
}

# Rewrites Ollama keys in node.env, restarts Ollama, reloads models.
cmd_set_env() {
  [[ $# -gt 0 ]] || die "usage: $0 set-env KEY=VALUE [KEY=VALUE ...]   keys: ${SET_ENV_KEYS}"
  require_instance
  local pair key val lines=""
  for pair in "$@"; do
    key="${pair%%=*}"; val="${pair#*=}"
    [[ "$pair" == *=* && " ${SET_ENV_KEYS} " == *" ${key} "* ]] || die "unsupported: ${pair} (keys: ${SET_ENV_KEYS})"
    [[ "$val" =~ ^[A-Za-z0-9._:/,\ -]*$ ]] || die "unexpected characters in ${key} value"
    lines+="sed -i '/^${key}=/d' /etc/lab02/node.env
echo '$(printf '%s=%q' "$key" "$val")' >> /etc/lab02/node.env
"
  done
  upload_node_scripts >/dev/null
  log "Applying on ${INSTANCE_ID}: $* (Ollama restarts, models reload)"
  ssm_run "$(fetch_node_scripts_cmd)
${lines}/opt/lab02/provision_node.sh serve
/opt/lab02/provision_node.sh warm
grep -E '^OLLAMA_' /etc/lab02/node.env
nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader" 1800 "lab02 set-env"
}

cmd_ttl() {
  local hours="${1:-}"
  [[ "$hours" =~ ^[0-9]+$ ]] || die "usage: $0 ttl <hours from now>   (0 = power off at next check)"
  require_instance
  ssm_run "mkdir -p /etc/lab02
echo \$(( \$(date +%s) + ${hours} * 3600 )) > /etc/lab02/deadline
echo \"deadline: \$(date -u -d @\$(cat /etc/lab02/deadline))\"" 60 "lab02 ttl"
}

cmd_hostbench() {
  local mode="${1:-quick}"
  require_instance
  log "Running lab02-hostbench ${mode} on ${INSTANCE_ID} (install first: exec \"\$(cat node_tools.sh)\")"
  SSM_OUTPUT_LINES=40 ssm_run "command -v lab02-hostbench >/dev/null || { echo 'lab02-hostbench missing - run node_tools.sh first'; exit 1; }
lab02-hostbench ${mode}" 3600 "lab02 hostbench ${mode}"
}

# Merges hostbench CSVs from HOSTBENCH_BUCKETS, adds current spot price and $/Mtok decode.
cmd_hostbench_report() {
  local buckets="${HOSTBENCH_BUCKETS:-$S3_BUCKET}"
  local out_csv="${SCRIPT_DIR}/../results/hostbench_all.csv" tmp b region f
  tmp=$(mktemp -d); TMP_FILES+=("$tmp")
  for b in $buckets; do
    region=$(aws_cli s3api get-bucket-location --bucket "$b" --query LocationConstraint --output text 2>/dev/null || true)
    [[ -z "$region" || "$region" == "None" ]] && region="us-east-1"
    aws --profile "$AWS_PROFILE" --region "$region" s3 cp "s3://${b}/${S3_PREFIX}/hostbench/" "${tmp}/${b}/" \
      --recursive --only-show-errors 2>/dev/null || true
  done
  mkdir -p "$(dirname "$out_csv")"
  local header="" row itype az rregion price key cost price_cache="${tmp}/prices.txt"
  : > "$out_csv"; : > "$price_cache"   # "type@az price" lines - bash 3.2 (macOS) has no assoc arrays
  while IFS= read -r f; do
    [[ -z "$header" ]] && { header=$(head -1 "$f"); echo "${header},spot_price_now,usd_per_mtok_decode" > "$out_csv"; }
    while IFS= read -r row; do
      itype=$(cut -d, -f3 <<<"$row"); az=$(cut -d, -f4 <<<"$row"); rregion="${az%[a-z]}"
      key="${itype}@${az}"
      if grep -q "^${key} " "$price_cache"; then
        price=$(awk -v k="$key" '$1 == k { print $2 }' "$price_cache")
      else
        price=$(aws --profile "$AWS_PROFILE" --region "$rregion" ec2 describe-spot-price-history \
          --instance-types "$itype" --product-descriptions Linux/UNIX --availability-zone "$az" \
          --start-time "$(date -u +%Y-%m-%dT%H:%M:%S)" --query 'SpotPriceHistory[0].SpotPrice' --output text 2>/dev/null | grep -v None || true)
        echo "${key} ${price}" >> "$price_cache"
      fi
      cost=$(awk -F, -v p="$price" '{ t = $23 } END { if (p != "" && t > 0) printf "%.2f", p / (t * 3600) * 1e6 }' <<<"$row")
      echo "${row},${price},${cost}" >> "$out_csv"
    done < <(tail -n +2 "$f")
  done < <(find "$tmp" -name '*.csv' | sort)
  [[ -n "$header" ]] || die "no hostbench results found in: ${buckets} (run: $0 hostbench)"
  log "Merged: ${out_csv}"
  # compact view: host + key numbers; full detail in the CSV
  awk -F, 'BEGIN { OFS="," } NR == 1 { print "when","type","az","vcpu","gib","gpu","triad_MB/s","nvme_rd_MB/s","nvme_4k_iops","s3_MB/s","model","prefill_t/s","decode_t/s","gpu_GB/s","spot_$/h","$/Mtok"; next }
    { print substr($1,1,16),$3,$4,$5,$6,$7,$12,$14,$15,$17,$18,$21,$23,$24,$25,$26 }' "$out_csv" | column -t -s,
}

# --- performance runs (lab02-metrics on the node) ---
cmd_metrics() {
  local action="${1:-status}"; shift || true
  require_instance
  case "$action" in
    start|stop|status|list|show) ;;
    *) die "usage: $0 metrics start <label> [interval_s] | stop | status | list | show <run>" ;;
  esac
  local args="" a
  for a in "$@"; do [[ "$a" =~ ^[A-Za-z0-9._-]+$ ]] || die "bad argument: ${a}"; args+=" ${a}"; done
  SSM_OUTPUT_LINES="${SSM_OUTPUT_LINES:-80}" ssm_run "command -v lab02-metrics >/dev/null || { echo 'lab02-metrics missing - run: lab02.sh provision metering'; exit 1; }
lab02-metrics ${action}${args}" 300 "lab02 metrics ${action}"
}

# Fixed workload (loadtest_node.sh) through lab02-meter, recorded as a lab02-metrics run.
cmd_loadtest() {
  local label="${1:-}" model="${2:-}" conc="${3:-2}" npred="${4:-400}" pset="${5:-short}"
  [[ "$label" =~ ^[A-Za-z0-9._-]+$ && "$model" =~ ^[A-Za-z0-9._:/-]+$ && "$conc" =~ ^[0-9]+$ && "$npred" =~ ^[0-9]+$ && "$pset" =~ ^(short|long)$ ]] \
    || die "usage: $0 loadtest <label> <model> [concurrency=2] [num_predict=400] [short|long]"
  require_instance
  upload_node_scripts >/dev/null
  log "loadtest ${label}: ${model}, ${pset} prompts, 3 sequential + 2 x ${conc} parallel, ${npred} tokens each"
  SSM_OUTPUT_LINES=20 ssm_run "$(fetch_node_scripts_cmd)
/opt/lab02/loadtest_node.sh ${label} ${model} ${conc} ${npred} ${pset}" 3600 "lab02 loadtest ${label}"
}

# Every run's summary.json from all lab02 buckets -> one comparison table + results/metrics_all.csv
cmd_metrics_report() {
  local buckets="${HOSTBENCH_BUCKETS:-$S3_BUCKET}"
  local tmp b region out_csv="${SCRIPT_DIR}/../results/metrics_all.csv"
  tmp=$(mktemp -d); TMP_FILES+=("$tmp")
  for b in $buckets; do
    region=$(aws_cli s3api get-bucket-location --bucket "$b" --query LocationConstraint --output text 2>/dev/null || true)
    [[ -z "$region" || "$region" == "None" ]] && region="us-east-1"
    aws --profile "$AWS_PROFILE" --region "$region" s3 cp "s3://${b}/${S3_PREFIX}/metrics/" "${tmp}/${b}/" \
      --recursive --exclude '*' --include '*/summary.json' --only-show-errors 2>/dev/null || true
  done
  local files; files=$(find "$tmp" -name summary.json | sort)
  [[ -n "$files" ]] || die "no metrics runs found (record one: $0 metrics start <label> ... $0 metrics stop)"
  mkdir -p "$(dirname "$out_csv")"
  # shellcheck disable=SC2086
  jq -s -r '
    ["run","type","gpu","backend","models","ctx","par","kv","dur_s","reqs","fail","rps","out_tok/s","gen_tps_p50","ttft_p50","ttft_p95","lat_p95","gpu%","vram_max","cpu%","kv%"],
    (sort_by(.run)[] | [.run, .instance_type, .gpu, (.backend_version // .backend_url),
      ([.loaded_models[]?.name] | join("+")), (.config.OLLAMA_CONTEXT_LENGTH // "-"), (.config.OLLAMA_NUM_PARALLEL // "-"),
      (.config.OLLAMA_KV_CACHE_TYPE // "" | if . == "" then "f16" else . end), .duration_s,
      .requests.requests, .requests.failed, .load.rps_avg_active, .requests.throughput_completion_tps,
      .requests.gen_tps_p50, .requests.ttft_p50_s, .requests.ttft_p95_s, .requests.latency_p95_s,
      .load.gpu_util_avg, .load.gpu_mem_max_mib, .load.cpu_util_avg, .load.kv_cache_pct_max]
      | map(if . == null then "-" else tostring end)) | @csv' $files > "$out_csv"
  log "Merged $(echo "$files" | wc -l | tr -d ' ') runs: ${out_csv}   (full per-run data: $0 metrics-pull <run>)"
  sed 's/"//g' "$out_csv" | column -t -s,
}

cmd_metrics_pull() {
  local run="${1:-}" b region dest
  [[ "$run" =~ ^[A-Za-z0-9._-]+$ ]] || die "usage: $0 metrics-pull <run>   (runs: $0 metrics-report)"
  dest="${SCRIPT_DIR}/../results/metrics/${run}"
  for b in ${HOSTBENCH_BUCKETS:-$S3_BUCKET}; do
    region=$(aws_cli s3api get-bucket-location --bucket "$b" --query LocationConstraint --output text 2>/dev/null || true)
    [[ -z "$region" || "$region" == "None" ]] && region="us-east-1"
    if aws --profile "$AWS_PROFILE" --region "$region" s3 cp "s3://${b}/${S3_PREFIX}/metrics/${run}/" "$dest/" --recursive --only-show-errors 2>/dev/null \
       && [[ -f "${dest}/summary.json" ]]; then
      log "Downloaded ${run} from ${b}: ${dest}/ (samples.csv = time series, requests.jsonl = per request)"
      return 0
    fi
  done
  die "run ${run} not found in any bucket"
}

# --- S3 model stores: models/<backend>/... (ollama: manifests/ + blobs/) ---
# Echoes "model manifest_key" for every Ollama manifest in S3.
s3_ollama_manifests() {
  local base_key="${S3_PREFIX}/models/ollama/manifests/"
  aws_cli s3 ls "s3://${S3_BUCKET}/${base_key}" --recursive | awk -v b="$base_key" '{
    k = $4; r = substr(k, length(b) + 1); n = split(r, p, "/"); tag = p[n]; name = ""
    start = (p[1] == "registry.ollama.ai") ? ((p[2] == "library") ? 3 : 2) : 1
    for (i = start; i < n; i++) name = name (name == "" ? "" : "/") p[i]
    print name ":" tag, k }'
}

cmd_s3_models() {
  local action="${1:-list}"; shift || true
  local backend="ollama" keep="" apply=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --backend) backend="$2"; shift 2 ;;
      --keep) keep="$2"; shift 2 ;;
      --apply) apply=1; shift ;;
      *) die "usage: $0 s3-models list [--backend B] | prune --keep '<model> ...' [--backend B] [--apply]" ;;
    esac
  done
  local base="s3://${S3_BUCKET}/${S3_PREFIX}/models/${backend}" tmp
  tmp=$(mktemp -d); TMP_FILES+=("$tmp")
  aws_cli s3 ls "${base}/" --recursive > "${tmp}/all.txt" 2>/dev/null || true

  if [[ "$backend" != "ollama" ]]; then  # generic layout: models/<backend>/<org>/<repo>/...
    awk -v b="${S3_PREFIX}/models/${backend}/" '{ r = substr($4, length(b) + 1); split(r, p, "/"); m = p[1] "/" p[2]; s[m] += $3; c[m]++ }
      END { for (m in s) printf "%s %d %d\n", m, s[m], c[m] }' "${tmp}/all.txt" | sort > "${tmp}/models.txt"
    if [[ "$action" == "list" ]]; then
      awk '{ printf "%-60s %8.2f GiB %6d files\n", $1, $2 / 2^30, $3; t += $2 } END { printf "total %.2f GiB in %s\n", t / 2^30, "'"${base}"'" }' "${tmp}/models.txt"
      return 0
    fi
    [[ "$action" == "prune" && -n "$keep" ]] || die "prune needs --keep '<org/repo> ...'"
    local m del=""
    while read -r m _; do [[ " ${keep} " == *" ${m} "* ]] || del+=" ${m}"; done < "${tmp}/models.txt"
    [[ -n "$del" ]] || { log "nothing to prune"; return 0; }
    log "would delete:${del}"
    [[ "$apply" == "1" ]] || { log "dry run - add --apply to delete"; return 0; }
    confirm "Delete${del} from ${base}?" || die "aborted"
    for m in $del; do aws_cli s3 rm "${base}/${m}/" --recursive --only-show-errors; done
    log "pruned:${del}"
    return 0
  fi

  # ollama: resolve manifests -> referenced blobs
  s3_ollama_manifests > "${tmp}/manifests.txt"
  [[ -s "${tmp}/manifests.txt" ]] || { log "no Ollama models in ${base}/"; return 0; }
  local model key digests size
  : > "${tmp}/refs.txt"
  while read -r model key; do
    aws_cli s3 cp "s3://${S3_BUCKET}/${key}" "${tmp}/m.json" --only-show-errors
    digests=$(jq -r '.config.digest, .layers[].digest | sub(":"; "-")' "${tmp}/m.json" | tr '\n' ' ')
    size=$(jq '[.config.size, .layers[].size] | add' "${tmp}/m.json")
    echo "${model} ${size} ${key} ${digests}" >> "${tmp}/refs.txt"
  done < "${tmp}/manifests.txt"
  awk '$4 ~ /\/blobs\// { n = split($4, p, "/"); print p[n], $3 }' "${tmp}/all.txt" | sort > "${tmp}/blobs.txt"

  if [[ "$action" == "list" ]]; then
    awk '{ printf "%-45s %8.2f GiB %3d blobs\n", $1, $2 / 2^30, NF - 3 }' "${tmp}/refs.txt" | sort
    awk 'NR == FNR { for (i = 4; i <= NF; i++) ref[$i] = 1; next } { t += $2; if (!($1 in ref)) { o++; os += $2 } }
      END { printf "store %.2f GiB in %s, unreferenced blobs: %d (%.2f GiB)\n", t / 2^30, "'"${base}"'", o, os / 2^30 }' \
      "${tmp}/refs.txt" "${tmp}/blobs.txt"
    return 0
  fi
  [[ "$action" == "prune" && -n "$keep" ]] || die "prune needs --keep '<model:tag> ...' (see: $0 s3-models list)"
  # keep set -> kept blobs; everything else (manifests + blobs) goes
  awk -v keep=" ${keep} " 'index(keep, " " $1 " ") { for (i = 4; i <= NF; i++) print $i }' "${tmp}/refs.txt" | sort -u > "${tmp}/keep_blobs.txt"
  awk -v keep=" ${keep} " '!index(keep, " " $1 " ") { print $3 }' "${tmp}/refs.txt" > "${tmp}/del_keys.txt"
  awk -v pre="${S3_PREFIX}/models/ollama/blobs/" 'NR == FNR { k[$1] = 1; next } !($1 in k) { print pre $1 }' \
    "${tmp}/keep_blobs.txt" "${tmp}/blobs.txt" >> "${tmp}/del_keys.txt"
  local missing="" w
  for w in $keep; do grep -q "^${w} " "${tmp}/refs.txt" || missing+=" ${w}"; done
  [[ -z "$missing" ]] || die "not in S3 (typo?):${missing} - nothing deleted"
  [[ -s "${tmp}/del_keys.txt" ]] || { log "nothing to prune - only kept models are stored"; return 0; }
  log "keep: ${keep}"
  log "delete $(wc -l < "${tmp}/del_keys.txt" | tr -d ' ') objects ($(awk 'NR == FNR { s[$1] = $2; next } { n = split($1, p, "/"); t += s[p[n]] } END { printf "%.2f GiB of blobs", t / 2^30 }' "${tmp}/blobs.txt" "${tmp}/del_keys.txt")):"
  sed 's|^|  |' "${tmp}/del_keys.txt"
  [[ "$apply" == "1" ]] || { log "dry run - add --apply to delete"; return 0; }
  confirm "Delete these objects from s3://${S3_BUCKET}?" || die "aborted"
  while read -r key; do aws_cli s3 rm "s3://${S3_BUCKET}/${key}" --only-show-errors; done < "${tmp}/del_keys.txt"
  log "pruned; remaining:"; cmd_s3_models list
}

cmd_bake() {
  require_instance
  local root_dev name bdm ami state i
  confirm "Bake ${INSTANCE_ID}? The node stops serving (bake-prep) and reboots for a consistent image." || die "aborted"

  ssm_run "/opt/lab02/provision_node.sh bake-prep" 600 "lab02 bake-prep" || die "bake-prep failed"

  root_dev=$(aws_cli ec2 describe-instances --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].RootDeviceName' --output text)
  name="${INSTANCE_NAME}-al2023-$(date -u +%Y%m%d-%H%M)"
  # Root only - NVMe instance store is never captured, it is re-enumerated on each Nitro instance.
  bdm=$(jq -cn --arg d "$root_dev" --argjson s "$ROOT_VOLUME_GB" '[{DeviceName:$d, Ebs:{VolumeSize:$s, VolumeType:"gp3", DeleteOnTermination:true}}]')

  ami=$(aws_cli ec2 create-image \
    --instance-id "$INSTANCE_ID" \
    --name "$name" \
    --description "lab02 LLM node: AL2023 + NVIDIA driver + Ollama + lab02-boot.service" \
    --block-device-mappings "$bdm" \
    --tag-specifications \
      "ResourceType=image,Tags=[{Key=Name,Value=${name}},{Key=project,Value=${PROJECT_TAG}}]" \
      "ResourceType=snapshot,Tags=[{Key=Name,Value=${name}},{Key=project,Value=${PROJECT_TAG}}]" \
    --query 'ImageId' --output text)
  log "Image ${ami} (${name}) creating..."

  for ((i = 0; i < 120; i++)); do
    state=$(aws_cli ec2 describe-images --image-ids "$ami" --query 'Images[0].State' --output text)
    case "$state" in
      available) break ;;
      failed|error|invalid) die "image ${ami} ended in state ${state}" ;;
    esac
    sleep 30
  done
  [[ "$state" == "available" ]] || die "image ${ami} still ${state} after 60 min - check later with: $0 images"

  log ""
  log "AMI ready: ${ami}"
  log "  1. set AMI_ID=\"${ami}\" in values.export"
  log "  2. $0 terminate        # this bake instance is cleaned and no longer serves"
  log "  3. $0 launch && $0 wait-ready && $0 tunnel"
}

cmd_images() {
  aws_cli ec2 describe-images --owners self --filters "Name=tag:project,Values=${PROJECT_TAG}" --output table \
    --query 'sort_by(Images, &CreationDate)[].{Id:ImageId,Name:Name,State:State,Created:CreationDate}'
}

cmd_image_delete() {
  local ami="${1:-}" snaps s
  [[ "$ami" == ami-* ]] || die "usage: $0 image-delete <ami-id>"
  snaps=$(aws_cli ec2 describe-images --image-ids "$ami" --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)
  confirm "Deregister ${ami} and delete snapshot(s) ${snaps}?" || die "aborted"
  aws_cli ec2 deregister-image --image-id "$ami"
  for s in $snaps; do aws_cli ec2 delete-snapshot --snapshot-id "$s"; done
  log "Deleted ${ami} (${snaps})."
}

cmd_spot_price() {
  local az subnet price mark
  log "${INSTANCE_TYPE} spot, cap \$${MAX_SPOT_PRICE:-on-demand}/h:"
  while read -r az subnet; do
    price=$(current_spot_price "$az")
    if [[ -z "$price" ]]; then mark="not offered"
    elif price_above_cap "$price"; then mark="ABOVE CAP"
    else mark="ok"; fi
    printf '  %-12s %-26s %-10s %s\n' "$az" "$subnet" "${price:--}" "$mark"
  done < <(launch_plan)
}

cmd_terminate() {
  require_instance
  confirm "Terminate ${INSTANCE_ID} (${INSTANCE_NAME})? NVMe data is lost; S3 model cache is kept." || die "aborted"
  aws_cli ec2 terminate-instances --instance-ids "$INSTANCE_ID" --query 'TerminatingInstances[0].CurrentState.Name' --output text
}

cmd_help() {
  cat <<EOF
Usage: $0 <command> [args]

  launch                 spot instance, tries each AZ in SUBNET_MAP (LAUNCH_ROUNDS passes), waits for SSM
  provision [step]       run provision_node.sh <step> on the node via SSM (default: all = incl. tools)
  wait-ready             poll until the boot service reports 'ready' (baked AMI launches)
  status                 instance state + SSM ping
  node-status            node status, GPU, NVMe, loaded models
  logs                   live tail of /var/log/lab02-node.log (Session Manager)
  shell                  interactive shell (Session Manager)
  exec '<cmd>'           run a shell command as root on the node, print output
  tunnel [local_port]    port-forward localhost:${LOCAL_PORT} -> node:${OLLAMA_PORT}
  set-models '<list>'    switch served models on the running node (S3 restore or pull)
  set-env K=V [K=V ...]  change Ollama settings on the running node (context, parallel, KV cache), restart
  ttl <hours>            move the auto-poweroff deadline to now + hours
  hostbench [quick|full] STREAM + NVMe fio + S3 + LLM prefill/decode on the node -> CSV in S3
  hostbench-report       merge hostbench CSVs from all regions + current spot price + \$/Mtok
  metrics start <label> [interval_s] | stop | status | list
                         record a performance run on the node (GPU/CPU/RAM/net/NVMe + rps, tokens/s,
                         TTFT, latency, KV cache) -> node + S3; stop prints summary
  loadtest <label> <model> [conc] [tokens] [short|long]  fixed repeatable workload -> metrics run
                         (long = ~1.5k-token Terraform summarize prompts, like repo ingestion)
  metrics-report         all runs from all regions -> comparison table + results/metrics_all.csv
  metrics-pull <run>     download one run (samples.csv, requests.jsonl, summary.json)
  s3-models list [--backend ollama|hf]          models stored in S3 for a backend, sizes, orphans
  s3-models prune --keep '<m> ...' [--apply]    delete everything else (dry run without --apply)
  bake                   bake-prep + create-image from the running node
  images                 list lab02 AMIs
  image-delete <ami>     deregister an AMI and delete its snapshots
  spot-price             current spot price for INSTANCE_TYPE in every launch AZ vs the cap
  terminate              terminate the instance

Config: ${VALUES_FILE} (env overrides win). DRY_RUN=1 validates launch; FORCE=1 skips prompts.
EOF
}

# main() wrapper: bash parses the whole file first, so editing it mid-run is safe.
main() {
  require_tools
  cmd="${1:-help}"
  shift || true
  case "$cmd" in
    help|-h|--help|status|images|image-delete|spot-price) ;;
    *) require_config S3_BUCKET ;;
  esac
  case "$cmd" in
    launch)       cmd_launch ;;
    provision)    cmd_provision "$@" ;;
    wait-ready)   cmd_wait_ready ;;
    status)       cmd_status ;;
    node-status)  cmd_node_status ;;
    logs)         cmd_logs ;;
    shell)        cmd_shell ;;
    exec)         cmd_exec "$@" ;;
    tunnel)       cmd_tunnel "$@" ;;
    set-models)   cmd_set_models "$@" ;;
    set-env)      cmd_set_env "$@" ;;
    ttl)          cmd_ttl "$@" ;;
    bake)         cmd_bake ;;
    hostbench)    cmd_hostbench "$@" ;;
    metrics)      cmd_metrics "$@" ;;
    loadtest)     cmd_loadtest "$@" ;;
    metrics-report) cmd_metrics_report ;;
    metrics-pull) cmd_metrics_pull "$@" ;;
    s3-models)    cmd_s3_models "$@" ;;
    hostbench-report) cmd_hostbench_report ;;
    images)       cmd_images ;;
    image-delete) cmd_image_delete "$@" ;;
    spot-price)   cmd_spot_price ;;
    terminate)    cmd_terminate ;;
    help|-h|--help) cmd_help ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"; exit $?
