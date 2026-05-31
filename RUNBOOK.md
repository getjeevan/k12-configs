# K12 Service Runbook

**Run a round:** `ssh aiserver '~/ops/scripts/status.sh'`  
**Slack:** All round alerts → #smart-rounding  
**Logs:** `/var/log/ops-rounds.log` · `/var/log/ops-health.log`  

---

## Rounding Schedule

| Who | When | How |
|-----|------|-----|
| Automated | Every 5 min | `rounds.sh` — auto-restores, Slacks on change |
| Automated | 07:00 daily | `health-check.sh` — full system summary |
| Team | Morning + evening | `ssh aiserver '~/ops/scripts/status.sh'` |
| Team | After any incident | Same command, verify all green |

---

## Service Restoration Procedures

### 🗄 Postgres
```bash
cd ~/services/postgres && docker compose up -d
docker logs postgres --tail 30
```
**Healthy sign:** `docker inspect postgres` → Health: healthy

---

### ⚡ Redis
```bash
cd ~/services/redis && docker compose up -d
# If dump.rdb corrupted:
docker stop redis
rm ~/data/redis/dump.rdb
docker compose up -d
```

---

### 🤖 Ollama (GPU)
```bash
sudo systemctl restart ollama
sudo systemctl status ollama
# Verify GPU active:
curl http://localhost:11434/api/tags
```
**If GPU not loading:** Check `/etc/systemd/system/ollama.service.d/rocm.conf` has `OLLAMA_VULKAN=1`

---

### 🌐 Open WebUI
```bash
cd ~/services/open-webui && docker compose up -d
docker logs open-webui --tail 20
```

---

### 🧠 Hermes Agent
```bash
cd ~/services/hermes-agent && docker compose restart
docker logs hermes-agent --tail 20
```
**Config:** `~/services/hermes-agent/hermes-data/config.yaml`  
**Model:** devstral:latest via native Ollama

---

### ⚙️ n8n
```bash
cd ~/services/n8n && docker compose up -d
docker logs n8n --tail 20
```
**DB issue:** Confirm `postgres` is healthy first — n8n needs it on startup.

---

### 🔍 Qdrant
```bash
cd ~/services/qdrant && docker compose up -d
curl http://localhost:6333/collections
```

---

### 📈 Alpaca Bot
```bash
cd ~/services/alpaca-bot && docker compose up -d
docker logs alpaca-bot --tail 30
```
**Note:** Market closed = `Market closed. Next open: ...` is NORMAL, not a failure.

---

### 🛡 Infra Dashboard
```bash
cd ~/services/infra-dashboard && docker compose up -d
curl http://localhost:7000
```

---

### 🔐 Kali
```bash
docker start kali
docker exec -it kali /bin/bash
```
**Note:** Kali has no compose dir — no auto-restore. Manual start only.

---

### 🎙 Whisper (STT)
```bash
cd ~/services/whisper && docker compose up -d
curl http://localhost:9000/docs
```
**Open WebUI STT base URL:** `http://192.168.1.168:9000/v1`
**Note:** First start downloads the `base.en` model (~140MB) — allow 60s.

---

### 🔊 Kokoro TTS
```bash
cd ~/services/kokoro-tts && docker compose up -d
curl http://localhost:8880/health
```
**Open WebUI TTS base URL:** `http://192.168.1.168:8880/v1`
**Voices:** `af_sky` (neutral), `af_bella` (warm), `bm_daniel` (British male)

---

### 🔥 fail2ban / UFW
```bash
sudo systemctl restart fail2ban
sudo systemctl restart ufw
sudo ufw status verbose
```
⚠️ **Never restart SSH from a remote session without a backup console open.**

---

## Disk Full
```bash
# Check what's large
df -h && du -sh ~/data/* ~/services/*/logs/* /var/log/* 2>/dev/null | sort -rh | head -20
# Clean Docker
docker system prune -f
# Run cleanup script
~/ops/scripts/cleanup-logs.sh
```

## Memory Pressure
```bash
free -h
docker stats --no-stream
# Restart heaviest containers if needed
cd ~/services/open-webui && docker compose restart
```

## Total Stack Restart (last resort)
```bash
for svc in postgres redis n8n qdrant open-webui hermes-agent infra-dashboard alpaca-bot whisper kokoro-tts; do
  dir=~/services/$svc
  [ -d "$dir" ] && cd "$dir" && docker compose up -d
done
sudo systemctl restart ollama
```

---

## Access Points

| Service | Local | Tailscale |
|---------|-------|-----------|
| infra-dashboard | http://192.168.1.168:7000 | http://100.112.118.83:7000 |
| open-webui (Jarvis UI) | http://192.168.1.168:8000 | http://100.112.118.83:8000 |
| n8n | http://192.168.1.168:3001 | http://100.112.118.83:3001 |
| Ollama API | http://192.168.1.168:11434 | http://100.112.118.83:11434 |
| alpaca-dashboard | http://192.168.1.168:8080 | — |
| Qdrant | http://192.168.1.168:6333 | — |
| Whisper STT | http://192.168.1.168:9000 | — |
| Kokoro TTS | http://192.168.1.168:8880 | — |

**SSH:**
```bash
ssh aiserver      # local
ssh aiserver-ts   # via Tailscale
```

---


---

## Hostinger VPS (187.124.240.44)

**SSH:** `ssh root@187.124.240.44`  
**Tailscale:** `100.85.33.109`

### Service Map

| Service | Type | Purpose |
|---------|------|---------|
| nginx | systemd | Serves ashleindallas.com + MCP proxy |
| alpaca-bot | systemd | Trading bot (active Mon–Fri 13:30–20:00 UTC only) |
| alpaca-mcp | Docker | Alpaca MCP server (port 127.0.0.1:8000) |
| openclaw | Docker | OpenClaw application |
| biryani-api | Docker | Biryani Express API (Express.js) |
| biryani-web | Docker | Biryani Express frontend (nginx:alpine, port 8081) |
| cisco-config-parser | Docker | Cisco config parsing service |
| netops-agent | Docker | NetOps automation agent |
| it-rag-api | Docker | IT RAG API |
| it-rag-minio | Docker | Object storage for RAG |
| it-rag-postgres | Docker | RAG database |
| it-rag-ollama | Docker | Local LLM for RAG |

### Restoration Procedures

#### nginx
```bash
ssh root@187.124.240.44
systemctl restart nginx && systemctl status nginx
curl -I http://ashleindallas.com
```

#### alpaca-bot (Hostinger)
```bash
systemctl start alpaca-bot
systemctl status alpaca-bot
journalctl -u alpaca-bot -n 30
```
> ⚠️ **Normal:** shows `failed` outside Mon–Fri 13:30–20:00 UTC — cron manages start/stop

#### Any Docker container
```bash
ssh root@187.124.240.44
docker compose -f /path/to/docker-compose.yml up -d
docker logs <container> --tail 30
```

#### Full Hostinger stack restart
```bash
ssh root@187.124.240.44
for c in alpaca-mcp openclaw biryani-api biryani-web cisco-config-parser netops-agent-netops-agent-1 it-rag-api it-rag-minio it-rag-postgres it-rag-ollama; do
  docker restart $c
done
systemctl restart nginx
```

### Cron Schedule (UTC)
| Time | Days | Action |
|------|------|--------|
| 13:30 | Mon–Fri | `systemctl start alpaca-bot` |
| 20:00 | Mon–Fri | `systemctl stop alpaca-bot` |
| 20:05 | Mon–Fri | End-of-day report → Slack |

### Access Points
- **Site:** http://ashleindallas.com
- **MCP:** https://mcp.ashleindallas.com/006243dc.../mcp
- **Biryani:** http://www.biryaniexpress.no (proxied via nginx)


---

*Auto-generated. Configs live at: https://github.com/getjeevan/k12-configs*
