# laguna-xs-2.1 - OpenViking initial data ingestion (Terraform repo)

Date: 2026-09-26, window 04:52:35-04:52:56 UTC (sample of 6 requests, lab02-meter requests.jsonl)

## Setup

| Item | Value |
|---|---|
| Task | ov (OpenViking) initial data ingestion of a Terraform repo |
| Node | g6.4xlarge spot, eu-north-1a, 1x NVIDIA L4 24 GB, 16 vCPU, 64 GiB, baked lab02 AMI |
| Backend | Ollama 0.34.4, via lab02-meter proxy (SSM tunnel -> :18080 -> :11434) |
| Model | `laguna-xs-2.1:latest` (33B MoE, 3B active, Q4_K_M 20 GB), 100% GPU |
| Settings | ctx 65536, `OLLAMA_NUM_PARALLEL=1`, KV cache q8_0, 1 loaded model |
| Client calls | `/api/generate`, `stream: false`, ~1 new request every 2.8 s |

## Results

| Metric | Value |
|---|---|
| Requests | 6, all 200 |
| Prompt tokens / request | avg 1024 (598-1214) |
| Completion tokens / request | avg 191 (163-268) |
| Latency / request | avg 7.66 s (6.72-8.64) |
| End-to-end tok/s / request (`gen_tps`) | avg 25.0 (20.2-33.7) |
| Throughput (whole window) | 54.9 output tok/s, 295 prompt tok/s, 0.29 req/s |
| Avg requests in flight | 2.2 |

## Reading

- `gen_tps` here is end-to-end (non-streaming): it includes queue wait and prompt processing,
  not the model's generation speed (~100 tok/s on this node, 1 slot, measured by loadtest
  `20260926T031316Z-laguna-xs21-q4-ctx64k-p1`).
- Estimated service time per request ~2.9 s (~1 s prefill at ~1000 prompt tok/s + ~1.9 s
  decode at ~100 tok/s) vs arrival every ~2.8 s -> the single slot is saturated; ~4.7 s of the
  7.7 s latency is queue wait.
- The client sends ~2 requests concurrently while the node served 1 at a time.

## Next

- Same workload with `OLLAMA_NUM_PARALLEL=2` + `OLLAMA_CONTEXT_LENGTH=32768` (2 slots still
  100% GPU) - expected: queue wait mostly gone, higher throughput.
- Compare with `qwen3.8:27b` (ctx 64K, 2 slots, now serving; ~30 tok/s generation) on the same
  ingestion - quality vs speed.
- Record it as a run: `./lab02.sh metrics start ov-ingest-tfrepo-<model>-<settings>` ... `stop`.
