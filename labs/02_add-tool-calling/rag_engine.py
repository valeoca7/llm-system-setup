#!/usr/bin/env python3
"""Reusable, local-only retrieval engine carried forward from Lab 01."""

from __future__ import annotations

import hashlib
import json
import math
import os
import tempfile
from pathlib import Path
from typing import Any

import requests


PROJECT_DIR = Path(__file__).resolve().parent
DATA_FILE = PROJECT_DIR / "data" / "knowledge.txt"
INDEX_FILE = PROJECT_DIR / "storage" / "index.json"
INDEX_SCHEMA_VERSION = 1

OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://127.0.0.1:11434").rstrip("/")
EMBEDDING_MODEL = os.environ.get("EMBEDDING_MODEL", "qwen3-embedding:0.6b")
LLM_MODEL = os.environ.get("LLM_MODEL", "qwen3:1.7b")
CHUNK_SIZE = int(os.environ.get("CHUNK_SIZE", "300"))
CHUNK_OVERLAP = int(os.environ.get("CHUNK_OVERLAP", "50"))
TOP_K = int(os.environ.get("TOP_K", "3"))
MIN_SIMILARITY = float(os.environ.get("MIN_SIMILARITY", "0.15"))
REQUEST_TIMEOUT_SECONDS = int(os.environ.get("REQUEST_TIMEOUT_SECONDS", "180"))


def source_hash(file_path: Path) -> str:
    return hashlib.sha256(file_path.read_bytes()).hexdigest()


def read_knowledge_file(file_path: Path) -> str:
    if not file_path.is_file():
        raise FileNotFoundError(f"Knowledge file does not exist: {file_path}")
    text = file_path.read_text(encoding="utf-8").strip()
    if not text:
        raise ValueError(f"Knowledge file is empty: {file_path}")
    return text


def split_into_chunks(text: str, chunk_size: int, overlap: int) -> list[str]:
    """Split text into overlapping chunks, preferring whitespace boundaries."""
    if chunk_size <= 0:
        raise ValueError("CHUNK_SIZE must be greater than zero")
    if not 0 <= overlap < chunk_size:
        raise ValueError("CHUNK_OVERLAP must be non-negative and smaller than CHUNK_SIZE")

    chunks: list[str] = []
    start = 0
    while start < len(text):
        limit = min(start + chunk_size, len(text))
        end = limit
        if limit < len(text):
            boundary = text.rfind(" ", start + chunk_size // 2, limit)
            if boundary > start:
                end = boundary
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= len(text):
            break
        next_start = max(end - overlap, start + 1)
        while next_start > start and not text[next_start - 1].isspace():
            next_start -= 1
        # A whitespace adjustment must never move back to the current start.
        # If the requested overlap cannot preserve progress, begin at `end`.
        if next_start <= start:
            next_start = end
        start = next_start
    return chunks


def request_json(method: str, path: str, timeout: int | None = None, **kwargs: Any) -> dict[str, Any]:
    try:
        response = requests.request(
            method,
            f"{OLLAMA_BASE_URL}{path}",
            timeout=timeout or REQUEST_TIMEOUT_SECONDS,
            **kwargs,
        )
        response.raise_for_status()
        payload = response.json()
    except (requests.RequestException, ValueError) as exc:
        raise RuntimeError(f"Ollama request to {path} failed: {exc}") from exc
    if not isinstance(payload, dict):
        raise RuntimeError(f"Ollama returned an unexpected response for {path}.")
    return payload


def check_ollama_and_models() -> None:
    tags = request_json("GET", "/api/tags", timeout=10)
    available = {item.get("name") for item in tags.get("models", []) if isinstance(item, dict)}

    def is_available(model: str) -> bool:
        return model in available or f"{model}:latest" in available

    missing = [model for model in (LLM_MODEL, EMBEDDING_MODEL) if not is_available(model)]
    if missing:
        raise RuntimeError(
            "Required model(s) are missing: "
            + ", ".join(missing)
            + ". Run 03-pull-models.sh (or set LLM_MODEL / EMBEDDING_MODEL)."
        )


def create_embeddings(texts: list[str]) -> list[list[float]]:
    if not texts:
        return []
    payload = request_json(
        "POST", "/api/embed", json={"model": EMBEDDING_MODEL, "input": texts, "truncate": False}
    )
    embeddings = payload.get("embeddings")
    if not isinstance(embeddings, list) or len(embeddings) != len(texts):
        raise RuntimeError("Ollama returned an invalid embedding response.")
    try:
        vectors = [[float(value) for value in vector] for vector in embeddings]
    except (TypeError, ValueError) as exc:
        raise RuntimeError("Ollama returned a non-numeric embedding.") from exc
    if not vectors or not all(vectors):
        raise RuntimeError("Ollama returned an empty embedding.")
    dimensions = len(vectors[0])
    if any(len(vector) != dimensions for vector in vectors):
        raise RuntimeError("Ollama returned embeddings with inconsistent dimensions.")
    return vectors


def save_index(chunks: list[str], embeddings: list[list[float]], current_hash: str) -> None:
    if len(chunks) != len(embeddings):
        raise RuntimeError("Cannot save an index with mismatched chunks and embeddings.")
    index = {
        "schema_version": INDEX_SCHEMA_VERSION,
        "source_file": str(DATA_FILE),
        "source_hash": current_hash,
        "embedding_model": EMBEDDING_MODEL,
        "chunk_size": CHUNK_SIZE,
        "chunk_overlap": CHUNK_OVERLAP,
        "embedding_dimensions": len(embeddings[0]) if embeddings else 0,
        "chunks": [
            {"id": number, "text": chunk, "embedding": embedding}
            for number, (chunk, embedding) in enumerate(zip(chunks, embeddings))
        ],
    }
    INDEX_FILE.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=INDEX_FILE.parent, prefix="index.", suffix=".tmp", delete=False
    ) as temporary_file:
        json.dump(index, temporary_file, ensure_ascii=False, indent=2)
        temporary_file.write("\n")
        temporary_path = Path(temporary_file.name)
    temporary_path.replace(INDEX_FILE)


def load_index() -> dict[str, Any] | None:
    try:
        payload = json.loads(INDEX_FILE.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return None
    return payload if isinstance(payload, dict) else None


def is_usable_index(index: dict[str, Any], current_hash: str) -> bool:
    chunks = index.get("chunks")
    dimensions = index.get("embedding_dimensions")
    chunks_are_valid = isinstance(chunks, list) and bool(chunks) and isinstance(dimensions, int) and dimensions > 0
    if chunks_are_valid:
        chunks_are_valid = all(
            isinstance(item, dict)
            and isinstance(item.get("id"), int)
            and isinstance(item.get("text"), str)
            and bool(item["text"].strip())
            and isinstance(item.get("embedding"), list)
            and len(item["embedding"]) == dimensions
            and all(isinstance(value, (int, float)) for value in item["embedding"])
            for item in chunks
        )
    return (
        index.get("schema_version") == INDEX_SCHEMA_VERSION
        and index.get("source_hash") == current_hash
        and index.get("embedding_model") == EMBEDDING_MODEL
        and index.get("chunk_size") == CHUNK_SIZE
        and index.get("chunk_overlap") == CHUNK_OVERLAP
        and chunks_are_valid
    )


def build_index() -> dict[str, Any]:
    text = read_knowledge_file(DATA_FILE)
    chunks = split_into_chunks(text, CHUNK_SIZE, CHUNK_OVERLAP)
    print(f"Building index for {len(chunks)} chunk(s) with {EMBEDDING_MODEL}...")
    save_index(chunks, create_embeddings(chunks), source_hash(DATA_FILE))
    index = load_index()
    if index is None:
        raise RuntimeError("Index could not be loaded after creation.")
    return index


def ensure_fresh_index(rebuild: bool = False) -> dict[str, Any]:
    current_hash = source_hash(DATA_FILE)
    index = load_index()
    if rebuild or index is None or not is_usable_index(index, current_hash):
        return build_index()
    return index


def cosine_similarity(first: list[float], second: list[float]) -> float:
    if len(first) != len(second) or not first:
        return 0.0
    denominator = math.sqrt(sum(value * value for value in first)) * math.sqrt(sum(value * value for value in second))
    return sum(left * right for left, right in zip(first, second)) / denominator if denominator else 0.0


def retrieve_relevant_chunks(question: str, index: dict[str, Any]) -> list[dict[str, Any]]:
    question_embedding = create_embeddings([question])[0]
    scored = [
        {"id": item["id"], "text": item["text"], "score": cosine_similarity(question_embedding, item["embedding"])}
        for item in index["chunks"]
    ]
    scored.sort(key=lambda item: item["score"], reverse=True)
    return [item for item in scored[:TOP_K] if item["score"] >= MIN_SIMILARITY]
