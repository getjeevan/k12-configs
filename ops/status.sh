#!/bin/bash
# status.sh — Human rounding dashboard for K12
# Usage: ssh aiserver "~/ops/scripts/status.sh"
source ~/ops/secrets/slack.env 2>/dev/null || true
# Or add to ~/.ssh/config:  RemoteCommand ~/ops/scripts/status.sh

# ── Colours ──────────────────────────────────────────────────────────────────
GRN='\033[0;32m'; RED='\033[0;31m'; YEL='\033[0;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'
ok()   { printf "${GRN}● %-28s${RST} %s\n" "$1" "$2"; }
warn() { printf "${YEL}⚠ %-28s${RST} %s\n" "$1" "$2"; }
fail() { printf "${RED}✖ %-28s${RST} %s\n" "$1" "$2"; }
hdr()  { printf "\n${BLD}${BLU}── %s ${RST}\n" "$1"; }

# ── Container check ───────────────────────────────────────────────────────────
chk_docker() {
  local name="$1" label="${2:-$1}"
  local state health
  state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)
  health=$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null)
  if [ "$state" = "running" ]; then
    local detail=""
    [ -n "$health" ] && [ "$health" != "unhealthy" ] && detail="($health)"
    [ "$health" = "unhealthy" ] && { warn "$label" "running but UNHEALTHY"; return; }
    ok "$label" "$detail"
  elif [ -z "$state" ]; then
    fail "$label" "not found"
  else
    fail "$label" "$state"
  fi
}

# ── Systemd check ─────────────────────────────────────────────────────────────
chk_systemd() {
  local name="$1" label="${2:-$1}"
  if systemctl is-active "$name" > /dev/null 2>&1; then
    ok "$label" "(systemd)"
  else
    fail "$label" "$(systemctl is-active "$name" 2>/dev/null)"
  fi
}

# ── URL smoke test ────────────────────────────────────────────────────────────
chk_url() {
  local label="$1" url="$2"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$url" 2>/dev/null)
  local first="${code:0:1}"
  if [ "$first" = "2" ] || [ "$code" = "401" ]; then
    ok "$label" "HTTP $code  ← $url"
  elif [ -z "$code" ] || [ "$code" = "000" ]; then
    fail "$label" "no response  ← $url"
  else
    warn "$label" "HTTP $code  ← $url"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
TS=$(date '+%Y-%m-%d %H:%M:%S %Z')
HOSTNAME=$(hostname)
printf "\n${BLD}${CYN}╔══════════════════════════════════════════════╗${RST}\n"
printf   "${BLD}${CYN}║  K12 Status — %-30s║${RST}\n" "$TS"
printf   "${BLD}${CYN}╚══════════════════════════════════════════════╝${RST}\n"

# ── System ────────────────────────────────────────────────────────────────────
hdr "System"
DISK=$(df / | awk 'NR==2 {print $5}')
DISK_NUM=${DISK/\%/}
MEM_FREE=$(free -h | awk '/^Mem/ {print $7}')
MEM_PCT=$(free | awk '/^Mem/ {printf "%.0f", $7/$2*100}')
LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
UPTIME=$(uptime -p)

[ "$DISK_NUM" -lt 80 ] && ok   "Disk /" "$DISK used  — free: $(df -h / | awk 'NR==2{print $4}')" \
                         || warn "Disk /" "$DISK used — getting full"
[ "$MEM_PCT"  -gt 10  ] && ok   "Memory"   "${MEM_FREE} free (${MEM_PCT}%)" \
                         || warn "Memory"   "${MEM_FREE} free (${MEM_PCT}%) — LOW"
ok "Load avg" "$LOAD"
ok "Uptime"   "$UPTIME"

# ── Core infrastructure ───────────────────────────────────────────────────────
hdr "Core Infrastructure"
chk_docker postgres  "Postgres (db)"
chk_docker redis     "Redis (cache)"

# ── AI & LLM ─────────────────────────────────────────────────────────────────
hdr "AI & LLM"
chk_systemd ollama       "Ollama (native GPU)"

# GPU check
GPU=$(curl -s --max-time 3 http://localhost:11434/api/tags 2>/dev/null | \
      python3 -c "import sys,json; d=json.load(sys.stdin); print(', '.join(m['name'] for m in d.get('models',[])))" 2>/dev/null)
if [ -n "$GPU" ]; then
  ok "Ollama models" "$GPU"
else
  warn "Ollama models" "API not responding or no models loaded"
fi

chk_docker open-webui    "Open WebUI"
chk_docker hermes-agent  "Hermes Agent"

# ── Workflow & Automation ─────────────────────────────────────────────────────
hdr "Workflow & Automation"
chk_docker n8n    "n8n"
chk_docker qdrant "Qdrant"

# ── Trading ───────────────────────────────────────────────────────────────────
hdr "Trading"
chk_docker alpaca-bot       "Alpaca Bot"
chk_docker alpaca-dashboard "Alpaca Dashboard"

# ── Security & Utilities ──────────────────────────────────────────────────────
hdr "Security & Utilities"
chk_docker  infra-dashboard "Infra Dashboard"
chk_docker  kali            "Kali"
chk_systemd fail2ban        "fail2ban"
chk_systemd ufw             "UFW firewall"
chk_systemd ssh             "SSH daemon"

# ── Endpoints ─────────────────────────────────────────────────────────────────
hdr "Endpoint Smoke Tests"
chk_url "Ollama API"      "http://localhost:11434/api/tags"
chk_url "Open WebUI"      "http://localhost:8000"
chk_url "Hermes Agent"    "http://localhost:9119/health"
chk_url "n8n"             "http://localhost:3001"
chk_url "Infra Dashboard" "http://localhost:7000"
chk_url "Qdrant"          "http://localhost:6333/collections"
chk_url "Alpaca Dashboard" "http://localhost:8080"

# ── Recent rounds log ─────────────────────────────────────────────────────────
hdr "Recent Auto-Rounds (last 5 events)"
DOWN_STATE=$(ls /home/getjeevan/ops/rounds/state/*.down 2>/dev/null)
if [ -n "$DOWN_STATE" ]; then
  printf "${RED}Persistent failures tracked:${RST}\n"
  for f in $DOWN_STATE; do printf "  ${RED}✖ %s${RST}\n" "$(basename "$f" .down)"; done
else
  printf "${GRN}  No persistent failures in state tracker${RST}\n"
fi

grep -E 'RESTORED|RECOVERED|FAILED|DOWN' /var/log/ops-rounds.log 2>/dev/null | tail -5 | while read -r line; do
  echo "  $line"
done

# ── Footer ────────────────────────────────────────────────────────────────────
printf "\n${BLD}  Runbook: ~/ops/k12-configs/RUNBOOK.md${RST}\n"
printf   "${BLD}  Logs:    /var/log/ops-rounds.log | ops-health.log${RST}\n"
printf   "${BLD}  Repo:    https://github.com/getjeevan/k12-configs${RST}\n\n"

# ── Post summary to #smart-rounding ──────────────────────────────────────────
source ~/ops/secrets/slack.env 2>/dev/null || true
if [ -n "$SLACK_ROUNDING" ]; then
  FAILS=
  DOWN_STATE=       0
  if [ -z "$FAILS" ] && [ "$DOWN_STATE" -eq 0 ]; then
    MSG="✅ *Manual round complete — * | 2026-05-25 12:23 CDT\nAll services healthy. Disk: % | Mem free: %"
  else
    MSG="⚠️ *Manual round — * | 2026-05-25 12:23 CDT\nIssues found — check /var/log/ops-rounds.log or run: ssh aiserver status"
  fi
  curl -s -X POST -H 'Content-type: application/json'     --data "{\"text\":\"$MSG\"}" "$SLACK_ROUNDING" > /dev/null
fi

# ── Post summary to #smart-rounding ──────────────────────────────────────────
source ~/ops/secrets/slack.env 2>/dev/null || true
if [ -n "$SLACK_ROUNDING" ]; then
  DOWN_COUNT=$(ls /home/getjeevan/ops/rounds/state/*.down 2>/dev/null | wc -l)
  STOPPED=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | head -5 | tr "\n" " ")
  RDATE=$(date "+%Y-%m-%d %H:%M %Z")
  HOST=$(hostname)
  if [ "$DOWN_COUNT" -eq 0 ] && [ -z "$STOPPED" ]; then
    RMSG="✅ *Manual round — $HOST* | $RDATE\nAll services healthy | Disk: $(df / | awk 'NR==2{print $5}') | Mem free: $(free | awk '/^Mem/{printf "%.0f%%", $7/$2*100}')"
  else
    RMSG="⚠️ *Manual round — $HOST* | $RDATE\n$DOWN_COUNT service(s) in failed state | Stopped: ${STOPPED:-none}"
  fi
  curl -s -X POST -H "Content-type: application/json" \
    --data "{\"text\":\"$RMSG\"}" "$SLACK_ROUNDING" > /dev/null
  echo -e "\n  📣 Round posted to #smart-rounding"
fi
