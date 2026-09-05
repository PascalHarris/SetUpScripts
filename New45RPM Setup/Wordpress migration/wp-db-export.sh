#!/bin/bash
# wp-db-export.sh
# Run on the OLD server as root to dump the WordPress database ready for
# migration to Hecate. Outputs a timestamped .sql file in the current
# directory.
#
set -euo pipefail

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: this script must be run as root." >&2
    echo "       Use: sudo ./wp-db-export.sh" >&2
    exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress Database Export"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Detect docker compose command (v1 uses hyphen, v2 does not) ──────────────
if docker compose version &>/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    echo "Error: neither 'docker compose' nor 'docker-compose' found." >&2
    exit 1
fi

# ── Show running services to help identify the right container ───────────────
echo "Running Docker services:"
$DC ps 2>/dev/null || echo "  (could not list services -- check you are in the right directory)"
echo ""

read -rp "MariaDB service name [mariadb]: " DB_SERVICE
DB_SERVICE="${DB_SERVICE:-mariadb}"

# ── Prompt for password (read silently so it is never shown on screen) ───────
echo ""
read -rsp "MariaDB root password: " OLD_PASSWORD
echo ""

# ── List available databases ──────────────────────────────────────────────────
echo ""
echo "Available databases:"
$DC exec -e MYSQL_PWD="${OLD_PASSWORD}" -T "${DB_SERVICE}" \
    mariadb -u root \
    -e "SHOW DATABASES;" 2>/dev/null \
|| $DC exec -e MYSQL_PWD="${OLD_PASSWORD}" -T "${DB_SERVICE}" \
    mysql -u root \
    -e "SHOW DATABASES;"
echo ""

# ── Prompt for the database to export ────────────────────────────────────────
read -rp "WordPress database name to export: " DB_NAME
if [[ -z "${DB_NAME}" ]]; then
    echo "Error: database name is required." >&2
    exit 1
fi

# ── Confirm before running ────────────────────────────────────────────────────
echo ""
echo "  Service:  ${DB_SERVICE}"
echo "  Database: ${DB_NAME}"
echo ""
read -rp "Proceed with export? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ "${CONFIRM^^}" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# ── Run the dump ──────────────────────────────────────────────────────────────
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="wordpress_export_${TIMESTAMP}.sql"

echo ""
echo "--> Dumping '${DB_NAME}' to ${OUTPUT_FILE} ..."

# MYSQL_PWD is passed via -e so the password never appears on the command
# line (and therefore never in `ps` output). The mariadb client emits a
# deprecation notice for MYSQL_PWD to stderr; that is separate from the
# dump on stdout and does not affect the output file.
$DC exec -e MYSQL_PWD="${OLD_PASSWORD}" -T "${DB_SERVICE}" \
    mysqldump \
    -u root \
    --single-transaction \
    --routines \
    --triggers \
    "${DB_NAME}" > "${OUTPUT_FILE}"

SIZE=$(du -sh "${OUTPUT_FILE}" | cut -f1)

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Export complete."
echo ""
echo "  File: ${OUTPUT_FILE}"
echo "  Size: ${SIZE}"
echo ""
echo "  Transfer this file to Hecate, then run"
echo "  wp-db-import.sh as root on Hecate."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
