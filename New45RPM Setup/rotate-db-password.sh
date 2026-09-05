#!/bin/bash
# rotate-db-password.sh
# Run on the HOST as root any time the MariaDB root password needs changing.
# Generates a cryptographically random replacement, applies it to the live
# database, and updates both secret files atomically.
#
set -euo pipefail

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    echo "       Use: sudo ./rotate-db-password.sh" >&2
    exit 1
fi

COMPOSE_HOME=/home/pascalharris/lemp-compose
SECRETS_DIR=/root/secrets

NEW_PASSWORD=$(openssl rand -base64 32)

# 1. Change the *running* database's actual root password, authenticating
#    with the file that still has the OLD password at this point (we
#    haven't overwritten it yet). --defaults-extra-file keeps the password
#    off the command line entirely, so it never appears in `ps` output.
#
#    --defaults-extra-file MUST be the first argument to mariadb or it is
#    rejected with "unknown variable". --protocol=tcp forces a TCP
#    connection rather than the Unix socket, ensuring both root accounts
#    ('root'@'localhost' and 'root'@'%') are updated in the same statement
#    and can never drift out of sync.
docker compose -f "$COMPOSE_HOME/docker-compose.yml" exec -T maria-db \
    mariadb \
    --defaults-extra-file=/etc/mysql/backup.cnf \
    --protocol=tcp --host=127.0.0.1 \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASSWORD}';
        ALTER USER 'root'@'%'         IDENTIFIED BY '${NEW_PASSWORD}';
        FLUSH PRIVILEGES;"

# 2. Bring both secret files up to date.
#    db_root_password.txt is only read by MariaDB on first-run initialisation
#    of an empty data directory -- updating it here keeps it correct as a
#    disaster-recovery source of truth if the data directory is ever rebuilt.
printf '%s'                                 "$NEW_PASSWORD" \
    > "$SECRETS_DIR/db_root_password.txt"
printf '[client]\nuser=root\npassword=%s\n' "$NEW_PASSWORD" \
    > "$SECRETS_DIR/db_backup.cnf"
chmod 600  "$SECRETS_DIR/db_root_password.txt" "$SECRETS_DIR/db_backup.cnf"
chown root:root "$SECRETS_DIR/db_root_password.txt" "$SECRETS_DIR/db_backup.cnf"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Password rotated. New MariaDB root password:"
echo ""
echo "  ${NEW_PASSWORD}"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Update your password manager, then update Sequel Ace"
echo "  and DataGrip if you have the password saved there."
echo ""
echo "  If a WordPress install exists, also update wp-config.php"
echo "  for any database user whose password you rotated separately."
echo ""
