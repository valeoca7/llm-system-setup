#!/bin/bash
# lab02 - monitoring/benchmark tools for the LLM node (AL2023 x86_64, NVIDIA), idempotent, run as root.
set -euo pipefail

BTOP_VERSION="${BTOP_VERSION:-1.4.7}"
NVTOP_VERSION="${NVTOP_VERSION:-3.3.2}"
STREAM_ARRAY_SIZE="${STREAM_ARRAY_SIZE:-80000000}" # 3 x 8 B x 80M = 1.8 GiB, >> any L3; fits 16 GiB hosts
TOOLS_DIR="/opt/lab02-tools"
VENV="${TOOLS_DIR}/venv"
BIN="/usr/local/bin"

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { echo "x86_64 only (nvtop AppImage)" >&2; exit 1; }
mkdir -p "$TOOLS_DIR"

echo "== repo packages"
dnf -y -q install htop iotop iftop tmux sysstat python3-pip gcc-c++ make tar gzip jq \
  fio stress-ng nvme-cli numactl libgomp

# btop release binaries lack GPU support - build from source with GPU_SUPPORT=true.
if ! "${BIN}/btop" --version 2>/dev/null | grep -q "$BTOP_VERSION"; then
  echo "== btop ${BTOP_VERSION} (source build, GPU support)"
  src="${TOOLS_DIR}/btop-${BTOP_VERSION}"
  rm -rf "$src"
  curl -fsSL "https://github.com/aristocratos/btop/archive/refs/tags/v${BTOP_VERSION}.tar.gz" | tar -xz -C "$TOOLS_DIR"
  if ! make -C "$src" -j"$(nproc)" GPU_SUPPORT=true >/dev/null 2>&1; then
    echo "   default g++ failed - retrying with gcc14"
    dnf -y -q install gcc14-c++
    make -C "$src" clean >/dev/null 2>&1 || true
    make -C "$src" -j"$(nproc)" GPU_SUPPORT=true CXX=gcc14-g++ >/dev/null
  fi
  make -C "$src" install PREFIX=/usr/local >/dev/null
  rm -rf "$src"
fi

if [[ ! -x "${TOOLS_DIR}/nvtop/AppRun" ]]; then
  echo "== nvtop ${NVTOP_VERSION} (AppImage, extracted)"
  cd "$TOOLS_DIR"
  curl -fsSL -o nvtop.AppImage "https://github.com/Syllo/nvtop/releases/download/${NVTOP_VERSION}/nvtop-${NVTOP_VERSION}-x86_64.AppImage"
  chmod +x nvtop.AppImage
  ./nvtop.AppImage --appimage-extract >/dev/null
  rm -rf nvtop && mv squashfs-root nvtop && rm -f nvtop.AppImage
  cd - >/dev/null
fi
ln -sf "${TOOLS_DIR}/nvtop/AppRun" "${BIN}/nvtop"

# STREAM, x86-64-v3 (not -march=native) so a baked AMI runs on AMD and Intel hosts.
if [[ ! -x "${BIN}/stream" ]]; then
  echo "== stream (STREAM_ARRAY_SIZE=${STREAM_ARRAY_SIZE})"
  curl -fsSL -o "${TOOLS_DIR}/stream.c" https://www.cs.virginia.edu/stream/FTP/Code/stream.c \
    || curl -fsSL -o "${TOOLS_DIR}/stream.c" https://raw.githubusercontent.com/jeffhammond/STREAM/master/stream.c
  gcc -O3 -march=x86-64-v3 -fopenmp -mcmodel=medium -DSTREAM_ARRAY_SIZE="${STREAM_ARRAY_SIZE}" -DNTIMES=20 \
    "${TOOLS_DIR}/stream.c" -o "${BIN}/stream"
fi

echo "== nvitop, gpustat, glances (python venv ${VENV})"
[[ -x "${VENV}/bin/pip" ]] || python3 -m venv "$VENV"
"${VENV}/bin/pip" install -q --upgrade pip
# one pip run: nvitop pins nvidia-ml-py
"${VENV}/bin/pip" install -q --upgrade nvitop gpustat glances \
  || echo "   WARN: pip install nvitop/gpustat/glances failed - skipped"
for tool in nvitop gpustat glances; do
  [[ -x "${VENV}/bin/${tool}" ]] && ln -sf "${VENV}/bin/${tool}" "${BIN}/${tool}"
done

echo "== llmtop"
cat > "${BIN}/llmtop" <<'EOF'
#!/bin/bash
# llmtop [refresh_s] - Ollama models, GPU, last API requests
exec watch -t -n "${1:-2}" '
echo "== $(hostname) $(date -u +%H:%M:%SZ)  status=$(cat /run/lab02/status 2>/dev/null || echo -)  load=$(cut -d" " -f1-3 /proc/loadavg)"
echo; echo "== ollama ps"; ollama ps 2>/dev/null || echo "ollama not running"
echo; echo "== GPU"
nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,power.draw,temperature.gpu --format=csv 2>/dev/null || echo "no NVIDIA driver"
echo; echo "== last requests (status | latency | client | method path)"
journalctl -u ollama --no-pager -n 500 -o cat 2>/dev/null | grep "\[GIN\]" | tail -12 | cut -c1-120
'
EOF
chmod 755 "${BIN}/llmtop"

echo "== lab02-hostbench"
cat > "${BIN}/lab02-hostbench" <<'HBEOF'
#!/bin/bash
# lab02-hostbench [quick|full] - STREAM, NVMe fio, S3->NVMe, Ollama prefill/decode -> CSV + S3
set -euo pipefail
MODE="${1:-quick}"
[[ $EUID -eq 0 ]] || exec sudo -E "$0" "$@"
export HOME="${HOME:-/root}"
[[ -f /etc/lab02/node.env ]] && { set -a; . /etc/lab02/node.env; set +a; }

AWS_REGION="${AWS_REGION:-us-west-2}"
S3_BUCKET="${S3_BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-lab02}"
MODELS="${MODELS:-}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
DATA="${DATA_MOUNT_POINT:-/data}"
WORK="${DATA}/.hostbench"
LOCAL_CSV="/var/log/lab02-hostbench.csv"
S3_URI="${HOSTBENCH_S3_URI:-s3://${S3_BUCKET}/${S3_PREFIX}/hostbench}"
case "$MODE" in
  quick) RT=15; FSIZE=2G ;;
  full)  RT=60; FSIZE=8G ;;
  *) echo "usage: $0 [quick|full]" >&2; exit 1 ;;
esac

log() { echo "[hostbench $(date -u +%H:%M:%S)] $*" >&2; }
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 600')
imds() { curl -s -H "X-aws-ec2-metadata-token: ${TOKEN}" "http://169.254.169.254/latest/meta-data/$1"; }
IID=$(imds instance-id); ITYPE=$(imds instance-type); AZ=$(imds placement/availability-zone)
VCPU=$(nproc)
MEM_GIB=$(awk '/MemTotal/ {printf "%.0f", $2 / 1048576}' /proc/meminfo)
GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | tr ',' ' ' || true)
GPU_MEM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || true)
DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
log "${ITYPE} ${AZ} ${IID}: ${VCPU} vCPU, ${MEM_GIB} GiB, GPU ${GPU:-none} ${GPU_MEM:-} MiB, mode ${MODE}"

# --- 1. STREAM ---
STREAM_COPY=""; STREAM_TRIAD=""
if command -v stream >/dev/null; then
  log "STREAM (${VCPU} threads)..."
  out=$(OMP_NUM_THREADS="$VCPU" OMP_PROC_BIND=spread OMP_PLACES=threads stream 2>&1)
  STREAM_COPY=$(awk '/^Copy:/ {print $2}' <<<"$out")
  STREAM_TRIAD=$(awk '/^Triad:/ {print $2}' <<<"$out")
  log "  Copy ${STREAM_COPY} MB/s, Triad ${STREAM_TRIAD} MB/s"
else
  log "stream not installed - skipped"
fi

# --- 2. fio on local NVMe ---
NV_SW=""; NV_SR=""; NV_RR=""
if mountpoint -q "$DATA"; then
  mkdir -p "$WORK"
  fio_json() {
    fio --name="$1" --directory="$WORK" --rw="$2" --bs="$3" --iodepth="$4" --numjobs=4 --size="$FSIZE" \
      --runtime="$RT" --time_based --direct=1 --ioengine=libaio --group_reporting --output-format=json 2>/dev/null
  }
  log "fio seq write 1M (4 jobs x ${FSIZE}, ${RT}s)..."
  NV_SW=$(fio_json seqw write 1M 32 | jq '.jobs[0].write.bw / 1024 | floor')
  log "fio seq read 1M..."
  NV_SR=$(fio_json seqr read 1M 32 | jq '.jobs[0].read.bw / 1024 | floor')
  log "fio rand read 4k QD64..."
  NV_RR=$(fio_json randr randread 4k 64 | jq '.jobs[0].read.iops | floor')
  log "  NVMe ($(findmnt -no SOURCE "$DATA")): write ${NV_SW} MB/s, read ${NV_SR} MB/s, 4k rand read ${NV_RR} IOPS"
else
  log "${DATA} not mounted - NVMe tests skipped"
fi

# --- 3. S3 -> NVMe ---
S3_MB=""; S3_MBS=""
if [[ -n "$S3_BUCKET" ]] && mountpoint -q "$DATA"; then
  obj=$(aws s3 ls "s3://${S3_BUCKET}/${S3_PREFIX}/models/ollama/blobs/" --region "$AWS_REGION" 2>/dev/null | sort -k3,3n | tail -1 | awk '{print $3, $4}' || true)
  if [[ -n "$obj" ]]; then
    size=${obj%% *}; key=${obj#* }
    log "S3 download ${key} ($((size / 1048576)) MB)..."
    t0=$(date +%s.%N)
    aws s3 cp "s3://${S3_BUCKET}/${S3_PREFIX}/models/ollama/blobs/${key}" "${WORK}/s3obj" --region "$AWS_REGION" --only-show-errors
    t1=$(date +%s.%N)
    rm -f "${WORK}/s3obj"
    S3_MB=$((size / 1048576))
    S3_MBS=$(awk -v b="$size" -v a="$t0" -v c="$t1" 'BEGIN { printf "%.0f", b / 1048576 / (c - a) }')
    log "  ${S3_MBS} MB/s"
  else
    log "no model blobs in s3://${S3_BUCKET}/${S3_PREFIX}/models/ollama/ - S3 test skipped"
  fi
fi
rm -rf "$WORK"

# --- 4. LLM (Ollama) ---
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HEADER="timestamp_utc,instance_id,instance_type,az,vcpu,mem_gib,gpu,gpu_mem_mib,driver,mode,stream_copy_mbs,stream_triad_mbs,nvme_seq_write_mbs,nvme_seq_read_mbs,nvme_rand_read_iops,s3_object_mb,s3_download_mbs,model,model_size_gb,prompt_tokens,prompt_tps,decode_tokens,decode_tps,implied_gpu_gbs"
HOST="${TS},${IID},${ITYPE},${AZ},${VCPU},${MEM_GIB},${GPU:-none},${GPU_MEM},${DRIVER},${MODE},${STREAM_COPY},${STREAM_TRIAD},${NV_SW},${NV_SR},${NV_RR},${S3_MB},${S3_MBS}"
ROWS=()
API="http://127.0.0.1:${OLLAMA_PORT}"
if [[ -n "$MODELS" ]] && curl -sf "${API}/api/version" >/dev/null; then
  prompt_body=$(for i in $(seq 1 60); do echo "2026-09-25T12:00:${i}Z app=svc-${i} level=WARN msg=\"request latency above threshold\" latency_ms=$((i * 37)) path=/api/v1/items/${i}"; done)
  for model in $(echo "$MODELS" | tr ',' ' '); do
    size_gb=$(curl -s "${API}/api/tags" | jq -r --arg m "$model" '.models[] | select(.name == $m) | .size / 1e9 * 100 | floor / 100')
    [[ -n "$size_gb" ]] || { log "model ${model} not present - skipped"; continue; }
    log "LLM ${model} (${size_gb} GB): warm-up + prefill/decode..."
    curl -s -m 600 "${API}/api/generate" -d "$(jq -n --arg m "$model" '{model:$m, prompt:"hi", stream:false, keep_alive:-1, options:{num_predict:1}}')" >/dev/null
    # unique first line defeats Ollama's prompt-prefix cache, so prefill is really measured
    prompt="run ${RANDOM}${RANDOM}: summarize the main problems in these logs.
${prompt_body}"
    r=$(curl -s -m 900 "${API}/api/generate" -d "$(jq -n --arg m "$model" --arg p "$prompt" \
      '{model:$m, prompt:$p, stream:false, keep_alive:-1, options:{temperature:0, seed:42, num_predict:256}}')")
    pc=$(jq -r '.prompt_eval_count // 0' <<<"$r"); pd=$(jq -r '.prompt_eval_duration // 0' <<<"$r")
    ec=$(jq -r '.eval_count // 0' <<<"$r");        ed=$(jq -r '.eval_duration // 0' <<<"$r")
    ptps=$(awk -v c="$pc" -v d="$pd" 'BEGIN { if (d > 0) printf "%.1f", c / (d / 1e9) }')
    dtps=$(awk -v c="$ec" -v d="$ed" 'BEGIN { if (d > 0) printf "%.1f", c / (d / 1e9) }')
    gbs=$(awk -v s="$size_gb" -v t="$dtps" 'BEGIN { if (t > 0) printf "%.0f", s * t }')
    log "  prefill ${pc} tok @ ${ptps} tok/s, decode ${ec} tok @ ${dtps} tok/s, implied GPU mem BW ~${gbs} GB/s"
    ROWS+=("${HOST},${model},${size_gb},${pc},${ptps},${ec},${dtps},${gbs}")
  done
else
  log "Ollama not reachable or MODELS empty - LLM tests skipped"
fi
[[ ${#ROWS[@]} -gt 0 ]] || ROWS=("${HOST},,,,,,,")

[[ -f "$LOCAL_CSV" ]] || echo "$HEADER" > "$LOCAL_CSV"
run_csv=$(mktemp)
{ echo "$HEADER"; printf '%s\n' "${ROWS[@]}"; } > "$run_csv"
tail -n +2 "$run_csv" >> "$LOCAL_CSV"
if [[ -n "$S3_BUCKET" ]]; then
  dest="${S3_URI}/$(date -u +%Y%m%dT%H%M%SZ)-${ITYPE}-${IID}.csv"
  aws s3 cp "$run_csv" "$dest" --region "$AWS_REGION" --only-show-errors && log "uploaded ${dest}"
fi
echo
column -t -s, "$run_csv" 2>/dev/null || cat "$run_csv"
rm -f "$run_csv"
HBEOF
chmod 755 "${BIN}/lab02-hostbench"

echo
echo "Installed:"
for t in htop btop nvtop nvitop gpustat glances iotop iftop iostat tmux llmtop fio stream stress-ng nvme lab02-hostbench; do
  printf '  %-8s %s\n' "$t" "$(command -v "$t" || echo MISSING)"
done
cat <<'EOF'

Quick use (as root / sudo -i):
  btop                      host + GPU (keys 5/6 toggle GPU boxes)
  nvtop | nvitop            GPU util/memory/processes (ollama runner)
  gpustat -i 1              one-line GPU status, refresh 1s
  glances                   everything, incl. GPU and disk/network
  nvidia-smi dmon -s pucm   GPU power/util/clock/memory per second
  iostat -xm 2              NVMe throughput (S3 model restore)
  iftop -i ens5             network (S3 / tunnel traffic)
  llmtop                    loaded models + GPU + last Ollama requests
  tmux new -s mon           keep views open across SSM reconnects
  lab02-hostbench quick     STREAM + NVMe fio + S3 + LLM prefill/decode -> CSV (+ S3); 'full' = longer
  stream                    memory bandwidth only (Triad MB/s = the number to compare)
  fio --name=r --filename=/data/t --rw=read --bs=1M --size=4G --direct=1 --iodepth=32 --ioengine=libaio
EOF
