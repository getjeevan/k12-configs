from fastapi import FastAPI
from datetime import datetime, timezone
import httpx
import docker

app = FastAPI(title="Jarvis Ops API", version="1.0")

docker_client = docker.from_env()

CONTAINERS = [
    "postgres", "redis", "open-webui", "n8n", "qdrant",
    "hermes-agent", "infra-dashboard", "alpaca-bot",
    "alpaca-dashboard", "kali", "whisper", "kokoro-tts",
    "langfuse", "mcp",
]

ENDPOINTS = [
    ("Ollama",       "http://192.168.1.168:11434/api/tags"),
    ("Open WebUI",   "http://192.168.1.168:8000"),
    ("n8n",          "http://192.168.1.168:3001/healthz"),
    ("Qdrant",       "http://192.168.1.168:6333/health"),
    ("MCP Server",   "http://192.168.1.168:3005/health"),
    ("Langfuse",     "http://192.168.1.168:8888/api/public/health"),
    ("Whisper STT",  "http://192.168.1.168:9000/docs"),
    ("Kokoro TTS",   "http://192.168.1.168:8880/health"),
    ("Infra Dash",   "http://192.168.1.168:7000"),
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
        containers[name] = _inspect_container(name)

    endpoints = {}
    async with httpx.AsyncClient(timeout=5.0) as http:
        for label, url in ENDPOINTS:
            try:
                r = await http.get(url)
                endpoints[label] = {
                    "http_status": r.status_code,
                    "healthy": r.status_code < 400,
                }
            except Exception:
                endpoints[label] = {"http_status": 0, "healthy": False}

    all_healthy = all(v["healthy"] for v in containers.values()) and \
                  all(v["healthy"] for v in endpoints.values())

    return {
        "overall": "healthy" if all_healthy else "degraded",
        "containers": containers,
        "endpoints": endpoints,
        "ts": datetime.now(timezone.utc).isoformat(),
    }


@app.get("/status/text")
async def status_text():
    data = await status()

    down_containers = [n for n, v in data["containers"].items() if not v["healthy"]]
    down_endpoints  = [n for n, v in data["endpoints"].items()  if not v["healthy"]]

    lines = [
        f"K12 Status — {data['ts']}",
        f"Overall: {data['overall'].upper()}",
        "",
        "Containers:",
    ]
    for name, info in data["containers"].items():
        icon = "✅" if info["healthy"] else "❌"
        detail = info["status"]
        if info["health"] and info["health"] not in ("no-healthcheck", ""):
            detail += f" ({info['health']})"
        lines.append(f"  {icon} {name}: {detail}")

    lines.append("")
    lines.append("Endpoints:")
    for name, info in data["endpoints"].items():
        icon = "✅" if info["healthy"] else "❌"
        lines.append(f"  {icon} {name}: HTTP {info['http_status']}")

    if down_containers or down_endpoints:
        lines.append("")
        all_down = down_containers + down_endpoints
        lines.append(f"ACTION NEEDED: {', '.join(all_down)}")

    return {"text": "\n".join(lines), "overall": data["overall"]}
