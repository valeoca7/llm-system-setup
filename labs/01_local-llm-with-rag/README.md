# Local LLM with RAG

A small, local-only RAG learning lab based on the supplied LinkedIn guide. By default it uses `qwen3:1.7b` to generate answers and `qwen3-embedding:0.6b` for retrieval. Ollama runs both models locally; `app.py` chunks `data/knowledge.txt`, stores embeddings in `storage/index.json`, retrieves the closest chunks with cosine similarity, then asks the LLM to answer only from that context.

`data/knowledge.txt` is a symlink to the repository-wide `shared/data/labs-0x-knowledge.txt`. Labs 01 and 02 therefore read and update the same canonical knowledge source.

## Run order

From this directory, run the scripts in numeric order. They are safe to rerun.

```bash
./00-check-host.sh
./01-install-prerequisites.sh
./02-install-ollama.sh
./03-pull-models.sh
./04-create-python-environment.sh
./05-smoke-test.sh
./06-run-assistant.sh
```

The install scripts support macOS and Linux. On macOS they use Homebrew for the scripted installation and start the Ollama application. On Linux they support `apt`, `dnf`, or `pacman`, use Ollama's official installer, and start the `systemd` service when available. Shell scripts must be executable; run `chmod +x [0-9][0-9]-*.sh` once if the checkout did not preserve executable permissions.

`04-create-python-environment.sh` creates `.venv` in this directory and installs with `.venv/bin/python -m pip`; `05-smoke-test.sh` and `06-run-assistant.sh` also use only that interpreter. This intentionally avoids macOS/Homebrew's PEP 668 “externally managed environment” error. Do not run `pip` or `pip3 install -r requirements.txt` outside `.venv`.

## Stop the lab

From this directory, run `make stop`; from the repository root, run `make lab-01-stop`. The `99-stop-lab.sh` stop script terminates assistant processes launched with this lab's `app.py` path and stops the local Ollama runtime. Ollama is shared by all local Ollama workloads, so stop it only when you also intend to interrupt other Ollama models or applications.

To use different local models or an Ollama endpoint, set environment variables before scripts 03–06:

```bash
LLM_MODEL=your-model EMBEDDING_MODEL=your-embedding-model OLLAMA_BASE_URL=http://127.0.0.1:11434 ./03-pull-models.sh
```

## Review of the source implementation

The source guide is a good first implementation: it makes the RAG stages visible, uses the current Ollama `/api/embed` and `/api/chat` endpoints, persists a local index, and detects source-file changes by hash. Its main limitations are operational rather than conceptual: it is Ubuntu-specific, assumes `systemd`, has no integrity check for a malformed index, writes the index non-atomically, uses character chunking that can split words, and always sends the top results even when none is relevant.

This lab keeps the deliberately simple JSON-index design but adds cross-platform setup, model availability checks, atomic index writes, embedding/index validation, whitespace-aware chunk boundaries, a relevance threshold, a non-interactive smoke test, environment-based configuration, and a prompt-injection boundary for the retrieved text. NumPy is unnecessary for this small lab, so cosine similarity is implemented with the Python standard library.

## Caveats

- `qwen3:1.7b` and `qwen3-embedding:0.6b` are downloaded models. Disk, RAM, and first-response time depend on your hardware; the preflight script recommends at least 8 GiB RAM and 10 GiB free space.
- macOS requires Sonoma 14+ for the current Ollama app. Apple Silicon gets GPU acceleration; Intel Macs use CPU inference. Linux GPU acceleration requires separately configured compatible drivers.
- The JSON index is suitable only for small learning datasets. For larger corpora, use token-aware chunking, metadata/citations, batched ingestion, evaluations, and a vector database or ANN index.
- Retrieval thresholding reduces obviously irrelevant answers but does not make the result factual. Local models can still misunderstand context; do not use this lab for safety-critical decisions.
- Changing `LLM_MODEL` does not require reindexing, but changing `EMBEDDING_MODEL`, `CHUNK_SIZE`, or `CHUNK_OVERLAP` does; the application detects those changes and rebuilds automatically.
