#!/bin/bash
# wp-db-import.sh
# Run on HECATE as root to create a WordPress database and user, import a
# dump file, and optionally update wp-config.php and run a URL
# search-replace via WP-CLI.
#
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
COMPOSE_HOME=/home/pascalharris/lemp-compose
PHPFPM_SERVICE=phpfpm-45rpm
WP_DOCROOT="${COMPOSE_HOME}/public/45rpm/htdocs/blog"

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    echo "       Use: sudo ./wp-db-import.sh" >&2
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress Database Import — Hecate"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Helper: run SQL against the maria-db container ───────────────────────────
# Uses db_backup.cnf so no password ever appears on the command line.
run_sql() {
    docker compose -f "${COMPOSE_HOME}/docker-compose.yml" \
        exec -T maria-db \
        mariadb \
        --defaults-extra-file=/etc/mysql/backup.cnf \
        --protocol=tcp --host=127.0.0.1 \
        "$@"
}

# ── Step 1: Locate the dump file ──────────────────────────────────────────────
read -rp "Path to the SQL dump file: " DUMP_FILE
if [[ ! -f "${DUMP_FILE}" ]]; then
    echo "Error: file not found: ${DUMP_FILE}" >&2
    exit 1
fi
SIZE=$(du -sh "${DUMP_FILE}" | cut -f1)
echo "  Found: ${DUMP_FILE} (${SIZE})"
echo ""

# ── Step 2: Database and user names ──────────────────────────────────────────
read -rp "New database name [wordpress_45rpm]: " DB_NAME
DB_NAME="${DB_NAME:-wordpress_45rpm}"

read -rp "New database username [wp_45rpm]: " DB_USER
DB_USER="${DB_USER:-wp_45rpm}"

# ── Step 3: Generate and display the WordPress DB password ───────────────────
DB_PASSWORD=$(openssl rand -base64 24)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Generated password for '${DB_USER}' — save this now:"
echo ""
echo "  ${DB_PASSWORD}"
echo ""
echo "  You will need it for wp-config.php."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Press Enter once saved to continue..."

# ── Confirm before making any changes ────────────────────────────────────────
echo ""
echo "  Dump file: ${DUMP_FILE}"
echo "  Database:  ${DB_NAME}"
echo "  User:      ${DB_USER}"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ "${CONFIRM^^}" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Step 4: Create the database and user ─────────────────────────────────────
echo ""
echo "--> Creating database '${DB_NAME}' and user '${DB_USER}'..."

run_sql -e "
    CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_unicode_ci;
    CREATE USER IF NOT EXISTS '${DB_USER}'@'%'
        IDENTIFIED BY '${DB_PASSWORD}';
    GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
    FLUSH PRIVILEGES;
"
echo "    Done."

# ── Step 5: Import the dump ───────────────────────────────────────────────────
echo ""
echo "--> Importing dump into '${DB_NAME}'..."
echo "    (This may take a moment for large databases.)"

docker compose -f "${COMPOSE_HOME}/docker-compose.yml" \
    exec -T maria-db \
    mariadb \
    --defaults-extra-file=/etc/mysql/backup.cnf \
    --protocol=tcp --host=127.0.0.1\
    "${DB_NAME}" < "${DUMP_FILE}"

echo "    Import complete."

# ── Step 6: Update wp-config.php ─────────────────────────────────────────────
WP_CONFIG="${WP_DOCROOT}/wp-config.php"
echo ""

if [[ -f "${WP_CONFIG}" ]]; then
    read -rp "Update wp-config.php with the new credentials? [Y/n]: " UPDATE_CONFIG
    UPDATE_CONFIG="${UPDATE_CONFIG:-Y}"
    if [[ "${UPDATE_CONFIG^^}" == "Y" ]]; then
        cp "${WP_CONFIG}" "${WP_CONFIG}.bak"
        echo "    Backed up to ${WP_CONFIG}.bak"

        # sed uses | as delimiter throughout so that base64 characters
        # (A-Z, a-z, 0-9, +, /, =) in the password never break the
        # expression. The pattern [^)]* matches up to the closing paren.
        sed -i "s|define( *'DB_NAME'[^)]*)|define( 'DB_NAME', '${DB_NAME}' )|g"     "${WP_CONFIG}"
        sed -i "s|define( *'DB_USER'[^)]*)|define( 'DB_USER', '${DB_USER}' )|g"     "${WP_CONFIG}"
        sed -i "s|define( *'DB_PASSWORD'[^)]*)|define( 'DB_PASSWORD', '${DB_PASSWORD}' )|g" "${WP_CONFIG}"
        # DB_HOST must be the Docker service name, not localhost, because
        # PHP-FPM reaches MariaDB over the internal Docker network.
        sed -i "s|define( *'DB_HOST'[^)]*)|define( 'DB_HOST', 'maria-db' )|g"       "${WP_CONFIG}"

        echo "    wp-config.php updated."
    fi
else
    echo "NOTE: wp-config.php not found at ${WP_CONFIG}"
    echo "      Create or copy it from the old server and set these values:"
    echo ""
    echo "        define( 'DB_NAME',     '${DB_NAME}' );"
    echo "        define( 'DB_USER',     '${DB_USER}' );"
    echo "        define( 'DB_PASSWORD', '${DB_PASSWORD}' );"
    echo "        define( 'DB_HOST',     'maria-db' );"
fi

# ── Step 7: Optional URL search-replace ──────────────────────────────────────
echo ""
read -rp "Run WP-CLI URL search-replace now? [y/N]: " DO_REPLACE
DO_REPLACE="${DO_REPLACE:-N}"

if [[ "${DO_REPLACE^^}" == "Y" ]]; then
    read -rp "Old site URL (e.g. http://old.example.com): " OLD_URL
    read -rp "New site URL (e.g. https://45rpmsoftware.com): " NEW_URL

    echo ""
    echo "--> Replacing '${OLD_URL}' with '${NEW_URL}' across all tables..."

    docker compose -f "${COMPOSE_HOME}/docker-compose.yml" \
        exec -T -u www-data "${PHPFPM_SERVICE}" \
        wp --path=/var/www/html \
        search-replace "${OLD_URL}" "${NEW_URL}" \
        --all-tables

    echo "    Done."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Migration complete."
echo ""
echo "  Database: ${DB_NAME}"
echo "  User:     ${DB_USER}"
echo ""
echo "  Next steps:"
echo "  1. Copy wp-content/ files from the old server (especially uploads/)."
echo "  2. Rename wp-content/--plugins to wp-content/plugins if applicable."
echo "  3. Test via /etc/hosts on your Mac before DNS cutover."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
