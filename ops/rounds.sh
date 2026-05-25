#!/bin/bash
# rounds.sh — IT Service Rounding
# Runs every 5 minutes via cron. Checks all K12 services, auto-restores
# unhealthy ones, and sends Slack alerts only on state CHANGES.
#
# Schedule: */5 * * * * /home/getjeevan/ops/scripts/rounds.sh >> /var/log/ops-rounds.log 2>&1

source ~/ops/secrets/slack.env
STATE_DIR="/home/getjeevan/ops/rounds/state"
HOSTNAME=$(hostname)
TS=$(date '+%Y-%m-%d %H:%M:%S')
RESTORED=()
FAILED=()
RECOVERED=()

# ── Helpers ───────────────────────────────────────────────────────────────────

slack() {
  curl -s -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"$1\"}" "$SLACK_WEBHOOK" > /dev/null
}

log() { echo "[$TS] $*"; }

# State files track previous up/down status to avoid repeated alerts
was_down() { [ -f "$STATE_DIR/$1.down" ]; }
mark_down() { touch "$STATE_DIR/$1.down"; }
mark_up()   { rm -f "$STATE_DIR/$1.down"; }

# ── Docker container check + restore ─────────────────────────────────────────
# Args: container_name  compose_dir  [restart_policy: auto|alert]
check_docker() {
  local name="$1"
  local dir="$2"
  local policy="${3:-auto}"

  local state
  state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)

  if [ "$state" = "running" ]; then
    # Check health if available
    local health
    health=$(docker inspect --format '{{.State.Health.Status}}' "$name" 2>/dev/null)
    if [ "$health" = "unhealthy" ]; then
      state="unhealthy"
    fi
  fi

  if [ "$state" = "running" ]; then
    # Back up, was it previously down?
    if was_down "$name"; then
      log "✅ RECOVERED: $name"
      RECOVERED+=("$name")
      mark_up "$name"
    fi
    return 0
  fi

  # Service is not running
  log "⚠️  DOWN: $name (state: ${state:-not found})"

  if [ "$policy" = "auto" ] && [ -n "$dir" ] && [ -d "$dir" ]; then
    log "🔄 Restoring: $name via docker compose in $dir"
    cd "$dir" && docker compose up -d "$name" >> /var/log/ops-rounds.log 2>&1
    sleep 8
    local new_state
    new_state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)
    if [ "$new_state" = "running" ]; then
      log "✅ RESTORED: $name"
      RESTORED+=("$name")
      mark_up "$name"
      return 0
    else
      log "❌ RESTORE FAILED: $name still $new_state"
    fi
  fi

  if ! was_down "$name"; then
    mark_down "$name"
  fi
  FAILED+=("$name (${state:-not found})")
}

# ── Systemd service check + restore ──────────────────────────────────────────
# Args: service_name  [restart_policy: auto|alert]
check_systemd() {
  local name="$1"
  local policy="${2:-auto}"

  if systemctl is-active "$name" > /dev/null 2>&1; then
    if was_down "$name"; then
      log "✅ RECOVERED: $name (systemd)"
      RECOVERED+=("$name")
      mark_up "$name"
    fi
    return 0
  fi

  log "⚠️  DOWN: $name (systemd)"

  if [ "$policy" = "auto" ]; then
    log "🔄 Restarting: $name via systemctl"
    sudo systemctl restart "$name" 2>/dev/null
    sleep 5
    if systemctl is-active "$name" > /dev/null 2>&1; then
      log "✅ RESTORED: $name"
      RESTORED+=("$name")
      mark_up "$name"
      return 0
    else
      log "❌ RESTORE FAILED: $name"
    fi
  fi

  if ! was_down "$name"; then
    mark_down "$name"
  fi
  FAILED+=("$name (systemd)")
}

# ── URL reachability check ────────────────────────────────────────────────────
# Args: label  url  expected_http_code_prefix (e.g. "2" for 2xx, "4" for 4xx)
check_url() {
  local label="$1"
  local url="$2"
  local ok_prefix="${3:-2}"    # first digit of acceptable HTTP code

  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>/dev/null)
  local first="${code:0:1}"

  if [ "$first" = "$ok_prefix" ] || [ "$code" = "401" ] || [ "$code" = "200" ]; then
    if was_down "url_$label"; then
      log "✅ RECOVERED endpoint: $label ($url)"
      RECOVERED+=("$label endpoint")
      mark_up "url_$label"
    fi
    return 0
  fi

  log "⚠️  ENDPOINT DOWN: $label — $url returned $code"
  if ! was_down "url_$label"; then
    mark_down "url_$label"
  fi
  FAILED+=("$label endpoint (HTTP $code)")
}

# ── Run all rounds ────────────────────────────────────────────────────────────

log "═══ Starting rounds ═══"

# Core infrastructure
check_docker postgres        ~/services/postgres       auto
check_docker redis           ~/services/redis          auto

# AI & LLM
check_systemd ollama         auto
check_docker  open-webui     ~/services/open-webui     auto
check_docker  hermes-agent   ~/services/hermes-agent   auto

# Workflow
check_docker n8n             ~/services/n8n            auto
check_docker qdrant          ~/services/qdrant         auto

# Trading
check_docker alpaca-bot      ~/services/alpaca-bot     auto
check_docker alpaca-dashboard ~/services/alpaca-bot    auto

# Security / Utilities
check_docker infra-dashboard ~/services/infra-dashboard auto
check_docker kali            ""                        alert   # no compose dir, alert only

# System daemons (alert only — don't auto-restart SSH)
check_systemd ssh            alert
check_systemd fail2ban       auto
check_systemd ufw            auto

# Endpoint smoke tests
check_url ollama-api   "http://localhost:11434/api/tags"    2
check_url open-webui   "http://localhost:8000"              2
check_url hermes       "http://localhost:9119/health"       4   # 401 = auth required = alive
check_url n8n          "http://localhost:3001"              2
check_url infra-dash   "http://localhost:7000"              2
check_url qdrant       "http://localhost:6333/collections"  2

log "═══ Rounds complete ═══"

# ── Build Slack notification (state changes only) ─────────────────────────────
MSG=""

if [ ${#RECOVERED[@]} -gt 0 ]; then
  NAMES=$(printf ' • %s\n' "${RECOVERED[@]}")
  MSG="$MSG\n✅ *Recovered on $HOSTNAME:*\n$NAMES"
fi

if [ ${#RESTORED[@]} -gt 0 ]; then
  NAMES=$(printf ' • %s\n' "${RESTORED[@]}")
  MSG="$MSG\n🔄 *Auto-restored on $HOSTNAME:*\n$NAMES"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  NAMES=$(printf ' • %s\n' "${FAILED[@]}")
  MSG="$MSG\n🚨 *DOWN (manual intervention needed) on $HOSTNAME:*\n$NAMES"
fi

if [ -n "$MSG" ]; then
  slack "$(echo -e "$MSG\n_$(date '+%Y-%m-%d %H:%M %Z')_")"
fi

# Exit non-zero if any persistent failures
[ ${#FAILED[@]} -eq 0 ]
