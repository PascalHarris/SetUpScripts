#!/bin/bash
#
# Quarterly site maintenance for 45rpmsoftware.com.
#
# Run unattended via site-maintenance.timer (see systemd/ -- installs to
# /etc/systemd/system/). Can also be run by hand: sudo ./maintenance.sh
#
# Deliberately NOT doing any more in this script:
#   - TLS renewal. certbot has its own systemd timer running twice daily
#     and only actually renews (and fires certbot-deploy-hook.sh) when a
#     cert is within 30 days of expiry -- far tighter than this script's
#     quarterly cadence. See server-setup-guide.md "TLS certificates".
#   - Security patching. unattended-upgrades applies security updates
#     daily on its own. This script's apt step below is for everything
#     ELSE (feature/bugfix updates) that unattended-upgrades intentionally
#     leaves alone.
#   - Rotating nginx/php-fpm's own log files. Those are written to
#     continuously by long-running processes, so they're handled by
#     logrotate on its normal daily schedule (see
#     logrotate-45rpm-site.conf) rather than waiting up to three months
#     for this script. This script's own housekeeping step below is for
#     things that only need clearing out periodically: apt/Docker caches,
#     old kernels, the journal, and this script's own historical output.
#
set -uo pipefail
# Deliberately not `-e`: one failed step shouldn't stop the rest running
# (or stop the failure e-mail going out) -- each step's exit status is
# checked explicitly instead, and $errors is what decides the exit code.

start=$(date +%s)
errors=0

# ---- configuration -------------------------------------------------------
COMPOSE_HOME=/home/pascalharris/lemp-compose
SUPPORT_EMAIL=support@45rpmsoftware.com
OWNER_ACCOUNT=pascalharris
BACKUP_RETENTION=4        # quarterly local backups kept (~1 year)
WP_SNAPSHOT_RETENTION=2   # WordPress pre-update snapshots kept (~6 months)
LOG_RETENTION=8           # this script's own run-logs kept (~2 years)
JOURNAL_RETENTION=90d     # systemd journal trimmed to this age
LOGFILE="/var/log/site-maintenance/$(date +%Y%m%d_%H%M%S).log"

declare -a sites
sites[0]='www.45rpmsoftware.com;45rpmsoftware.com'
#sites[1]='www.sfmaskco.com;sfmaskco.com'
#sites[2]='www.thesavingfacemask.com;thesavingfacemask.com;www.thesavingfacemask.co.uk;thesavingfacemask.co.uk'
#sites[3]='www.fresserei.com'

mkdir -p "$(dirname "$LOGFILE")"
exec > >(tee -a "$LOGFILE") 2>&1

fail() {
  echo "**ERROR** $1"
  errors=$((errors + 1))
}

# ---- pre-flight ------------------------------------------------------------
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
  echo "Not running as root. Run via sudo, or via the systemd unit (which runs as root)."
  exit 1
fi
if [ ! -d "$COMPOSE_HOME" ]; then
  echo "**ERROR** Docker directory '$COMPOSE_HOME' doesn't exist"
  exit 1
fi

cd "$COMPOSE_HOME" || { echo "**ERROR** Could not cd to $COMPOSE_HOME"; exit 1; }

echo "Site maintenance starting: $(date)"

# ---- 1. Database backup -----------------------------------------------------
echo "-> Backing up database"
if docker compose exec -T maria-db mysqldump \
      --defaults-extra-file=/etc/mysql/backup.cnf \
      --lock-tables --all-databases > "$COMPOSE_HOME/db-data/db_backup.sql"; then
  echo "   Database backup OK"
else
  fail "Database backup failed"
fi

# ---- 2. Site file backup, with retention -----------------------------------
echo "-> Backing up site files"
now=$(date +"%m_%d_%Y")
backup_file="small_backup_$now.tar.gz"
# --exclude/--exclude-from must come BEFORE the source path (".") -- GNU tar
# treats them as positional and silently ignores them placed after.
if tar cpzf "$backup_file" --exclude="$backup_file" --exclude-from <(find . -size +100M) .; then
  chown "$OWNER_ACCOUNT":"$OWNER_ACCOUNT" "$backup_file"
  echo "   Site backup OK: $backup_file"
else
  fail "Site backup failed"
fi

echo "-> Pruning local backups older than the last $BACKUP_RETENTION"
# shellcheck disable=SC2012
ls -1t small_backup_*.tar.gz 2>/dev/null | tail -n "+$((BACKUP_RETENTION + 1))" | xargs -r rm -f --

# ---- 3. Pull and restart containers -----------------------------------------
echo "-> Pulling and restarting containers"
if docker compose pull && docker compose up -d --remove-orphans; then
  echo "   Containers updated"
else
  fail "docker compose pull/up failed"
fi

# ---- 4. WordPress updates (skipped until a site is actually installed) -----
echo "-> WordPress updates"
WP_DOCROOT="$COMPOSE_HOME/public/45rpm/htdocs/blog"
if [ -f "$WP_DOCROOT/wp-config.php" ]; then
  if "$COMPOSE_HOME/wp-update.sh" "$WP_DOCROOT" phpfpm-45rpm "https://45rpmsoftware.com/blog"; then
    echo "   WordPress updated"
  else
    fail "WordPress update failed or was rolled back -- check the log above"
  fi
else
  echo "   No wp-config.php found at $WP_DOCROOT yet -- skipping (nothing to update)."
fi

# ---- 5. Everything else apt hasn't already patched daily -------------------
echo "-> Full apt upgrade"
if apt-get update && apt-get -y full-upgrade; then
  echo "   apt upgrade OK"
else
  fail "apt upgrade failed"
fi

# ---- 6. Housekeeping: free up disk space -----------------------------------
echo "-> Disk usage before housekeeping:"
df -h / "$COMPOSE_HOME"
docker system df

echo "-> Clearing stale apt cache and old kernels/packages"
if apt-get -y autoremove --purge && apt-get clean; then
  echo "   apt cleanup OK"
else
  fail "apt cleanup failed"
fi

echo "-> Pruning dangling Docker images and build cache"
# Plain (non -a) prune only: removes untagged/dangling layers left behind
# when a pinned tag like mariadb:11.4 is re-pulled, never anything a
# running container still references -- so this is safe to run
# unattended, unlike `docker system prune -a`.
docker image prune -f
docker builder prune -f

echo "-> Trimming the systemd journal to the last $JOURNAL_RETENTION"
journalctl --vacuum-time="$JOURNAL_RETENTION"

echo "-> Pruning old WordPress pre-update snapshots (keeping last $WP_SNAPSHOT_RETENTION)"
# shellcheck disable=SC2012
ls -1t "$COMPOSE_HOME"/wp-snapshots/*.tar.gz 2>/dev/null | tail -n "+$((WP_SNAPSHOT_RETENTION + 1))" | xargs -r rm -f --

echo "-> Pruning old maintenance run-logs (keeping last $LOG_RETENTION)"
# shellcheck disable=SC2012
ls -1t /var/log/site-maintenance/*.log 2>/dev/null | tail -n "+$((LOG_RETENTION + 1))" | xargs -r rm -f --

echo "-> Disk usage after housekeeping:"
df -h / "$COMPOSE_HOME"

# ---- wrap up -----------------------------------------------------------------
end=$(date +%s)
runtime=$((end - start))
echo "Maintenance took $runtime seconds to complete, with $errors error(s)."

if [ "$errors" -gt 0 ] && command -v mail >/dev/null 2>&1; then
  mail -s "[45RPM] Site maintenance FAILED ($errors error(s))" "$SUPPORT_EMAIL" < "$LOGFILE"
fi

exit "$errors"
