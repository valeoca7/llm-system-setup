#!/bin/bash
# lab02 - backend-neutral LLM metering (lab02-meter proxy + lab02-metrics recorder), run as root; config /etc/lab02/meter.env
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
BIN=/usr/local/bin
mkdir -p /etc/lab02 /var/lib/lab02/meter /var/lib/lab02/metrics

[[ -f /etc/lab02/meter.env ]] || cat > /etc/lab02/meter.env <<'EOF'
# lab02-meter / lab02-metrics config. After a change: systemctl restart lab02-meter
METER_LISTEN=127.0.0.1:18080
# Backend the proxy forwards to: Ollama http://127.0.0.1:11434 | sglang http://127.0.0.1:30000 | vLLM http://127.0.0.1:8000
METER_BACKEND=http://127.0.0.1:11434
# Backend Prometheus endpoint for KV-cache/queue gauges (sglang/vLLM: <backend>/metrics); empty for Ollama
BACKEND_METRICS_URL=
EOF

cat > "${BIN}/lab02-meter" <<'PYEOF'
#!/usr/bin/env python3
"""lab02-meter - metering reverse proxy for LLM backends (stdlib only); tokens from Ollama final object or OpenAI usage."""
import http.client, json, os, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LISTEN = os.environ.get("METER_LISTEN", "127.0.0.1:18080")
BACKEND = urllib.parse.urlsplit(os.environ.get("METER_BACKEND", "http://127.0.0.1:11434"))
LOG = os.environ.get("METER_LOG", "/var/lib/lab02/meter/requests.jsonl")
BHOST, BPORT = BACKEND.hostname, BACKEND.port or 80
METERED = ("/api/generate", "/api/chat", "/v1/chat/completions", "/v1/completions")
HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te",
       "trailers", "transfer-encoding", "upgrade", "content-length", "host"}

lock = threading.Lock()
C = {"requests_total": 0, "requests_failed_total": 0, "prompt_tokens_total": 0,
     "completion_tokens_total": 0, "request_seconds_total": 0.0, "in_flight": 0}
os.makedirs(os.path.dirname(LOG), exist_ok=True)
logf = open(LOG, "a", buffering=1)


def usage_of(obj):
    if not isinstance(obj, dict):
        return None
    if "eval_count" in obj or "prompt_eval_count" in obj:          # Ollama native, final object
        return int(obj.get("prompt_eval_count") or 0), int(obj.get("eval_count") or 0)
    u = obj.get("usage")                                             # OpenAI-compatible
    if isinstance(u, dict):
        return int(u.get("prompt_tokens") or 0), int(u.get("completion_tokens") or 0)
    return None


def parse_line(ln):
    ln = ln.strip()
    if ln.startswith(b"data:"):
        ln = ln[5:].strip()
    if not ln.startswith(b"{"):
        return None
    try:
        return usage_of(json.loads(ln))
    except ValueError:
        return None


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_GET(self):
        if self.path == "/lab02/metrics":
            with lock:
                snap = dict(C)
            body = "".join("lab02_meter_%s %s\n" % kv for kv in snap.items()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.forward()

    do_POST = do_PUT = do_DELETE = lambda self: self.forward()

    def forward(self):
        t0 = time.time()
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n) if n else b""
        path = self.path.split("?")[0]
        metered = self.command == "POST" and path.startswith(METERED)
        model, stream = None, False
        if metered and body:
            try:
                req = json.loads(body)
                model = req.get("model")
                stream = bool(req.get("stream", path.startswith("/api/")))  # Ollama native streams by default
                if path.startswith("/v1/") and stream:
                    so = req.get("stream_options") or {}
                    if not so.get("include_usage"):
                        so["include_usage"] = True
                        req["stream_options"] = so
                        body = json.dumps(req).encode()
            except ValueError:
                pass
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP}
        headers["Host"] = "%s:%s" % (BHOST, BPORT)
        if body or self.command in ("POST", "PUT"):
            headers["Content-Length"] = str(len(body))
        if metered:
            with lock:
                C["in_flight"] += 1
        status, ttft, ptok, ctok, err, sent = 0, None, 0, 0, "", False
        try:
            conn = http.client.HTTPConnection(BHOST, BPORT, timeout=3600)
            conn.request(self.command, self.path, body=body or None, headers=headers)
            resp = conn.getresponse()
            status = resp.status
            self.send_response(status)
            for k, v in resp.getheaders():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            sent = True
            buf = b""
            while True:
                chunk = resp.read1(65536)
                if not chunk:
                    break
                if ttft is None:
                    ttft = time.time() - t0
                self.wfile.write(b"%x\r\n%s\r\n" % (len(chunk), chunk))
                self.wfile.flush()
                if metered:
                    buf += chunk
                    *lines, buf = buf.split(b"\n")
                    for ln in lines:
                        u = parse_line(ln)
                        if u:
                            ptok, ctok = u
            if metered and buf:
                u = parse_line(buf)
                if u:
                    ptok, ctok = u
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
            conn.close()
        except Exception as e:  # backend down, client gone, timeout
            err = str(e)[:200]
            if not sent:
                try:
                    self.send_error(502, "lab02-meter: backend error")
                except Exception:
                    pass
        if not metered:
            return
        dt = time.time() - t0
        gen = (dt - ttft) if (stream and ttft is not None and dt - ttft > 0.05) else dt
        ok = 200 <= status < 300 and not err
        with lock:
            C["in_flight"] -= 1
            C["requests_total"] += 1
            C["requests_failed_total"] += 0 if ok else 1
            C["prompt_tokens_total"] += ptok
            C["completion_tokens_total"] += ctok
            C["request_seconds_total"] += dt
            logf.write(json.dumps({
                "ts": round(t0, 3), "path": path, "model": model, "stream": stream, "status": status,
                "latency_s": round(dt, 4), "ttft_s": round(ttft, 4) if ttft is not None else None,
                "prompt_tokens": ptok, "completion_tokens": ctok,
                "gen_tps": round(ctok / gen, 2) if ctok and gen > 0 else None, "error": err}) + "\n")


if __name__ == "__main__":
    host, port = LISTEN.rsplit(":", 1)
    srv = ThreadingHTTPServer((host, int(port)), Proxy)
    srv.daemon_threads = True
    print("lab02-meter %s -> %s:%s, log %s" % (LISTEN, BHOST, BPORT, LOG), flush=True)
    srv.serve_forever()
PYEOF
chmod 755 "${BIN}/lab02-meter"

cat > /etc/systemd/system/lab02-meter.service <<'EOF'
[Unit]
Description=lab02 metering proxy (client -> lab02-meter -> LLM backend)
After=network-online.target
[Service]
EnvironmentFile=/etc/lab02/meter.env
ExecStart=/usr/local/bin/lab02-meter
Restart=always
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF

cat > "${BIN}/lab02-metrics" <<'SHEOF'
#!/bin/bash
# lab02-metrics start <label> [interval_s] | stop | status | list | show <run>
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo -E "$0" "$@"
export HOME="${HOME:-/root}"
[[ -f /etc/lab02/node.env ]] && { set -a; . /etc/lab02/node.env; set +a; }
[[ -f /etc/lab02/meter.env ]] && { set -a; . /etc/lab02/meter.env; set +a; }
ROOT=/var/lib/lab02/metrics
CUR="${ROOT}/current"
METER_URL="http://${METER_LISTEN:-127.0.0.1:18080}/lab02/metrics"
REQLOG=/var/lib/lab02/meter/requests.jsonl
S3_URI="s3://${S3_BUCKET:-}/${S3_PREFIX:-lab02}/metrics"

imds() {
  local t; t=$(curl -s -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')
  curl -s -m 2 -H "X-aws-ec2-metadata-token: $t" "http://169.254.169.254/latest/meta-data/$1"
}

HEADER="ts,elapsed_s,gpu_util_pct,gpu_mem_used_mib,gpu_mem_total_mib,gpu_power_w,gpu_sm_clock_mhz,gpu_temp_c,cpu_util_pct,load1,mem_used_mib,mem_cached_mib,net_rx_mbs,net_tx_mbs,disk_read_mbs,disk_write_mbs,in_flight,rps,failed_rps,prompt_tps,completion_tps,backend_running,backend_waiting,kv_cache_pct,backend_vram_mib"

meter_counters() {  # requests failed prompt completion in_flight
  curl -s -m 1 "$METER_URL" 2>/dev/null | awk '
    /requests_total /{r=$2} /requests_failed_total/{f=$2} /prompt_tokens_total/{p=$2}
    /completion_tokens_total/{c=$2} /in_flight/{i=$2} END{printf "%s %s %s %s %s", r+0, f+0, p+0, c+0, i+0}'
}

backend_gauges() {  # running waiting kv_pct vram_mib
  if [[ -n "${BACKEND_METRICS_URL:-}" ]]; then
    curl -s -m 1 "$BACKEND_METRICS_URL" 2>/dev/null | awk '
      /^#/ {next}
      /^(vllm:num_requests_running|sglang:num_running_reqs)[ {]/ {run+=$NF}
      /^(vllm:num_requests_waiting|sglang:num_queue_reqs)[ {]/ {wait+=$NF}
      /^(vllm:kv_cache_usage_perc|vllm:gpu_cache_usage_perc|sglang:token_usage)[ {]/ {kv=$NF*100}
      END {printf "%s %s %s -", run+0, wait+0, (kv==""?"-":sprintf("%.1f",kv))}'
  else  # Ollama: loaded models' VRAM from /api/ps; no KV/queue gauges
    local v; v=$(curl -s -m 1 "${METER_BACKEND:-http://127.0.0.1:11434}/api/ps" 2>/dev/null | jq -r '[.models[]?.size_vram] | add // 0 | . / 1048576 | floor' 2>/dev/null || echo -)
    echo "- - - ${v:--}"
  fi
}

run_loop() {  # internal: sampler, runs as transient unit
  local dir="$1" interval="$2" t0 now el
  local iface disk; iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
  disk=$(basename "$(readlink -f "$(findmnt -no SOURCE /data 2>/dev/null || echo none)")")
  read_proc() {  # cpu_total cpu_idle rx tx rd_sect wr_sect
    awk '/^cpu /{t=0; for(i=2;i<=NF;i++) t+=$i; printf "%s %s ", t, $5+$6}' /proc/stat
    awk -v i="${iface}:" '$1==i {printf "%s %s ", $2, $10}' /proc/net/dev
    awk -v d="$disk" '$3==d {printf "%s %s", $6, $10}' /proc/diskstats
  }
  echo "$HEADER" > "${dir}/samples.csv"
  t0=$(date +%s.%N)
  read -r pc_t pc_i p_rx p_tx p_rd p_wr _ <<<"$(read_proc) 0 0 0 0"
  read -r p_req p_fail p_pt p_ct _ <<<"$(meter_counters)"
  p_time=$t0
  while [[ -f "${dir}/.running" ]]; do
    sleep "$interval"
    now=$(date +%s.%N)
    read -r c_t c_i c_rx c_tx c_rd c_wr _ <<<"$(read_proc) 0 0 0 0"
    read -r c_req c_fail c_pt c_ct inflight <<<"$(meter_counters)"
    gpu=$(nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total,power.draw,clocks.sm,temperature.gpu \
      --format=csv,noheader,nounits 2>/dev/null | awk -F', ' '{u+=$1; m+=$2; t+=$3; p+=$4; c+=$5; if($6>tp)tp=$6; n++}
      END{if(n) printf "%.0f,%d,%d,%.1f,%.0f,%d", u/n, m, t, p, c/n, tp; else printf "-,-,-,-,-,-"}')
    mem=$(awk '/MemTotal/{t=$2} /MemAvailable/{a=$2} /^Cached/{c=$2} END{printf "%d,%d", (t-a)/1024, c/1024}' /proc/meminfo)
    read -r br bw bkv bvr <<<"$(backend_gauges)"
    awk -v ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" -v el="$now" -v t0="$t0" -v pt="$p_time" \
        -v ct="$c_t" -v ci="$c_i" -v pct="$pc_t" -v pci="$pc_i" -v rx="$c_rx" -v prx="$p_rx" -v tx="$c_tx" -v ptx="$p_tx" \
        -v rd="$c_rd" -v prd="$p_rd" -v wr="$c_wr" -v pwr="$p_wr" -v gpu="$gpu" -v mem="$mem" \
        -v ld="$(cut -d' ' -f1 /proc/loadavg)" -v infl="$inflight" \
        -v rq="$c_req" -v prq="$p_req" -v fl="$c_fail" -v pfl="$p_fail" -v ptk="$c_pt" -v pptk="$p_pt" -v ctk="$c_ct" -v pctk="$p_ct" \
        -v br="$br" -v bw="$bw" -v bkv="$bkv" -v bvr="$bvr" 'BEGIN {
      dt = el - pt; if (dt <= 0) dt = 1
      cpu = (ct - pct > 0) ? 100 * (1 - (ci - pci) / (ct - pct)) : 0
      printf "%s,%.1f,%s,%.1f,%s,%s,%.2f,%.2f,%.1f,%.1f,%s,%.3f,%.3f,%.2f,%.2f,%s,%s,%s,%s\n", ts, el - t0, gpu, cpu, ld, mem,
        (rx - prx) / dt / 1048576, (tx - ptx) / dt / 1048576, (rd - prd) * 512 / dt / 1048576, (wr - pwr) * 512 / dt / 1048576,
        infl, (rq - prq) / dt, (fl - pfl) / dt, (ptk - pptk) / dt, (ctk - pctk) / dt, br, bw, bkv, bvr }' >> "${dir}/samples.csv"
    pc_t=$c_t; pc_i=$c_i; p_rx=$c_rx; p_tx=$c_tx; p_rd=$c_rd; p_wr=$c_wr
    p_req=$c_req; p_fail=$c_fail; p_pt=$c_pt; p_ct=$c_ct; p_time=$now
  done
}

summarize() {  # dir -> summary.json
  local dir="$1" start end
  start=$(jq -r .start_epoch "${dir}/meta.json"); end=$(jq -r .end_epoch "${dir}/meta.json")
  jq -c --argjson s "$start" --argjson e "$end" 'select(.ts >= $s and .ts <= $e)' "$REQLOG" > "${dir}/requests.jsonl" 2>/dev/null || : > "${dir}/requests.jsonl"
  local samples reqs
  samples=$(awk -F, 'NR>1 {n++; gu+=$3; if($3>gmx)gmx=$3; if($4>gm)gm=$4; gp+=$6; cu+=$9; if($9>cmx)cmx=$9; if($11>mm)mm=$11;
      if($17>0){a++; ct+=$21; pt+=$20; r+=$18} if($21>cpk)cpk=$21; if($17>ifl)ifl=$17; if($24!="-" && $24>kv)kv=$24}
    END{printf "{\"samples\":%d,\"gpu_util_avg\":%.1f,\"gpu_util_max\":%d,\"gpu_mem_max_mib\":%d,\"gpu_power_avg_w\":%.1f,\"cpu_util_avg\":%.1f,\"cpu_util_max\":%.1f,\"mem_used_max_mib\":%d,\"active_samples\":%d,\"completion_tps_avg_active\":%.1f,\"completion_tps_peak\":%.1f,\"prompt_tps_avg_active\":%.1f,\"rps_avg_active\":%.3f,\"in_flight_max\":%d,\"kv_cache_pct_max\":%s}",
      n, (n?gu/n:0), gmx, gm, (n?gp/n:0), (n?cu/n:0), cmx, mm, a, (a?ct/a:0), cpk, (a?pt/a:0), (a?r/a:0), ifl, (kv==""?"null":kv)}' "${dir}/samples.csv")
  reqs=$(jq -s 'def pct(p): (sort | if length == 0 then null else .[((length - 1) * p | floor)] end);
      {requests: length, failed: (map(select(.status < 200 or .status >= 300 or .error != "")) | length),
       prompt_tokens: (map(.prompt_tokens) | add // 0), completion_tokens: (map(.completion_tokens) | add // 0),
       latency_p50_s: (map(.latency_s) | pct(0.5)), latency_p95_s: (map(.latency_s) | pct(0.95)),
       ttft_p50_s: (map(select(.stream) | .ttft_s) | pct(0.5)), ttft_p95_s: (map(select(.stream) | .ttft_s) | pct(0.95)),
       gen_tps_p50: (map(.gen_tps // empty) | pct(0.5)), gen_tps_p05: (map(.gen_tps // empty) | pct(0.05))}' "${dir}/requests.jsonl")
  jq -n --slurpfile m "${dir}/meta.json" --argjson s "$samples" --argjson r "$reqs" \
    '$m[0] + {duration_s: ($m[0].end_epoch - $m[0].start_epoch | floor)} + {load: $s} + {requests: $r}
     | .requests.throughput_completion_tps = (if .duration_s > 0 then (.requests.completion_tokens / .duration_s * 10 | floor / 10) else null end)' > "${dir}/summary.json"
}

cmd="${1:-status}"; shift || true
case "$cmd" in
  start)
    label="${1:?usage: lab02-metrics start <label> [interval_s]}"; interval="${2:-2}"
    [[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "label: letters, digits, . _ - only" >&2; exit 1; }
    [[ -L "$CUR" ]] && { echo "a run is active: $(readlink "$CUR") - stop it first" >&2; exit 1; }
    systemctl is-active -q lab02-meter || echo "WARN: lab02-meter not running - no request/token metrics (systemctl start lab02-meter)" >&2
    run="$(date -u +%Y%m%dT%H%M%SZ)-${label}"; dir="${ROOT}/${run}"; mkdir -p "$dir"
    burl="${METER_BACKEND:-http://127.0.0.1:11434}"
    bver=$(curl -s -m 2 "${burl}/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)
    loaded=$(curl -s -m 2 "${burl}/api/ps" 2>/dev/null | jq -c '[.models[]? | {name, size_vram, context_length}]' 2>/dev/null || true)
    [[ -n "$loaded" ]] || loaded='[]'
    config=$(jq -n 'env | with_entries(select(.key | test("^(OLLAMA_|MODELS$|METER_|BACKEND_)")))')
    jq -n --arg run "$run" --arg label "$label" --argjson start "$(date +%s)" --argjson interval "$interval" \
      --arg itype "$(imds instance-type)" --arg az "$(imds placement/availability-zone)" --arg iid "$(imds instance-id)" \
      --arg gpu "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)" \
      --argjson gpus "$(nvidia-smi -L 2>/dev/null | wc -l | tr -d ' ')" \
      --arg driver "$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)" \
      --argjson vcpu "$(nproc)" --argjson mem_gib "$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)" \
      --arg backend "$burl" --arg backend_version "$bver" --argjson loaded "$loaded" --argjson config "$config" \
      '{run: $run, label: $label, start_epoch: $start, interval_s: $interval, instance_type: $itype, az: $az, instance_id: $iid,
        gpu: $gpu, gpu_count: $gpus, driver: $driver, vcpu: $vcpu, mem_gib: $mem_gib,
        backend_url: $backend, backend_version: $backend_version, loaded_models: $loaded, config: $config}' > "${dir}/meta.json"
    touch "${dir}/.running"; ln -sfn "$dir" "$CUR"
    systemd-run --unit="lab02-metrics-run" --collect --quiet /usr/local/bin/lab02-metrics _run "$dir" "$interval"
    echo "recording ${run} every ${interval}s -> ${dir}  (stop: lab02-metrics stop)"
    ;;
  _run) run_loop "$1" "$2" ;;
  stop)
    [[ -L "$CUR" ]] || { echo "no active run" >&2; exit 1; }
    dir=$(readlink -f "$CUR"); rm -f "${dir}/.running" "$CUR"
    sleep 1; systemctl stop lab02-metrics-run 2>/dev/null || true
    tmp=$(mktemp); jq --argjson e "$(date +%s)" '.end_epoch = $e' "${dir}/meta.json" > "$tmp" && mv "$tmp" "${dir}/meta.json"
    summarize "$dir"
    if [[ -n "${S3_BUCKET:-}" ]]; then
      aws s3 cp "$dir" "${S3_URI}/$(basename "$dir")/" --recursive --region "${AWS_REGION:-us-west-2}" --only-show-errors \
        && echo "uploaded ${S3_URI}/$(basename "$dir")/" >&2
    fi
    jq . "${dir}/summary.json"
    ;;
  status)
    if [[ -L "$CUR" ]]; then d=$(readlink -f "$CUR"); echo "recording: $(basename "$d") ($(($(wc -l < "${d}/samples.csv") - 1)) samples)"; tail -n 3 "${d}/samples.csv"
    else echo "no active run"; fi
    systemctl is-active -q lab02-meter && echo "lab02-meter: active -> ${METER_BACKEND:-}" || echo "lab02-meter: NOT running"
    ;;
  list) ls -1 "$ROOT" | grep -v '^current$' || true ;;
  show) jq . "${ROOT}/${1:?usage: lab02-metrics show <run>}/summary.json" ;;
  *) echo "usage: lab02-metrics start <label> [interval_s] | stop | status | list | show <run>" >&2; exit 1 ;;
esac
SHEOF
chmod 755 "${BIN}/lab02-metrics"

systemctl daemon-reload
systemctl enable -q lab02-meter
systemctl restart lab02-meter
sleep 1
systemctl is-active -q lab02-meter && echo "lab02-meter active: $(grep -E '^METER_(LISTEN|BACKEND)=' /etc/lab02/meter.env | tr '\n' ' ')" \
  || { echo "lab02-meter failed to start:"; journalctl -u lab02-meter -n 20 --no-pager; exit 1; }
