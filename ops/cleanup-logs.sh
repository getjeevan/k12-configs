#!/bin/bash
# cleanup-logs.sh — Weekly log cleanup
# Schedule: 0 3 * * 0 /home/getjeevan/ops/scripts/cleanup-logs.sh

echo "[cleanup $(date)] Starting log cleanup..."

# Docker container logs (truncate if > 100MB)
for log in /var/lib/docker/containers/*/*-json.log; do
  SIZE=$(stat -c%s "$log" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 104857600 ]; then
    CNAME=$(docker inspect --format '{{.Name}}' $(basename $(dirname $log)) 2>/dev/null | tr -d '/')
    echo "Truncating large log: $CNAME ($((SIZE/1024/1024))MB)"
    truncate -s 0 "$log"
  fi
done

# System journal (keep last 500MB)
journalctl --vacuum-size=500M

# Old tmp files
find /tmp -type f -mtime +3 -delete 2>/dev/null

echo "[cleanup $(date)] Done."
