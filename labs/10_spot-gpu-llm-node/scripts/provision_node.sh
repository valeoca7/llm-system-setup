#!/bin/bash
# lab02 - node-side provisioning + boot (AL2023, root, driven via SSM); config from /etc/lab02/node.env
set -euo pipefail

export HOME="${HOME:-/root}"   # SSM RunShellScript runs without HOME; aws cli config needs it
export PATH="/usr/local/bin:/usr/local/sbin:${PATH}"

ENV_FILE="${LAB02_ENV_FILE:-/etc/lab02/node.env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

# --- config (real values from node.env) ---
AWS_REGION="${AWS_REGION:-us-west-2}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-lab02}"
# per-backend store: models/ollama/{manifests,blobs}, later models/hf/<org>/<repo>/
S3_MODELS_URI="${S3_MODELS_URI:-s3://${S3_BUCKET}/${S3_PREFIX}/models/ollama}"
S3_SAVE_PULLED="${S3_SAVE_PULLED:-1}"            # push models pulled from ollama.com back to S3
S3_TARGET_BANDWIDTH="${S3_TARGET_BANDWIDTH:-25Gb/s}" # aws cli CRT client target throughput

MODELS="${MODELS:-gpt-oss:20b}"                  # space/comma separated Ollama tags

DATA_MOUNT_POINT="${DATA_MOUNT_POINT:-/data}"
OLLAMA_MODELS_DIR="${DATA_MOUNT_POINT}/ollama-models"

OLLAMA_VERSION="${OLLAMA_VERSION:-}"              # empty = latest from ollama.com/install.sh
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
OLLAMA_BIND="${OLLAMA_BIND:-127.0.0.1}"          # SSM port forwarding reaches localhost - no SG ingress
OLLAMA_KEEP_ALIVE="${OLLAMA_KEEP_ALIVE:--1}"     # keep models resident in GPU memory
OLLAMA_NUM_PARALLEL="${OLLAMA_NUM_PARALLEL:-4}"
OLLAMA_MAX_LOADED_MODELS="${OLLAMA_MAX_LOADED_MODELS:-2}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-65536}"
# KV cache: "" = f16, q8_0 = half, q4_0 = quarter; needs flash attention
OLLAMA_KV_CACHE_TYPE="${OLLAMA_KV_CACHE_TYPE:-}"
OLLAMA_FLASH_ATTENTION="${OLLAMA_FLASH_ATTENTION:-1}"

TEST_PROMPT="${TEST_PROMPT:-Explain what a spot instance is, in two sentences.}"

INSTALL_DIR="/opt/lab02"
STATE_DIR="/var/lib/lab02"
STATUS_DIR="/run/lab02"
STATUS_FILE="${STATUS_DIR}/status"
LOG_FILE="/var/log/lab02-node.log"
BOOT_UNIT="/etc/systemd/system/lab02-boot.service"
OLLAMA_DROPIN_DIR="/etc/systemd/system/ollama.service.d"
MD_DEVICE="/dev/md/lab02"

# --- helpers ---
if [[ $EUID -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

mkdir -p "$STATE_DIR" "$STATUS_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
die() { log "ERROR: $*"; exit 1; }
set_status() { echo "$1" > "$STATUS_FILE"; }

model_list() { echo "$MODELS" | tr ',' ' '; }

# Manifest path in the Ollama store (registry.ollama.ai/library/..., user/..., or hf.co/... as is).
manifest_rel() {
  local model="$1" name tag
  name="${model%%:*}"
  if [[ "$model" == *:* ]]; then tag="${model##*:}"; else tag="latest"; fi
  if [[ "$name" == */* && "${name%%/*}" == *.* ]]; then   # registry host prefix (hf.co/...), not "qwen3.8"
    echo "manifests/${name}/${tag}"
  elif [[ "$name" == */* ]]; then
    echo "manifests/registry.ollama.ai/${name}/${tag}"
  else
    echo "manifests/registry.ollama.ai/library/${name}/${tag}"
  fi
}

wait_ollama_api() {
  local i
  for ((i = 0; i < 60; i++)); do
    curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/version" >/dev/null && return 0
    sleep 2
  done
  die "Ollama API did not come up on 127.0.0.1:${OLLAMA_PORT} (journalctl -u ollama)"
}

# SSM exit 194 = reboot and re-run the command; steps are idempotent.
request_reboot() {
  if [[ "${LAB02_SSM:-0}" == "1" ]]; then
    log "Rebooting through SSM (exit 194) - the provision command resumes after the reboot."
    sync
    exit 194
  fi
  log "REBOOT REQUIRED: run 'sudo reboot', reconnect, then re-run: $0 ${CURRENT_STEP:-all}"
  exit 0
}

# --- bake steps ---
step_packages() {
  # Prefer IPv4: subnets with DNS64 but no NAT64 resolve IPv4-only S3/STS to dead 64:ff9b:: addresses.
  grep -q '^precedence ::ffff:0:0/96' /etc/gai.conf 2>/dev/null || echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf
  log "Installing base packages..."
  dnf -y install jq pciutils mdadm xfsprogs zstd tar
  # CRT transfer client: multi-connection S3 transfers, needed to get GB/s from S3 onto NVMe.
  aws configure set default.s3.preferred_transfer_client crt
  aws configure set default.s3.target_bandwidth "$S3_TARGET_BANDWIDTH"
}

step_driver() {
  if nvidia-smi -L >/dev/null 2>&1; then
    log "NVIDIA driver active: $(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader)"
    log "nvidia kernel module license: $(modinfo -F license nvidia 2>/dev/null || echo unknown) (Dual MIT/GPL = open module, required for Blackwell)"
    return
  fi

  if [[ -f "${STATE_DIR}/driver-installed" ]]; then
    dmesg | grep -i nvidia | tail -20 || true
    # TODO: 'No devices were found' on g7e = proprietary module installed; Blackwell needs the open one.
    die "driver was installed and the node rebooted, but nvidia-smi still fails (see dmesg above)"
  fi

  log "Installing NVIDIA driver from the AL2023 NVIDIA repository (AWS-maintained)..."
  dnf -y install nvidia-release
  # Headers must match the running kernel package (e.g. kernel6.18-devel), not plain kernel-devel.
  local kpkg
  kpkg=$(rpm -qf --qf '%{NAME}\n' "/boot/vmlinuz-$(uname -r)" | head -1)
  log "Running kernel $(uname -r) from package ${kpkg} - installing ${kpkg}-devel/-headers"
  dnf -y install "${kpkg}-devel-$(uname -r)" "${kpkg}-headers-$(uname -r)"
  # Open kernel module: required on Blackwell, works on Ada/Ampere.
  dnf -y install ${NVIDIA_DRIVER_PACKAGES:-kmod-nvidia-open-dkms nvidia-driver-cuda}
  dkms status 2>/dev/null | grep -i nvidia || log "WARN: no nvidia entry in dkms status"
  # No cuda-toolkit: Ollama ships its own CUDA runtime, only the driver is needed.
  touch "${STATE_DIR}/driver-installed"
  request_reboot
}

step_ollama() {
  if command -v ollama >/dev/null 2>&1 && [[ -z "$OLLAMA_VERSION" || "$(ollama -v 2>/dev/null)" == *"$OLLAMA_VERSION"* ]]; then
    log "Ollama already installed: $(ollama -v 2>/dev/null | tail -1)"
  else
    log "Installing Ollama ${OLLAMA_VERSION:-latest}..."
    curl -fsSL https://ollama.com/install.sh | OLLAMA_VERSION="$OLLAMA_VERSION" sh
  fi
  # lab02-boot.service owns the Ollama lifecycle: it must only start after the NVMe is mounted.
  systemctl disable ollama >/dev/null 2>&1 || true
}

step_install_service() {
  log "Installing ${INSTALL_DIR}/provision_node.sh + lab02-boot.service..."
  mkdir -p "$INSTALL_DIR"
  if [[ "$(readlink -f "$0")" != "${INSTALL_DIR}/provision_node.sh" ]]; then
    install -m 0755 "$0" "${INSTALL_DIR}/provision_node.sh"
  fi
  cat > "$BOOT_UNIT" <<EOF
[Unit]
Description=lab02 node boot: mount NVMe, restore models from S3, start Ollama
After=network-online.target
Wants=network-online.target
ConditionPathExists=${ENV_FILE}

[Service]
Type=oneshot
RemainAfterExit=yes
TimeoutStartSec=infinity
ExecStart=${INSTALL_DIR}/provision_node.sh boot

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable lab02-boot.service
}

# --- run steps (boot service) ---
step_mount() {
  if mountpoint -q "$DATA_MOUNT_POINT"; then
    log "${DATA_MOUNT_POINT} already mounted: $(findmnt -no SOURCE "$DATA_MOUNT_POINT")"
    return
  fi

  local disks count device
  disks=$(lsblk -dpno NAME,MODEL | awk '/Instance Storage/ {print $1}')
  count=$(echo "$disks" | grep -c . || true)
  [[ "$count" -gt 0 ]] || die "no NVMe instance store disks found (instance type without local storage?)"
  log "NVMe instance store disks (${count}): $(echo $disks)"

  if [[ "$count" -eq 1 ]]; then
    device="$disks"
  else
    device="$MD_DEVICE"
    if [[ ! -e "$device" ]]; then
      mdadm --assemble --scan >/dev/null 2>&1 || true
    fi
    if [[ ! -e "$device" ]]; then
      log "Creating RAID0 across ${count} NVMe disks..."
      # shellcheck disable=SC2086
      mdadm --create "$device" --level=0 --raid-devices="$count" --run $disks
    fi
  fi

  if ! blkid "$device" >/dev/null 2>&1; then
    log "Formatting ${device} as XFS (fresh instance store)..."
    mkfs.xfs -f -L lab02-data "$device"
  fi

  mkdir -p "$DATA_MOUNT_POINT"
  mount -o noatime "$device" "$DATA_MOUNT_POINT"
  log "Mounted ${device} at ${DATA_MOUNT_POINT}: $(df -h --output=size,avail "$DATA_MOUNT_POINT" | tail -1)"
}

step_serve() {
  mountpoint -q "$DATA_MOUNT_POINT" || die "${DATA_MOUNT_POINT} not mounted - run 'mount' first"
  id ollama >/dev/null 2>&1 || die "ollama user missing - run 'ollama' step first"

  mkdir -p "$OLLAMA_MODELS_DIR"
  chown -R ollama:ollama "$OLLAMA_MODELS_DIR"

  log "Configuring Ollama (bind ${OLLAMA_BIND}:${OLLAMA_PORT}, models ${OLLAMA_MODELS_DIR})..."
  mkdir -p "$OLLAMA_DROPIN_DIR"
  cat > "${OLLAMA_DROPIN_DIR}/override.conf" <<EOF
[Unit]
RequiresMountsFor=${DATA_MOUNT_POINT}

[Service]
Environment="OLLAMA_HOST=${OLLAMA_BIND}:${OLLAMA_PORT}"
Environment="OLLAMA_MODELS=${OLLAMA_MODELS_DIR}"
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
Environment="OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
Environment="OLLAMA_CONTEXT_LENGTH=${OLLAMA_CONTEXT_LENGTH}"
Environment="OLLAMA_FLASH_ATTENTION=${OLLAMA_FLASH_ATTENTION}"
${OLLAMA_KV_CACHE_TYPE:+Environment="OLLAMA_KV_CACHE_TYPE=${OLLAMA_KV_CACHE_TYPE}"}
EOF
  systemctl daemon-reload
  systemctl restart ollama
  wait_ollama_api
  log "Ollama up: $(curl -s "http://127.0.0.1:${OLLAMA_PORT}/api/version")"
}

model_present() {
  ollama show "$1" >/dev/null 2>&1
}

# Restores one model (manifest + its blobs) from S3; non-zero lets the caller fall back to pull.
restore_model_from_s3() {
  local model="$1" rel digest blob
  rel=$(manifest_rel "$model")
  aws s3 cp "${S3_MODELS_URI}/${rel}" "${OLLAMA_MODELS_DIR}/${rel}" --region "$AWS_REGION" --only-show-errors 2>/dev/null || return 1

  for digest in $(jq -r '.config.digest, .layers[].digest' "${OLLAMA_MODELS_DIR}/${rel}"); do
    blob="blobs/${digest/:/-}"
    [[ -f "${OLLAMA_MODELS_DIR}/${blob}" ]] && continue
    aws s3 cp "${S3_MODELS_URI}/${blob}" "${OLLAMA_MODELS_DIR}/${blob}" --region "$AWS_REGION" --only-show-errors || {
      rm -f "${OLLAMA_MODELS_DIR}/${rel}"
      return 1
    }
  done
  chown -R ollama:ollama "$OLLAMA_MODELS_DIR"
  model_present "$model"
}

step_models() {
  wait_ollama_api
  local model pulled="" start end bytes
  for model in $(model_list); do
    if model_present "$model"; then
      log "Model ${model}: already on local NVMe."
      continue
    fi

    start=$(date +%s)
    if restore_model_from_s3 "$model"; then
      end=$(date +%s)
      bytes=$(du -sb "$OLLAMA_MODELS_DIR" | cut -f1)
      log "Model ${model}: restored from ${S3_MODELS_URI} in $((end - start))s (store now $((bytes / 1024 / 1024 / 1024)) GiB)."
    else
      log "Model ${model}: not in S3 cache - pulling from ollama.com (slow, first time only)..."
      # progress bars would flood the log/SSM output - keep only the tail on failure
      if ! pull_out=$(ollama pull "$model" 2>&1); then
        echo "$pull_out" | tr '\r' '\n' | grep -v '^\s*$' | tail -5
        die "ollama pull ${model} failed"
      fi
      end=$(date +%s)
      log "Model ${model}: pulled in $((end - start))s."
      pulled+=" ${model}"
      [[ "$S3_SAVE_PULLED" == "1" ]] && save_model_to_s3 "$model"
    fi
  done
  [[ -z "$pulled" ]] || log "Pulled this run:${pulled}"
}

# Uploads one model (manifest + its blobs, missing only); per model so pruned models do not return.
save_model_to_s3() {
  local model="$1" rel digest args=()
  rel=$(manifest_rel "$model")
  [[ -f "${OLLAMA_MODELS_DIR}/${rel}" ]] || { log "WARN: ${model} not in local store - not saved"; return 0; }
  args=(--exclude '*' --include "$rel")
  for digest in $(jq -r '.config.digest, .layers[].digest' "${OLLAMA_MODELS_DIR}/${rel}"); do
    args+=(--include "blobs/${digest/:/-}")
  done
  log "Saving ${model} to ${S3_MODELS_URI} ($(( ${#args[@]} / 2 - 1 )) blobs, missing ones only)..."
  aws s3 sync "${OLLAMA_MODELS_DIR}/" "${S3_MODELS_URI}/" "${args[@]}" --region "$AWS_REGION" --only-show-errors
  log "Saved ${model}."
}

# Saves every model in MODELS that is present locally.
step_save_models() {
  local model
  for model in $(model_list); do
    model_present "$model" && save_model_to_s3 "$model"
  done
}

step_warm() {
  local model start
  for model in $(model_list); do
    start=$(date +%s)
    log "Loading ${model} into GPU memory (keep_alive ${OLLAMA_KEEP_ALIVE})..."
    curl -sf -m 900 "http://127.0.0.1:${OLLAMA_PORT}/api/generate" \
      -d "$(jq -n --arg m "$model" --arg k "$OLLAMA_KEEP_ALIVE" '{model:$m, prompt:"", keep_alive:($k|tonumber? // $k)}')" >/dev/null \
      || die "failed to load ${model}"
    log "Loaded ${model} in $(( $(date +%s) - start ))s."
  done
  ollama ps || true
}

step_test() {
  local model payload response eval_count eval_ns
  model=$(model_list | awk '{print $1}')
  log "Test prompt to ${model}: ${TEST_PROMPT}"
  payload=$(jq -n --arg m "$model" --arg p "$TEST_PROMPT" '{model:$m, prompt:$p, stream:false, options:{temperature:0}}')
  response=$(curl -s -m 300 "http://127.0.0.1:${OLLAMA_PORT}/api/generate" -d "$payload")
  echo "$response" | jq -r '.response // .error'
  eval_count=$(echo "$response" | jq -r '.eval_count // 0')
  eval_ns=$(echo "$response" | jq -r '.eval_duration // 0')
  if [[ "$eval_ns" -gt 0 ]]; then
    log "Tokens: ${eval_count}, tokens/sec: $(awk -v c="$eval_count" -v d="$eval_ns" 'BEGIN { printf "%.2f", c / (d / 1e9) }')"
  fi
}

step_boot() {
  set_status "booting"
  # EXIT, not ERR: die() exits explicitly and ERR is not inherited by functions without set -E.
  trap 'rc=$?; [[ $rc -eq 0 ]] || set_status failed' EXIT
  step_mount
  step_serve
  step_models
  step_warm
  set_status "ready"
  log "Node READY - Ollama on ${OLLAMA_BIND}:${OLLAMA_PORT}, models: $(model_list)"
}

step_status() {
  echo "status:   $(cat "$STATUS_FILE" 2>/dev/null || echo none)"
  echo "deadline: $( [[ -f /etc/lab02/deadline ]] && date -u -d "@$(cat /etc/lab02/deadline)" +%Y-%m-%dT%H:%M:%SZ || echo none)"
  nvidia-smi --query-gpu=name,driver_version,memory.used,memory.total,utilization.gpu --format=csv,noheader 2>/dev/null || echo "gpu:      nvidia-smi unavailable"
  df -h "$DATA_MOUNT_POINT" 2>/dev/null | tail -1 || true
  systemctl is-active ollama >/dev/null 2>&1 && ollama ps || echo "ollama:   not running"
}

step_bake_prep() {
  log "Preparing node for create-image..."
  systemctl stop ollama >/dev/null 2>&1 || true
  if mountpoint -q "$DATA_MOUNT_POINT"; then umount "$DATA_MOUNT_POINT"; fi
  [[ -e "$MD_DEVICE" ]] && mdadm --stop "$MD_DEVICE" || true
  # Per-run config must come from the next instance's user-data, not from this one.
  rm -f "$ENV_FILE" /etc/lab02/deadline
  rm -rf "$STATUS_DIR"
  dnf clean all >/dev/null
  cloud-init clean --logs
  journalctl --rotate >/dev/null 2>&1 || true
  journalctl --vacuum-time=1s >/dev/null 2>&1 || true
  rm -f /root/.bash_history /home/*/.bash_history
  : > "$LOG_FILE"
  sync
  log "Bake prep done - node is no longer serving; create the image now."
}

# Optional monitoring/benchmark tools; failure never fails provisioning.
step_tools() {
  local tools="${INSTALL_DIR}/node_tools.sh"
  if [[ ! -f "$tools" ]]; then
    log "WARN: ${tools} missing - tools skipped (run: lab02.sh provision tools)"
    return 0
  fi
  log "Installing monitoring/benchmark tools (${tools})..."
  if bash "$tools"; then
    log "Tools installed."
  else
    log "WARN: node_tools.sh failed (rc=$?) - provisioning continues; rerun: lab02.sh provision tools"
  fi
}

# Metering proxy + run recorder (node_metering.sh, fetched next to this script). Fast, no downloads.
step_metering() {
  local m="${INSTALL_DIR}/node_metering.sh"
  [[ -f "$m" ]] || { log "WARN: ${m} missing - metering skipped (run: lab02.sh provision metering)"; return 0; }
  log "Installing metering (lab02-meter proxy + lab02-metrics)..."
  bash "$m" || log "WARN: node_metering.sh failed - rerun: lab02.sh provision metering"
}

step_all() {
  step_packages
  step_driver
  step_ollama
  step_install_service
  step_boot
  step_metering
  step_test
  step_tools
}

# --- dispatcher ---
CURRENT_STEP="${1:-}"
case "$CURRENT_STEP" in
  all)             step_all ;;
  packages)        step_packages ;;
  driver)          step_driver ;;
  ollama)          step_ollama ;;
  install-service) step_install_service ;;
  boot)            step_boot ;;
  mount)           step_mount ;;
  serve)           step_serve ;;
  models)          step_models ;;
  save-models)     step_save_models ;;
  tools)           step_tools ;;
  metering)        step_metering ;;
  warm)            step_warm ;;
  test)            step_test ;;
  status)          step_status ;;
  bake-prep)       step_bake_prep ;;
  *)
    echo "Usage: $0 {all|boot|packages|driver|ollama|install-service|mount|serve|models|save-models|warm|test|tools|metering|status|bake-prep}"
    exit 1
    ;;
esac
