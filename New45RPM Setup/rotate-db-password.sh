#!/bin/bash
#
# Rotate the MariaDB root password used by docker-compose.yml and by
# maintenance.sh's backup step. Run on the HOST, as root, any time the
# password needs changing (including right now, for the password that
# was exposed while drafting this setup).
#
set -euo pipefail

COMPOSE_HOME=/home/pascalharris/lemp-compose
SECRETS_DIR=/root/secrets

NEW_PASSWORD=$(openssl rand -base64 32)

# 1. Change the *running* database's actual root password, authenticating
#    with the file that still has the OLD password at this point (we
#    haven't overwritten it yet). --defaults-extra-file keeps the
#    password off the command line entirely, so it never appears in `ps`.
docker compose -f "$COMPOSE_HOME/docker-compose.yml" exec -T maria-db \
  mariadb \
  --protocol=tcp --host=127.0.0.1 \
  --defaults-extra-file=/etc/mysql/backup.cnf \
  -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASSWORD}';
      ALTER USER 'root'@'%'         IDENTIFIED BY '${NEW_PASSWORD}';
      FLUSH PRIVILEGES;"

# 2. Now bring both files that reference the password up to date.
#    (db_root_password.txt is only read by MariaDB on first-run
#    initialisation of an empty data directory -- updating it here doesn't
#    itself change anything live, it just keeps it correct as the
#    disaster-recovery source of truth if the data directory is ever
#    rebuilt from scratch.)
printf '%s' "$NEW_PASSWORD" > "$SECRETS_DIR/db_root_password.txt"
printf '[client]\nuser=root\npassword=%s\n' "$NEW_PASSWORD" > "$SECRETS_DIR/db_backup.cnf"
chmod 600 "$SECRETS_DIR"/db_root_password.txt "$SECRETS_DIR"/db_backup.cnf
chown root:root "$SECRETS_DIR"/db_root_password.txt "$SECRETS_DIR"/db_backup.cnf

echo "Password rotated."
echo "Update any application that connects with the old password separately"
echo "-- e.g. wp-config.php once a WordPress site is installed -- this"
echo "script only covers the root account and this stack's own scripts."
