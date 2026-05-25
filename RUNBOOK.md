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
for svc in postgres redis n8n qdrant open-webui hermes-agent infra-dashboard alpaca-bot; do
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
| open-webui | http://192.168.1.168:8000 | http://100.112.118.83:8000 |
| n8n | http://192.168.1.168:3001 | http://100.112.118.83:3001 |
| Ollama API | http://192.168.1.168:11434 | http://100.112.118.83:11434 |
| alpaca-dashboard | http://192.168.1.168:8080 | — |
| Qdrant | http://192.168.1.168:6333 | — |

**SSH:**
```bash
ssh aiserver      # local
ssh aiserver-ts   # via Tailscale
```

---

*Auto-generated. Configs live at: https://github.com/getjeevan/k12-configs*
