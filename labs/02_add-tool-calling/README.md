# Local RAG Agent with Tool Calling

Lab 02 upgrades Lab 01's fixed retrieval pipeline into a local agent that lets `qwen3:1.7b` choose among three trusted tools:

Its `data/knowledge.txt` path is a symlink to `shared/data/labs-0x-knowledge.txt`, the same canonical knowledge source used by Lab 01.

- `search_knowledge_file(query)` lazily loads/rebuilds the local RAG index and returns relevant chunks.
- `calculator(expression)` evaluates arithmetic through a restricted Python AST; it never uses `eval`.
- `current_time(timezone)` returns the current date and time for a validated IANA timezone.

The model only proposes a tool call. The Python application validates the name and arguments, executes an explicitly allowlisted function, appends the result to the conversation, and asks the model for its final response. Tool rounds are capped at five to prevent an infinite loop.

## Run the lab

From the repository root:

```bash
make lab-02
```

This runs the numbered scripts in order: host checks, prerequisites, Ollama installation/startup, model downloads, virtual-environment creation, verification, and the interactive agent. The scripts support macOS and Linux and are safe to rerun. To run only the already-installed lab:

```bash
cd labs/02_add-tool-calling
./05-smoke-test.sh
./06-run-agent.sh
```

Stop the agent and Ollama with `make lab-02-stop`. Ollama is shared by local workloads, so this also interrupts other applications using it.

The defaults match Lab 01: `qwen3:1.7b` for chat/tool selection and `qwen3-embedding:0.6b` for retrieval. Override them consistently for scripts 03–06, for example:

```bash
LLM_MODEL=qwen3:4b EMBEDDING_MODEL=qwen3-embedding:0.6b make lab-02
```

Tool routing generally becomes more reliable with a larger tool-capable model, at the cost of additional RAM and latency.

## Source article: six implementation steps

The supplied LinkedIn article, *Part 2/7 — Upgrading Local RAG Assistant by adding Tool Calling*, describes these steps:

1. Open the Part 1 project and activate its existing environment.
2. Preserve Part 1, then copy its RAG implementation into an importable `rag_engine.py` module. Its guarded `main()` prevents an interactive loop when imported.
3. Confirm the generation and embedding models are present in Ollama. The article uses `qwen3:1.7b` and `all-minilm`; this repository retains Lab 01's newer `qwen3-embedding:0.6b` default.
4. Keep the small raw-Python dependency set. No agent framework is introduced, so the model/tool/result loop stays visible.
5. Replace `app.py` with a tool-calling application. Define JSON tool schemas, trusted Python implementations, an explicit allowlist, argument validation, and a bounded agent loop.
6. Run and test four routing paths: local knowledge, current time, calculation, and ordinary conversation with no tool. Also test missing local knowledge.

The core loop is model → requested tool call → application validation/execution → tool result → model. The assistant's tool-call message must remain in conversation history before the tool result so the model can connect the observation to its request.

## Verification

`05-smoke-test.sh` first runs standard-library unit tests for arithmetic safety, tool allowlisting, argument parsing, timezone support, the no-tool path, and the multi-round agent loop. It then runs deterministic tool checks and two live Ollama questions covering calculator routing and lazy RAG retrieval.

Run just the unit tests without Ollama:

```bash
PYTHONPATH=. python3 -m unittest discover -s tests -v
python3 app.py --verify-tools
```

## Security and scope

- Tool names are resolved only through `AVAILABLE_TOOLS`; model-generated names are never evaluated dynamically.
- Tool arguments are untrusted. Unknown/missing fields, invalid timezones, code-like calculator input, extreme exponents, and oversized results are rejected.
- Retrieved text and tool output are treated as data, not instructions.
- The RAG index is created only if the model selects the knowledge tool. A greeting, calculation, or time question does not load it.
- Each question starts a fresh conversation. Memory and persistent session state are intentionally deferred to the next lab in the source series.
- Model routing is probabilistic, especially with a 1.7B model. Deterministic tests verify application behavior independently from routing quality.
