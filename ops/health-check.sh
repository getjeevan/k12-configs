#!/bin/bash
# health-check.sh — Daily server health check (7am)
# Sends Slack summary of full system state.

source ~/ops/secrets/slack.env
HOSTNAME=$(hostname)
ALERTS=""
STATUS="OK"

alert() { ALERTS="$ALERTS\n• $1"; STATUS="FAIL"; }
slack() {
  curl -s -X POST -H 'Content-type: application/json'     --data "{\"text\":\"$1\"}" "$SLACK_WEBHOOK" > /dev/null
}

# ── 1. Disk usage ─────────────────────────────────────────────────────────────
DISK=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
[ "$DISK" -gt 80 ] && alert "Disk usage at ${DISK}% — clean up needed"

# ── 2. Memory ─────────────────────────────────────────────────────────────────
MEM_FREE=$(free | awk '/^Mem/ {printf "%.0f", $4/$2*100}')
[ "$MEM_FREE" -lt 10 ] && alert "Memory critically low — ${MEM_FREE}% free"

# ── 3. Docker containers ──────────────────────────────────────────────────────
EXPECTED=(postgres redis n8n qdrant open-webui hermes-agent infra-dashboard
          alpaca-bot alpaca-dashboard kali)
for c in "${EXPECTED[@]}"; do
  STATE=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)
  [ "$STATE" != "running" ] && alert "Container DOWN: $c (status: ${STATE:-not found})"
done

# ── 4. Ollama (native systemd) ────────────────────────────────────────────────
systemctl is-active ollama > /dev/null 2>&1 || alert "Ollama service is down — GPU inference unavailable"

# ── 5. Ollama GPU check ───────────────────────────────────────────────────────
GPU_INFO=$(curl -s --max-time 5 http://localhost:11434/api/tags 2>/dev/null)
[ -z "$GPU_INFO" ] && alert "Ollama API not responding"

# ── 6. Internet connectivity ──────────────────────────────────────────────────
ping -c 2 -W 3 8.8.8.8 > /dev/null 2>&1 || alert "Internet unreachable"

# ── 7. SSH service ─────────────────────────────────────────────────────────────
systemctl is-active ssh > /dev/null 2>&1 || alert "SSH service is down"

# ── 8. fail2ban ───────────────────────────────────────────────────────────────
systemctl is-active fail2ban > /dev/null 2>&1 || alert "fail2ban is down — server unprotected"

# ── 9. Load average ───────────────────────────────────────────────────────────
LOAD=$(awk '{print $1}' /proc/loadavg | cut -d. -f1)
[ "$LOAD" -gt 12 ] && alert "High load average: $(cat /proc/loadavg | awk '{print $1,$2,$3}')"

# ── 10. Rounds log — any persistent failures? ─────────────────────────────────
DOWN_STATE=$(ls /home/getjeevan/ops/rounds/state/*.down 2>/dev/null | wc -l)
[ "$DOWN_STATE" -gt 0 ] && alert "$DOWN_STATE service(s) marked down by rounds — check /var/log/ops-rounds.log"

# ── Report ────────────────────────────────────────────────────────────────────
DISK_STR="Disk: ${DISK}%"
MEM_STR="Mem free: ${MEM_FREE}%"

if [ "$STATUS" = "FAIL" ]; then
  slack "⚠️ *Daily Health Check FAILED — $HOSTNAME*\n$(echo -e "$ALERTS")\n\n$DISK_STR | $MEM_STR\n_Run: ssh aiserver_"
  echo "[$(date)] FAILED: $ALERTS"
  exit 1
else
  slack "✅ *Daily Check — $HOSTNAME all clear*\n$DISK_STR | $MEM_STR | Load: $(cat /proc/loadavg | awk '{print $1}')"
  echo "[$(date)] All checks passed. $DISK_STR, $MEM_STR"
fi
