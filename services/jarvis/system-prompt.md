# Jarvis System Prompt

Paste this into **Open WebUI → Admin → Models → Create Model → System Prompt**.
Name the model `Jarvis` and set the base model to whichever Ollama model you prefer (e.g. `devstral:latest`).

---

```
You are Jarvis, the AI assistant for the K12 homelab.

## Infrastructure
- Server: K12 at 192.168.1.168 (Ubuntu 24.04, AMD GPU)
- Services: Ollama (LLM), Open WebUI (this UI), n8n (automation), Qdrant (memory), Hermes Agent, MCP Server, Langfuse, Alpaca Bot, Postgres, Redis
- Monitoring: health-check runs at 07:00 daily, rounds.sh every 5 min — alerts go to Slack #smart-rounding
- Logs: /var/log/ops-rounds.log, /var/log/ops-health.log

## Your Role
- Answer questions about the K12 infrastructure concisely and accurately
- Help diagnose service issues — ask for docker logs or health output when needed
- Assist with n8n workflow design, MCP tool integration, and automation
- Track context across conversations using your memory (Qdrant-backed knowledge base)
- Be direct and brief — one sentence when one sentence is enough

## Style
- No unnecessary preamble or sign-off
- Use markdown tables and code blocks for technical output
- When giving shell commands, prefer the exact syntax from the runbook
- If you don't know the current state of a service, say so and provide the command to check it

## Owner
Jeevan — getjeevan@gmail.com
```

---

## Open WebUI Voice Setup

After the Jarvis model is created, wire in the voice services:

1. Open WebUI → **Admin Panel → Settings → Audio**
2. **STT (Speech-to-Text)**
   - Provider: `OpenAI`
   - API Base URL: `http://192.168.1.168:9000/v1`
   - API Key: `anything` (Whisper doesn't validate keys)
   - Model: `whisper-1`
3. **TTS (Text-to-Speech)**
   - Provider: `OpenAI`
   - API Base URL: `http://192.168.1.168:8880/v1`
   - API Key: `anything`
   - Model: `kokoro`
   - Voice: `af_sky` (neutral) or `af_bella` (warmer) — see Kokoro docs for full list

4. In any chat, click the **microphone icon** to speak to Jarvis.

---

## n8n Morning Briefing Workflow

### One-time setup

1. Add your Slack webhook URL to `services/n8n/.env` (create if missing):
   ```
   SLACK_JARVIS_WEBHOOK=https://hooks.slack.com/services/YOUR/WEBHOOK/URL
   ```
   Then restart n8n: `cd ~/services/n8n && docker compose up -d`

2. In n8n (http://192.168.1.168:3001):
   - Go to **Workflows → Import from file**
   - Select `services/jarvis/n8n-morning-briefing.json`
   - Open the imported workflow and click **Activate** (toggle top-right)

3. To test immediately without waiting for 07:00:
   - Open the workflow → click **Execute Workflow**
   - Check Slack `#smart-rounding` for the briefing

### What it does

Every day at 07:00 UTC Jarvis:
1. Pings all 10 K12 services in parallel
2. Sends the health snapshot to Ollama (devstral) for a natural-language summary
3. Posts a formatted briefing to Slack with a service status block

---

## Jarvis Memory (RAG pipeline)

Jarvis remembers anything you drop into `~/data/jarvis-knowledge/` on K12.

### How it works

1. `jarvis-rag` (port 3007) polls `~/data/jarvis-knowledge/` every 60s
2. New or changed `.md`/`.txt` files are chunked, embedded with
   `nomic-embed-text` via Ollama, and upserted into the Qdrant collection
   `jarvis_memory` (edits replace stale chunks automatically)
3. The **K12 Jarvis Memory** tool in Open WebUI searches that collection

### Setup

```bash
# Deployed automatically by jarvis-deploy.sh. To verify:
curl http://localhost:3007/health

# Add your first memory
mkdir -p ~/data/jarvis-knowledge
echo "# K12 Notes\nThe alpaca bot uses paper trading only." > ~/data/jarvis-knowledge/notes.md
# Wait ~60s, then check files_ingested incremented:
curl http://localhost:3007/health
```

### Register the memory tool

1. Open WebUI → **Workspace → Tools → + New Tool**
2. Paste the contents of `services/jarvis/open-webui-memory-tool.py`
3. Save → enable it on the Jarvis model
4. Ask Jarvis: *"What do you remember about the alpaca bot?"*

---

## Jarvis Ops API + Open WebUI Tool

The Ops API (port 3006) gives Jarvis live infrastructure awareness.
Once wired in, you can ask: *"Is everything healthy?"* and get a real answer.

### Deploy the Ops API

```bash
cd ~/services/jarvis-ops-api
docker compose build
docker compose up -d
curl http://localhost:3006/status/text   # verify
```

### Register the Open WebUI tool

1. Open WebUI → **Admin Panel → Tools → + New Tool**
2. Paste the contents of `services/jarvis/open-webui-tool.py`
3. Save → toggle the tool **On** in the Jarvis model settings
4. Ask Jarvis: *"What's the status of K12?"* — it will call the API live

---

### Customise the schedule

Open the `Daily 07:00` node → change **Hour** to your preferred local time.
Note: n8n runs in UTC — adjust accordingly (`07:00 UTC = 02:00 CDT`).
