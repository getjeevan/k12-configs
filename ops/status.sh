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

# ── Hostinger VPS ─────────────────────────────────────────────────────────────
hdr "Hostinger VPS (187.124.240.44)"
HDATA=$(ssh -i ~/.ssh/id_ed25519_hostinger_rag -o StrictHostKeyChecking=no -o ConnectTimeout=6 root@187.124.240.44 'bash -s' <<'REMOTE'
  DISK=$(df / | awk 'NR==2{print $5}')
  DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
  MEM_FREE=$(free -h | awk '/^Mem/{print $7}')
  MEM_PCT=$(free | awk '/^Mem/{printf "%.0f", $7/$2*100}')
  LOAD=$(awk '{print $1}' /proc/loadavg)
  UPTIME_RAW=$(uptime -p | sed 's/up //')
  printf 'DISK=%s\n'      "$DISK"
  printf 'DISK_FREE=%s\n' "$DISK_FREE"
  printf 'MEM_FREE=%s\n'  "$MEM_FREE"
  printf 'MEM_PCT=%s\n'   "$MEM_PCT"
  printf 'LOAD=%s\n'      "$LOAD"
  printf "UPTIME='%s'\n"  "$UPTIME_RAW"
  for c in nginx alpaca-bot; do
    state=$(systemctl is-active "$c" 2>/dev/null)
    name_safe="${c//-/_}"
    printf 'SYS_%s=%s\n' "$name_safe" "$state"
  done
  for c in alpaca-mcp openclaw biryani-api biryani-web cisco-config-parser netops-agent-netops-agent-1 it-rag-api it-rag-postgres it-rag-ollama; do
    state=$(docker inspect --format '{{.State.Status}}' "$c" 2>/dev/null)
    health=$(docker inspect --format '{{.State.Health.Status}}' "$c" 2>/dev/null)
    [ "$health" = 'unhealthy' ] && state='unhealthy'
    name_safe="${c//-/_}"
    printf 'DCK_%s=%s\n' "$name_safe" "$state"
  done
REMOTE
)

if [ -z "$HDATA" ]; then
  fail "Hostinger VPS" "unreachable"
else
  eval "$HDATA"

  # System metrics
  [ "${DISK/\%/}" -lt 80 ] && ok "Disk /" "${DISK} used — ${DISK_FREE} free" || warn "Disk /" "${DISK} used"
  [ "$MEM_PCT" -gt 10 ] && ok "Memory" "${MEM_FREE} free (${MEM_PCT}%)" || warn "Memory" "${MEM_FREE} free — LOW"
  ok "Load / Uptime" "$LOAD | $UPTIME"

  # Systemd services
  [ "$SYS_nginx" = "active" ]      && ok "nginx" "(systemd)"      || fail "nginx" "$SYS_nginx"
  [ "$SYS_alpaca_bot" = "active" ] && ok "alpaca-bot" "(systemd)" || fail "alpaca-bot (trading)" "$SYS_alpaca_bot"

  # Docker containers
  while IFS= read -r entry; do
    key="${entry%%=*}"; val="${entry##*=}"
    [[ "$key" != DCK_* ]] && continue
    name="${key#DCK_}"
    label="${name//_/-}"
    [ "$val" = "running" ] && ok "$label" || fail "$label" "$val"
  done <<< "$HDATA"
fi

# ── Footer ────────────────────────────────────────────────────────────────────
printf "\n${BLD}  Runbook: ~/ops/k12-configs/RUNBOOK.md${RST}\n"
printf   "${BLD}  Logs:    /var/log/ops-rounds.log | ops-health.log${RST}\n"
printf   "${BLD}  Repo:    https://github.com/getjeevan/k12-configs${RST}\n\n"

# ── Rich Slack post to #smart-rounding ───────────────────────────────────────
source ~/ops/secrets/slack.env 2>/dev/null || true
if [ -n "$SLACK_ROUNDING" ]; then
  RDATE=$(date "+%Y-%m-%d %H:%M %Z")
  HOST=$(hostname)

  # K12 metrics
  K12_DISK=$(df / | awk 'NR==2{print $5}')
  K12_DISK_FREE=$(df -h / | awk 'NR==2{print $4}')
  K12_MEM=$(free -h | awk '/^Mem/{print $7}')
  K12_MEM_PCT=$(free | awk '/^Mem/{printf "%.0f", $7/$2*100}')
  K12_LOAD=$(cat /proc/loadavg | awk '{print $1, $2, $3}')
  K12_UPTIME=$(uptime -p | sed 's/up //')
  K12_DOWN=$(ls /home/getjeevan/ops/rounds/state/*.down 2>/dev/null | wc -l)
  K12_MODELS=$(curl -s --max-time 3 http://localhost:11434/api/tags | python3 -c "import sys,json; print(', '.join(m['name'] for m in json.load(sys.stdin).get('models',[])))" 2>/dev/null || echo "N/A")

  # K12 service icons
  svc_icon() {
    local state; state=$(docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null)
    local health; health=$(docker inspect --format '{{.State.Health.Status}}' "$1" 2>/dev/null)
    [ "$state" = "running" ] && [ "$health" != "unhealthy" ] && echo ":large_green_circle:" || echo ":red_circle:"
  }
  sys_icon() { systemctl is-active "$1" > /dev/null 2>&1 && echo ":large_green_circle:" || echo ":red_circle:"; }
  K12_SVCS="$(sys_icon ollama) Ollama  $(svc_icon postgres) Postgres  $(svc_icon redis) Redis  $(svc_icon hermes-agent) Hermes Agent  $(svc_icon n8n) n8n  $(svc_icon qdrant) Qdrant  $(svc_icon alpaca-bot) Alpaca Bot  $(svc_icon infra-dashboard) Infra Dashboard  $(svc_icon kali) Kali"


  # Hostinger service icons (reuse eval'd vars)
  h_icon() { [ "$1" = "running" ] || [ "$1" = "active" ] && echo ":large_green_circle:" || echo ":red_circle:"; }
  H_SVCS="$(h_icon $SYS_nginx) nginx  $(h_icon $SYS_alpaca_bot) alpaca-bot  $(h_icon $DCK_alpaca_mcp) alpaca-mcp  $(h_icon $DCK_openclaw) openclaw  $(h_icon $DCK_biryani_api) biryani-api  $(h_icon $DCK_biryani_web) biryani-web  $(h_icon $DCK_cisco_config_parser) cisco-parser  $(h_icon $DCK_it_rag_api) it-rag-api  $(h_icon $DCK_it_rag_postgres) it-rag-db  $(h_icon $DCK_it_rag_ollama) it-rag-ollama"

  OVERALL_STATUS=$( [ "$K12_DOWN" -eq 0 ] && [ "$SYS_alpaca_bot" = "active" ] && echo ":white_check_mark: *All Clear*" || echo ":rotating_light: *Issues Detected*" )

  PAYLOAD=$(python3 -c "
import json, sys
blocks = [
  {'type':'header','text':{'type':'plain_text','text':'K12 Infrastructure Round'}},
  {'type':'section','text':{'type':'mrkdwn','text':'$OVERALL_STATUS | $RDATE'}},
  {'type':'divider'},
  {'type':'section','fields':[
    {'type':'mrkdwn','text':'*:desktop_computer: K12 (192.168.1.168)*\n$K12_SVCS\n\n:floppy_disk: $K12_DISK used ($K12_DISK_FREE free)\n:brain: Mem free: $K12_MEM ($K12_MEM_PCT%)\n:chart_with_upwards_trend: Load: $K12_LOAD\n:robot_face: Model: $K12_MODELS'},
    {'type':'mrkdwn','text':'*:cloud: Hostinger (187.124.240.44)*\n$H_SVCS\n\n:floppy_disk: $DISK used ($DISK_FREE free)\n:brain: Mem free: $MEM_FREE ($MEM_PCT%)\n:chart_with_upwards_trend: Load: $LOAD\n:timer_clock: $UPTIME'}
  ]},
  {'type':'context','elements':[{'type':'mrkdwn','text':':books: <https://github.com/getjeevan/k12-configs/blob/main/RUNBOOK.md|Runbook> | Logs: /var/log/ops-rounds.log | Run: ssh aiserver-status'}]}
]
print(json.dumps({'blocks': blocks}))
")

  curl -s -X POST -H 'Content-type: application/json' \
    --data "$PAYLOAD" "$SLACK_ROUNDING" > /dev/null

  echo -e "\n  📣 Round posted to #smart-rounding (K12 + Hostinger)"
fi
