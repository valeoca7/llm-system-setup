# lab02 - spot GPU LLM node (g7e + AL2023 + Ollama), SSM only

One spot instance, no SSH / key pair / SG ingress. Access is AWS Session Manager: `send-command`
for provisioning, port forwarding for the Ollama API. Model weights live in S3
(`s3://<bucket>/lab02/models/ollama/`) and are served from the instance's local NVMe
(ephemeral), restored on every boot.

```
laptop                                   AWS (one region, public subnets)
------                                   ------------------------------------------------
lab02.sh launch      --EC2 API-->        g7e.8xlarge spot, baked AL2023 AMI (30 GB root)
                                           user-data -> /etc/lab02/node.env
                                           lab02-boot.service:
                                             NVMe -> XFS /data
                                             S3 models/ollama -> /data  (CRT, only needed blobs)
                                             ollama serve 127.0.0.1:11434, models loaded
lab02.sh tunnel      --SSM-->            port forward 11434
localhost:21434  <-----------------------'
  benchmark.sh / local tools / log analyzer
```

## Prerequisites

- AWS: VPC with public subnets (internet route, no ingress needed), an egress-only security group,
  an EC2 instance profile with S3 access to the bucket + `AmazonSSMManagedInstanceCore`, an S3 bucket
  in the same region.
- Set `SUBNET_MAP` (or `SUBNET_ID`), `SECURITY_GROUP_ID` (or `SECURITY_GROUP_NAME`),
  `IAM_INSTANCE_PROFILE`, `S3_BUCKET`, `AWS_PROFILE` in `values.export` or an `env.*.export` file.
- Local: `aws` v2, `jq`, `session-manager-plugin`.

## Files

| File | Runs on | Purpose |
|---|---|---|
| `scripts/values.export` | laptop | all config; auto-sourced by `lab02.sh`, env overrides win |
| `scripts/lab02.sh` | laptop | control CLI: launch, provision, tunnel, bake, terminate, ... |
| `scripts/provision_node.sh` | node (root) | install + boot steps; shipped via S3 + SSM |
| `scripts/node_tools.sh` | node (root) | monitoring + benchmark tools; shipped with `provision`, run as its last (`tools`) step |
| `scripts/node_metering.sh` | node (root) | `lab02-meter` metering proxy + `lab02-metrics` run recorder |
| `scripts/loadtest_node.sh` | node (root) | fixed repeatable workload, run by `lab02.sh loadtest` |
| `scripts/env.test-<region>.export` | laptop | per-region start values: usw1, usw2, use1, use2, euw1, euc1, eun1, sae1, apne1 (placeholders to fill in) |
| `scripts/benchmark.sh` | laptop | benchmark over the tunnel -> `results/bench_results.csv` |
| `scripts/bench_endpoints.json` | laptop | endpoints for the POC models on `localhost:21434` |

## 1. Bake the AMI (once, and after driver/Ollama changes)

```bash
cd scripts && source env.test-usw2.export   # fill in the <placeholders> first
DRY_RUN=1 ./lab02.sh launch     # validate request + permissions, nothing is created
./lab02.sh spot-price           # price per AZ vs MAX_SPOT_PRICE
./lab02.sh launch               # AMI_ID empty -> latest base AL2023; tries every AZ in
                                # SUBNET_MAP round-robin (LAUNCH_ROUNDS passes)
./lab02.sh provision            # packages, NVIDIA driver (+1 auto reboot), Ollama, boot service,
                                # NVMe mount, models (pull once -> pushed to S3), load, test,
                                # tools (node_tools.sh; non-fatal - rerun: ./lab02.sh provision tools)
./lab02.sh logs                 # (second terminal) live node log
./lab02.sh node-status          # GPU, NVMe, loaded models
./lab02.sh bake                 # bake-prep + create-image, prints ami-...
# put AMI_ID="ami-..." into values.export
./lab02.sh terminate
```

## 2. Run a session (baked AMI)

```bash
./lab02.sh launch               # user-data starts lab02-boot.service
./lab02.sh wait-ready           # NVMe + S3 restore + models in GPU
./lab02.sh tunnel               # keep open: localhost:21434 -> node:11434
```

In another terminal:

```bash
curl -s localhost:21434/api/tags | jq '.models[].name'
./benchmark.sh bench_endpoints.json bench_prompts.txt g7e.8xlarge-spot-usw2a

# local working env / log analyzer - OpenAI-compatible
export OPENAI_BASE_URL=http://localhost:21434/v1
export OPENAI_API_KEY=ollama            # any non-empty value
```

When done: `./lab02.sh terminate`. The instance also powers off (= terminates) after
`TTL_HOURS` (default 8); extend with `./lab02.sh ttl 4`.

## Models

Default (`MODELS`): `gpt-oss:20b` (MoE 21B / 3.6B active, 14 GB, parallel-friendly). Alternative:
`qwen3.8:27b` (dense 27B, 17 GB, ~23 tok/s total on L4, 2 slots max useful). Both fit any 24 GB+ GPU.

- Per launch: `MODELS="qwen3.8:27b" ./lab02.sh launch`
- On a running node: `./lab02.sh set-models 'qwen3.8:27b'` (both: `set-models 'gpt-oss:20b qwen3.8:27b'`
  with `OLLAMA_MAX_LOADED_MODELS=2`)

A model not yet in S3 is pulled from ollama.com once and pushed to S3; after that every boot
restores it from S3 only.

TypeSafe Jev (github.com/yibie/awesome-jev) is a hosted API (api.typesafe.ai / OpenRouter)
with no open weights - it cannot run on this node. Use it as a remote reference against
`gpt-oss:20b` / `qwen3.8:27b` as judge.

## Performance runs (repeatable, comparable across models / configs / backends)

Every client request goes through `lab02-meter` on the node (tunnel target `127.0.0.1:18080` ->
backend), so request/token metrics are measured the same way for Ollama, sglang or vLLM.

```bash
./lab02.sh tunnel                                    # terminal 1 (metered; TUNNEL_TARGET=backend = direct)
./lab02.sh metrics start qwen38-27b-q4-ctx64k-p2     # terminal 2: label = what you are testing
#   ... run your load: local tools, log analyzer, benchmark.sh, 4x parallel, ...
./lab02.sh metrics stop                              # summary.json printed + uploaded to S3
./lab02.sh metrics-report                            # all runs, all regions -> table + results/metrics_all.csv
./lab02.sh metrics-pull <run>                        # full data -> results/metrics/<run>/
```

Per run (`/var/lib/lab02/metrics/<UTC>-<label>/` on the node, `s3://<bucket>/lab02/metrics/<run>/`):

| File | Content |
|---|---|
| `meta.json` | instance type/AZ, GPU/driver, vCPU/RAM, backend URL + version, loaded models, all `OLLAMA_*` settings |
| `samples.csv` | every `interval_s` (default 2): GPU util/mem/power/clock/temp, CPU %, load, RAM used/cached, net rx/tx, NVMe read/write MB/s, in-flight, req/s, failed/s, prompt tok/s, completion tok/s, backend running/waiting, KV cache % (sglang/vLLM), backend VRAM (Ollama) |
| `requests.jsonl` | per request: endpoint, model, stream, status, latency, TTFT, prompt/completion tokens, generation tok/s |
| `summary.json` | meta + load (avg/max/peak) + requests (count, failed, tokens, latency/TTFT p50/p95, gen tok/s p50/p05, throughput) |

Comparable runs: same prompts/load script, one change at a time (model, quant, ctx, parallel, KV
type, backend, instance), label says what changed. Other backends: set `METER_BACKEND` (and
`BACKEND_METRICS_URL=<backend>/metrics` for KV-cache/queue gauges) in `/etc/lab02/meter.env`,
`systemctl restart lab02-meter` - the client side and the report stay identical.

## S3 model stores (per backend) and cleanup

```
s3://<bucket>/lab02/models/ollama/{manifests,blobs}/   Ollama store layout (restored per model)
s3://<bucket>/lab02/models/hf/<org>/<repo>/            sglang / vLLM weights (future)
```

- Restore: only the manifests + blobs of the models in `MODELS` are downloaded to the NVMe.
- Save: per model (manifest + its blobs, missing files only) after a pull - no whole-store sync,
  so pruned models do not come back.
- Review / clean up:

```bash
./lab02.sh s3-models list                                   # models, sizes, unreferenced blobs
./lab02.sh s3-models prune --keep 'gpt-oss:20b qwen3.8:27b'  # dry run: what would be deleted
./lab02.sh s3-models prune --keep 'gpt-oss:20b qwen3.8:27b' --apply
./lab02.sh s3-models list --backend hf                      # other backends: per <org>/<repo>
```

## Host benchmarks (IO, memory bandwidth, S3, LLM) and instance comparison

Installed by `./lab02.sh provision` (last step of `all`), so a baked AMI already has them.
Reinstall/update on a running node: `./lab02.sh provision tools`.

Run (node must be `ready`; don't run during `provision` - both use dnf/NVMe):

```bash
./lab02.sh hostbench quick      # ~3-5 min: STREAM, fio 15s/test, S3 blob, LLM per model
./lab02.sh hostbench full       # ~8-12 min: fio 60s/test on 4 x 8G files
./lab02.sh hostbench-report     # all regions' results + current spot price + $/Mtok -> results/hostbench_all.csv
```

On the node directly: `sudo lab02-hostbench quick`; history in `/var/log/lab02-hostbench.csv`;
each run also lands in `s3://<bucket>/lab02/hostbench/<ts>-<type>-<instance>.csv`.

| Test | Tool / setting | Metric to compare |
|---|---|---|
| Memory bandwidth | STREAM, all vCPUs, 1.8 GiB arrays | `stream_triad_mbs` - CPU inference speed scales with it |
| Local NVMe | fio `--direct=1` libaio, 4 jobs: 1M seq QD32, 4k rand QD64 | seq read MB/s (model load), 4k IOPS |
| S3 -> NVMe | largest model blob, aws cli CRT | MB/s - boot-time model restore |
| LLM prefill | ~1.5k-token log prompt, unique prefix (no cache hit) | `prompt_tps` - long-prompt apps (log analyzer) |
| LLM decode | 256 tokens, temperature 0, seed 42 | `decode_tps`, `$/Mtok` |
| GPU bandwidth (derived) | model size x decode tok/s | `implied_gpu_gbs` |

Sanity checks - results are plausible when:

- `implied_gpu_gbs` is ~50-80% of the GPU's spec memory bandwidth: L4 300 GB/s, A10G 600,
  L40S 864, RTX PRO 6000 (g7e) ~1800. Much lower = model not fully on GPU (`ollama ps`
  PROCESSOR must be `100% GPU`) or CPU-bound small model.
- `s3_download_mbs` stays below the instance network cap (e.g. "up to 10 Gbps" = ~1150 MB/s).
- Repeat runs agree within ~5-10% (STREAM/fio); a big outlier = noisy neighbour or a
  concurrent job - rerun. Watch live with `btop`/`nvtop`/`iostat -xm 2` in a second session.

Over-/under-provisioning: during `benchmark.sh` (sequential + 4-parallel) watch GPU util and VRAM
(`nvtop`, `llmtop`) and host CPU/RAM (`btop`). GPU saturated + host CPU idle = right-sized GPU,
oversized host (on g6 the smaller size has the same L4). VRAM near full / CPU split in
`ollama ps` = need a bigger GPU (g6e 48 GB, g7e 96 GB).

## Other commands

```bash
./lab02.sh help
./lab02.sh status | spot-price | images
./lab02.sh shell                                  # interactive root-capable shell
./lab02.sh exec 'nvidia-smi; df -h /data'
./lab02.sh provision models                       # run one provision_node.sh step
./lab02.sh image-delete ami-...                   # AMI + snapshots
```

## Notes

- NVMe instance store survives reboot, not stop/terminate. One-time spot cannot stop anyway.
- Spot interruption = terminate; relaunch restores everything from the AMI + S3.
  `lab02-spot-watch.service` (installed by user-data, runs from first boot) polls IMDS every 5s:
  rebalance recommendation -> logged; interruption notice (~2 min) -> status `interrupting`,
  completed models synced to S3 (<=100s, partial pulls excluded), node log uploaded to
  `s3://<bucket>/lab02/node-logs/`. On the node: `journalctl -u lab02-spot-watch`.
  `./lab02.sh status` shows why the last instance ended; a running `provision`/`exec` stops
  waiting as soon as the instance is gone.
- SSM command output (full): `s3://<bucket>/lab02/ssm-logs/<command-id>/`.
- Session Manager idle timeout (account preference, default 20 min) can close an idle tunnel;
  rerun `./lab02.sh tunnel`.
