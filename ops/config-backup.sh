#!/bin/bash
# config-backup.sh — Nightly config snapshot to GitHub
# Schedule: 50 23 * * * /home/getjeevan/ops/scripts/config-backup.sh >> /var/log/ops-config-backup.log 2>&1

REPO=/home/getjeevan/ops/k12-configs
TS=$(date '+%Y-%m-%d %H:%M:%S')
DATE=$(date '+%Y-%m-%d')
source ~/ops/secrets/slack.env 2>/dev/null || true

log() { echo "[$TS] $*"; }
slack() {
  [ -n "$SLACK_WEBHOOK" ] && curl -s -X POST -H 'Content-type: application/json'     --data "{\"text\":\"$1\"}" "$SLACK_WEBHOOK" > /dev/null
}

log "=== Config backup starting ==="

# ── 1. Refresh all docker-compose files ────────────────────────────────────────
for dir in ~/services/*/; do
  svc=$(basename "$dir")
  mkdir -p "$REPO/services/$svc"
  [ -f "$dir/docker-compose.yml" ] && cp "$dir/docker-compose.yml" "$REPO/services/$svc/docker-compose.yml"
done

# ── 2. Ops scripts (strip secrets before copy) ────────────────────────────────
for f in ~/ops/scripts/*.sh; do
  name=$(basename "$f")
  cp "$f" "$REPO/ops/$name"
  # Remove any accidentally hardcoded webhook URLs
  sed -i 's|https://hooks\.slack\.com/services/[A-Za-z0-9/]*|${SLACK_WEBHOOK}|g' "$REPO/ops/$name"
  sed -i 's|^SLACK_WEBHOOK=.*|source ~/ops/secrets/slack.env|' "$REPO/ops/$name"
done

# ── 3. Systemd drop-ins ───────────────────────────────────────────────────────
sudo cp /etc/systemd/system/ollama.service.d/rocm.conf $REPO/systemd/ollama-rocm.conf 2>/dev/null || true
sudo cp /etc/systemd/system/ollama.service $REPO/systemd/ollama.service 2>/dev/null || true

# ── 4. Crontab snapshot ───────────────────────────────────────────────────────
crontab -l > $REPO/ops/crontab.bak 2>/dev/null || true

# ── 5. Commit and push ────────────────────────────────────────────────────────
cd $REPO
git add -A

if git diff --cached --quiet; then
  log "No changes — nothing to commit"
  exit 0
fi

git commit -m "chore: nightly config backup $DATE

Auto-snapshot of all service configs, ops scripts, and systemd units."

if git push origin main 2>&1; then
  log "Push successful"
  slack "✅ *K12 config backup pushed* — $DATE | $(git rev-parse --short HEAD)"
else
  log "Push FAILED"
  slack "⚠️ *K12 config backup PUSH FAILED* — $DATE\nCheck /var/log/ops-config-backup.log"
  exit 1
fi

log "=== Config backup complete ==="
