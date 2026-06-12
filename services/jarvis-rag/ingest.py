"""
Jarvis RAG ingest — watches /knowledge for .md/.txt files, chunks them,
embeds via Ollama (nomic-embed-text), and upserts into the Qdrant
collection `jarvis_memory`. Re-ingests automatically when a file changes.

Drop files into ~/data/jarvis-knowledge/ on K12 and Jarvis remembers them.
"""

import hashlib
import json
import os
import threading
import time
import uuid
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI

OLLAMA_URL = os.environ.get("OLLAMA_URL", "http://192.168.1.168:11434")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://192.168.1.168:6333")
EMBED_MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
COLLECTION = "jarvis_memory"
VECTOR_SIZE = 768  # nomic-embed-text output dimension
KNOWLEDGE_DIR = Path("/knowledge")
STATE_FILE = Path("/state/ingested.json")
POLL_SECONDS = 60
CHUNK_CHARS = 1200
CHUNK_OVERLAP = 200

app = FastAPI(title="Jarvis RAG Ingest")
stats = {"files_ingested": 0, "chunks_upserted": 0, "last_run": None, "errors": []}


@app.get("/health")
def health():
    return {"status": "ok", **stats}


def load_state() -> dict:
    if STATE_FILE.exists():
        return json.loads(STATE_FILE.read_text())
    return {}


def save_state(state: dict):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2))


def chunk_text(text: str) -> list[str]:
    chunks = []
    start = 0
    while start < len(text):
        end = start + CHUNK_CHARS
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        start = end - CHUNK_OVERLAP
    return chunks


def embed(client: httpx.Client, texts: list[str]) -> list[list[float]]:
    r = client.post(
        f"{OLLAMA_URL}/api/embed",
        json={"model": EMBED_MODEL, "input": texts},
        timeout=120,
    )
    r.raise_for_status()
    return r.json()["embeddings"]


def ensure_collection(client: httpx.Client):
    r = client.get(f"{QDRANT_URL}/collections/{COLLECTION}")
    if r.status_code == 200:
        return
    client.put(
        f"{QDRANT_URL}/collections/{COLLECTION}",
        json={"vectors": {"size": VECTOR_SIZE, "distance": "Cosine"}},
        timeout=30,
    ).raise_for_status()


def delete_file_points(client: httpx.Client, source: str):
    client.post(
        f"{QDRANT_URL}/collections/{COLLECTION}/points/delete",
        json={"filter": {"must": [{"key": "source", "match": {"value": source}}]}},
        timeout=30,
    )


def ingest_file(client: httpx.Client, path: Path) -> int:
    text = path.read_text(errors="ignore")
    chunks = chunk_text(text)
    if not chunks:
        return 0

    source = str(path.relative_to(KNOWLEDGE_DIR))
    delete_file_points(client, source)  # replace stale chunks on re-ingest

    points = []
    # Embed in batches to keep Ollama request sizes sane
    for i in range(0, len(chunks), 16):
        batch = chunks[i : i + 16]
        vectors = embed(client, batch)
        for j, (chunk, vec) in enumerate(zip(batch, vectors)):
            point_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"{source}#{i + j}"))
            points.append({
                "id": point_id,
                "vector": vec,
                "payload": {"source": source, "chunk_index": i + j, "text": chunk},
            })

    client.put(
        f"{QDRANT_URL}/collections/{COLLECTION}/points",
        json={"points": points},
        timeout=60,
    ).raise_for_status()
    return len(points)


def poll_loop():
    state = load_state()
    while True:
        try:
            with httpx.Client() as client:
                ensure_collection(client)
                for path in sorted(KNOWLEDGE_DIR.rglob("*")):
                    if not path.is_file() or path.suffix.lower() not in (".md", ".txt"):
                        continue
                    digest = hashlib.sha256(path.read_bytes()).hexdigest()
                    key = str(path.relative_to(KNOWLEDGE_DIR))
                    if state.get(key) == digest:
                        continue
                    n = ingest_file(client, path)
                    state[key] = digest
                    save_state(state)
                    stats["files_ingested"] += 1
                    stats["chunks_upserted"] += n
                    print(f"Ingested {key}: {n} chunks", flush=True)
            stats["last_run"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            stats["errors"] = []
        except Exception as e:
            print(f"Ingest error: {e}", flush=True)
            stats["errors"] = [str(e)]
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    KNOWLEDGE_DIR.mkdir(parents=True, exist_ok=True)
    threading.Thread(target=poll_loop, daemon=True).start()
    uvicorn.run(app, host="0.0.0.0", port=3007)
