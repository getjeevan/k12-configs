"""
title: K12 Jarvis Memory
author: Jarvis
description: Search Jarvis's long-term memory (Qdrant jarvis_memory collection).
             Recalls notes and documents dropped into ~/data/jarvis-knowledge on K12.
version: 1.0
"""

import httpx

OLLAMA_URL = "http://192.168.1.168:11434"
QDRANT_URL = "http://192.168.1.168:6333"
EMBED_MODEL = "nomic-embed-text"
COLLECTION = "jarvis_memory"


class Tools:
    def __init__(self):
        pass

    async def search_memory(self, query: str) -> str:
        """
        Search Jarvis's long-term memory for notes and documents relevant
        to the query. Call this when the user asks about something Jarvis
        should remember — past notes, saved documents, project details,
        or anything stored in the knowledge base.

        :param query: A natural-language description of what to recall.
        """
        try:
            async with httpx.AsyncClient(timeout=30) as client:
                emb = await client.post(
                    f"{OLLAMA_URL}/api/embed",
                    json={"model": EMBED_MODEL, "input": [query]},
                )
                emb.raise_for_status()
                vector = emb.json()["embeddings"][0]

                res = await client.post(
                    f"{QDRANT_URL}/collections/{COLLECTION}/points/search",
                    json={"vector": vector, "limit": 5, "with_payload": True},
                )
                res.raise_for_status()
                hits = res.json().get("result", [])

            if not hits:
                return ("No matching memories found. The knowledge base may be "
                        "empty — drop .md/.txt files into ~/data/jarvis-knowledge on K12.")

            parts = []
            for h in hits:
                p = h.get("payload", {})
                parts.append(
                    f"[{p.get('source', 'unknown')} · score {h.get('score', 0):.2f}]\n"
                    f"{p.get('text', '')}"
                )
            return "\n\n---\n\n".join(parts)
        except Exception as e:
            return f"Memory search failed: {e}"
