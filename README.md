# K12 Server Config Backups

Automated nightly backup of K12 infrastructure configs.

**Server:** K12 (192.168.1.168) — Ubuntu 24.04.4 LTS  
**Backup time:** 23:50 daily  
**Script:** ~/ops/scripts/config-backup.sh

## Structure

```
services/       docker-compose.yml for each service
ops/            maintenance scripts (backup, health-check, rounds, cleanup)
systemd/        systemd service/drop-in configs
```

> ⚠️ .env files and secrets are excluded via .gitignore
