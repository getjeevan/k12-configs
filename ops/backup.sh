#!/bin/bash
# backup.sh — Daily automated backup
# Schedule: 0 2 * * * /home/getjeevan/ops/scripts/backup.sh >> /var/log/ops-backup.log 2>&1

BACKUP_DIR="/home/getjeevan/ops/backups"
REMOTE="root@187.124.240.44"
REMOTE_DIR="/root/backups/jeevans"
DATE=$(date +%Y-%m-%d)
source ~/ops/secrets/slack.env
LOG_PREFIX="[backup $DATE]"

slack_err() {
  curl -s -X POST -H 'Content-type: application/json' \
    --data "{\"text\":\"❌ *Backup FAILED* — $1\"}" "$SLACK_WEBHOOK" > /dev/null
}

mkdir -p "$BACKUP_DIR/$DATE"
echo "$LOG_PREFIX Starting backup..."

# ── 1. PostgreSQL dump ────────────────────────────────────────────────────────
echo "$LOG_PREFIX Dumping PostgreSQL..."
docker exec postgres pg_dumpall -U postgres > "$BACKUP_DIR/$DATE/postgres_full.sql" 2>&1
if [ $? -ne 0 ]; then
  slack_err "PostgreSQL dump failed"
  echo "$LOG_PREFIX ERROR: PostgreSQL dump failed"
fi

# ── 2. .env files ─────────────────────────────────────────────────────────────
echo "$LOG_PREFIX Backing up .env files..."
mkdir -p "$BACKUP_DIR/$DATE/env"
find /home/getjeevan -name ".env" -not -path "*/node_modules/*" \
  -exec cp --parents {} "$BACKUP_DIR/$DATE/env/" \; 2>/dev/null

# ── 3. Hermes data ────────────────────────────────────────────────────────────
echo "$LOG_PREFIX Backing up Hermes data..."
docker cp hermes-agent:/root/.hermes/memories "$BACKUP_DIR/$DATE/hermes-memories" 2>/dev/null
docker cp hermes-agent:/root/.hermes/sessions "$BACKUP_DIR/$DATE/hermes-sessions" 2>/dev/null

# ── 4. ops/docs ───────────────────────────────────────────────────────────────
echo "$LOG_PREFIX Backing up ops docs..."
cp -r /home/getjeevan/ops/docs "$BACKUP_DIR/$DATE/ops-docs"

# ── 5. System configs ─────────────────────────────────────────────────────────
echo "$LOG_PREFIX Backing up system configs..."
mkdir -p "$BACKUP_DIR/$DATE/system"
cp -r /etc/nginx "$BACKUP_DIR/$DATE/system/" 2>/dev/null
cp /etc/crontab "$BACKUP_DIR/$DATE/system/" 2>/dev/null
crontab -l > "$BACKUP_DIR/$DATE/system/user-crontab.txt" 2>/dev/null
cp /etc/sudoers.d/venkats "$BACKUP_DIR/$DATE/system/" 2>/dev/null

# ── 6. Compress ───────────────────────────────────────────────────────────────
echo "$LOG_PREFIX Compressing..."
tar -czf "$BACKUP_DIR/backup-$DATE.tar.gz" -C "$BACKUP_DIR" "$DATE"
rm -rf "$BACKUP_DIR/$DATE"

# ── 7. Sync to Hostinger VPS ─────────────────────────────────────────────────
echo "$LOG_PREFIX Syncing to remote..."
ssh -o StrictHostKeyChecking=no "$REMOTE" "mkdir -p $REMOTE_DIR"
rsync -az --delete "$BACKUP_DIR/" "$REMOTE:$REMOTE_DIR/" 2>&1
if [ $? -ne 0 ]; then
  slack_err "rsync to Hostinger failed — local backup still exists"
  echo "$LOG_PREFIX WARNING: Remote sync failed"
fi

# ── 8. Cleanup old local backups (keep 7 days) ────────────────────────────────
find "$BACKUP_DIR" -name "backup-*.tar.gz" -mtime +7 -delete
echo "$LOG_PREFIX Cleanup done. Kept last 7 days."

# ── 9. Done ───────────────────────────────────────────────────────────────────
SIZE=$(du -sh "$BACKUP_DIR/backup-$DATE.tar.gz" 2>/dev/null | cut -f1)
echo "$LOG_PREFIX Backup complete. Size: $SIZE"
