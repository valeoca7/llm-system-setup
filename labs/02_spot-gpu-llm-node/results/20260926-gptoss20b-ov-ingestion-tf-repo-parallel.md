# gpt-oss:20b - OpenViking ingestion (Terraform repo), 4 vs 6 parallel slots

Date: 2026-09-26. Source: lab02-meter per-request log (178 gpt-oss requests, 05:42:51-05:55:58 UTC),
raw copy `results/adhoc/gptoss20b-requests.jsonl`.

## Setup

| Item | Value |
|---|---|
| Task | ov (OpenViking) initial data ingestion of a Terraform repo |
| Node | g6.4xlarge spot, eu-north-1a, 1x NVIDIA L4 24 GB (72 W power cap), baked lab02 AMI |
| Backend | Ollama 0.34.4 via lab02-meter (tunnel -> :18080 -> :11434), client `/api/generate`, `stream: false` |
| Model | `gpt-oss:20b` (MoE 21B, ~3.6B active, MXFP4), 100% GPU |
| Settings | ctx 32768 per slot, flash attention on, KV cache f16, 1 loaded model |
| Compared | `OLLAMA_NUM_PARALLEL=4` + `vlm.max_concurrent=4`  vs  `OLLAMA_NUM_PARALLEL=6` + `vlm.max_concurrent=6` |

## Results (steady state, successful requests)

| Metric | 4 slots | 6 slots | Change |
|---|---|---|---|
| Window | 05:45:30-05:52:25 (6.9 min) | 05:52:52-05:55:58 (3.1 min) | |
| Requests | 109 | 56 | |
| **Requests / min** | **15.8** | **18.1** | **+15%** |
| **Output tok/s (total)** | **65.1** | **73.5** | **+13%** |
| Prompt tok/s (total) | 612 | 834 | +36% |
| Input / output tokens per request (avg) | 2324 / 247 | 2770 / 244 | inputs ~19% larger in the 6-slot window |
| Avg requests in flight | 3.1 | 5.2 | |
| Latency avg / p50 / p95 | 11.6 / 10.9 / 17.5 s | 17.4 / 17.2 / 23.2 s | +50% avg |
| End-to-end tok/s per request | 23.3 | 14.8 | -36% |
| VRAM | 15.5 GB | 17.1 GB | of 23 GB |
| GPU | 95-98%, 72 W cap, SM clock ~1.2 GHz (`SW Power Cap: Active`) | 95-96%, 72 W, ~1.14 GHz | power-bound in both |

Failures: 9, all at 05:51:51-05:52:28 = Ollama restart for the slot change (connections
closed/refused, then client-side broken pipes). None in steady state.

## Notes

- 6 slots gave **~+15% files/min and +13% output tok/s**; counting input work too (inputs were
  larger in the 6-slot window) total processed tokens went 677 -> 908 tok/s (+34%). Batching more
  requests gets more tokens out of the same 72 W power budget.
- Cost: every request takes ~50% longer (queue + shared GPU); fine for batch ingestion, not for
  interactive use.
- The L4 is power-capped (72 W, clocks ~60% of max) - GPU util ~95% is its ceiling; free VRAM
  (~6 GB) is not the limit. Further slots (8) likely add little; not tested.
- The 6-slot window is short (3.1 min) and files differ between windows -> treat ±10% as noise;
  re-check over a longer run with `./lab02.sh metrics start/stop`.
- Reference (same task, same node): laguna-xs-2.1 1 slot ~25 tok/s e2e per request, ~55 output
  tok/s total (queue-bound); qwen3.8:27b ~22-23 output tok/s total regardless of slots.

## Next options

- Lower gpt-oss reasoning effort (`think: "low"`) if ov allows - fewer output tokens per file.
- Smaller inputs / shorter instructions per request (prompt processing is a large share).
- vLLM/sglang backend (prefix caching of the shared ov instructions, better batching).
- Scale out: second g6.4xlarge or g6e.4xlarge (L40S, 350 W, ~3-4x).
