from fastapi import FastAPI
from datetime import datetime, timezone
import httpx
import docker

app = FastAPI(title="Jarvis Ops API", version="1.0")

docker_client = docker.from_env()

# Core containers — always expected to be running
CONTAINERS_REQUIRED = [
    "postgres", "redis", "open-webui", "n8n", "qdrant",
    "hermes-agent", "infra-dashboard", "alpaca-bot",
    "alpaca-dashboard", "kali", "whisper", "kokoro-tts",
    "jarvis-rag",
]

# Optional containers — reported but don't affect overall health
CONTAINERS_OPTIONAL = [
    "langfuse", "mcp",
]

CONTAINERS = CONTAINERS_REQUIRED + CONTAINERS_OPTIONAL

ENDPOINTS = [
    ("Ollama",       "http://192.168.1.168:11434/api/tags"),
    ("Open WebUI",   "http://192.168.1.168:8000"),
    ("n8n",          "http://192.168.1.168:3001/healthz"),
    ("Qdrant",       "http://192.168.1.168:6333/healthz"),   # /health → 404; correct path is /healthz
    ("Whisper STT",  "http://192.168.1.168:9000/docs"),
    ("Kokoro TTS",   "http://192.168.1.168:8880/health"),
    ("Jarvis RAG",   "http://192.168.1.168:3007/health"),
    ("Infra Dash",   "http://192.168.1.168:7000"),
]

# Optional endpoints — reported but don't affect overall health
ENDPOINTS_OPTIONAL = [
    ("MCP Server",   "http://192.168.1.168:3005/health"),
    ("Langfuse",     "http://192.168.1.168:8888/api/public/health"),
]


def _inspect_container(name: str) -> dict:
    try:
        c = docker_client.containers.get(name)
        health_status = (
            c.attrs.get("State", {})
             .get("Health", {})
             .get("Status", "")
        )
        is_healthy = (
            c.status == "running" and health_status != "unhealthy"
        )
        return {
            "status": c.status,
            "health": health_status or "no-healthcheck",
            "healthy": is_healthy,
        }
    except docker.errors.NotFound:
        return {"status": "not_found", "health": "", "healthy": False}
    except Exception as e:
        return {"status": "error", "health": str(e), "healthy": False}


@app.get("/health")
def health():
    return {"status": "ok", "ts": datetime.now(timezone.utc).isoformat()}


@app.get("/status")
async def status():
    containers = {}
    for name in CONTAINERS:
        info = _inspect_container(name)
        info["optional"] = name in CONTAINERS_OPTIONAL
        containers[name] = info

    endpoints = {}
    async with httpx.AsyncClient(timeout=5.0) as http:
        all_ep = [(label, url, False) for label, url in ENDPOINTS] + \
                 [(label, url, True)  for label, url in ENDPOINTS_OPTIONAL]
        for label, url, optional in all_ep:
            try:
                r = await http.get(url)
                endpoints[label] = {
                    "http_status": r.status_code,
                    "healthy": r.status_code < 400,
                    "optional": optional,
                }
            except Exception:
                endpoints[label] = {"http_status": 0, "healthy": False, "optional": optional}

    required_containers_healthy = all(
        v["healthy"] for v in containers.values() if not v["optional"]
    )
    required_endpoints_healthy = all(
        v["healthy"] for v in endpoints.values() if not v["optional"]
    )
    all_healthy = required_containers_healthy and required_endpoints_healthy

    return {
        "overall": "healthy" if all_healthy else "degraded",
        "containers": containers,
        "endpoints": endpoints,
        "ts": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/status/text")
async def status_text():
    data = await status()

    down_required = [
        n for n, v in data["containers"].items() if not v["healthy"] and not v["optional"]
    ] + [
        n for n, v in data["endpoints"].items() if not v["healthy"] and not v["optional"]
    ]
    down_optional = [
        n for n, v in data["containers"].items() if not v["healthy"] and v["optional"]
    ] + [
        n for n, v in data["endpoints"].items() if not v["healthy"] and v["optional"]
    ]

    lines = [
        f"K12 Status — {data['ts']}",
        f"Overall: {data['overall'].upper()}",
        "",
        "Containers:",
    ]
    for name, info in data["containers"].items():
        icon = "✅" if info["healthy"] else ("⚪" if info["optional"] else "❌")
        detail = info["status"]
        if info["health"] and info["health"] not in ("no-healthcheck", ""):
            detail += f" ({info['health']})"
        if info["optional"]:
            detail += " [optional]"
        lines.append(f"  {icon} {name}: {detail}")

    lines.append("")
    lines.append("Endpoints:")
    for name, info in data["endpoints"].items():
        icon = "✅" if info["healthy"] else ("⚪" if info["optional"] else "❌")
        suffix = " [optional]" if info["optional"] else ""
        lines.append(f"  {icon} {name}: HTTP {info['http_status']}{suffix}")

    if down_required:
        lines.append("")
        lines.append(f"ACTION NEEDED: {', '.join(down_required)}")
    if down_optional:
        lines.append(f"NOT DEPLOYED (optional): {', '.join(down_optional)}")

    return {"text": "\n".join(lines), "overall": data["overall"]}
