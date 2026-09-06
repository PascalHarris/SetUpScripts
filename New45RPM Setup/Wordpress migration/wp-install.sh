#!/bin/bash
# wp-install.sh
#
# Installs a fresh WordPress at:
#   lemp-compose/public/45rpm/htdocs/blog   (host path)
#   /var/www/html/blog                       (container path)
#
# Also installs and activates:
#   - Akismet (spam filtering)
#   - Jetpack (security, stats, social sharing)
#   - Twenty Seventeen (parent theme, from wordpress.org)
#   - 45rpmV2 (child theme -- zip must sit alongside this script)
#
# Prerequisites:
#   - Run as root (sudo)
#   - maria-db container must be running (docker compose ps)
#   - Database and user must already exist (see wp-db-import.sh, or
#     create them manually -- the script will prompt for the details)
#   - 45rpmV2.zip must be in the same directory as this script
#
# This script is for a FRESH install only. If migrating from the old
# server, use wp-db-import.sh to import the existing database and copy
# the WordPress files across instead. Do not run both.
#
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
COMPOSE_HOME=/home/pascalharris/lemp-compose
BLOG_HOST_PATH="${COMPOSE_HOME}/public/45rpm/htdocs/blog"
BLOG_CONTAINER_PATH="/var/www/html/blog"
PHPFPM_SERVICE=phpfpm-45rpm

# ── Privilege check ───────────────────────────────────────────────────────────
if [[ "$(id -u)" -ne 0 ]]; then
    echo "Error: run as root. Use: sudo ./wp-install.sh" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress Install — 45RPM Software Blog"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────

# Theme zip
THEME_ZIP="${SCRIPT_DIR}/45rpmV2.zip"
if [[ ! -f "${THEME_ZIP}" ]]; then
    echo "Error: 45rpmV2.zip not found in ${SCRIPT_DIR}." >&2
    echo "       Place the theme zip alongside this script and re-run." >&2
    exit 1
fi

# WP-CLI available in the container
if ! docker compose -f "${COMPOSE_HOME}/docker-compose.yml" \
        exec -T -u www-data "${PHPFPM_SERVICE}" wp --info > /dev/null 2>&1; then
    echo "Error: WP-CLI not found in ${PHPFPM_SERVICE}." >&2
    echo "       Ensure the container is running and was built from the" >&2
    echo "       php-fpm/Dockerfile in lemp-compose." >&2
    exit 1
fi

# Guard against clobbering an existing install
if [[ -f "${BLOG_HOST_PATH}/wp-config.php" ]]; then
    echo "WARNING: wp-config.php already exists at ${BLOG_HOST_PATH}."
    echo "         This script is for fresh installs only. If migrating"
    echo "         from the old server, see wp-db-import.sh instead."
    echo ""
    read -rp "Continue and overwrite? [y/N]: " OVERWRITE
    if [[ "${OVERWRITE^^}" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ── Gather details ────────────────────────────────────────────────────────────

echo "Database credentials (created by wp-db-import.sh or manually):"
read -rp "  Database name [wordpress_45rpm]: " DB_NAME
DB_NAME="${DB_NAME:-wordpress_45rpm}"

read -rp "  Database user [wp_45rpm]: " DB_USER
DB_USER="${DB_USER:-wp_45rpm}"

read -rsp "  Database password: " DB_PASS
echo ""

echo ""
echo "WordPress site settings:"
read -rp "  Site URL [https://45rpmsoftware.com/blog]: " SITE_URL
SITE_URL="${SITE_URL:-https://45rpmsoftware.com/blog}"

read -rp "  Blog title [45RPM Software Blog]: " BLOG_TITLE
BLOG_TITLE="${BLOG_TITLE:-45RPM Software Blog}"

read -rp "  Admin username [admin]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-admin}"

read -rp "  Admin email [support@45rpmsoftware.com]: " ADMIN_EMAIL
ADMIN_EMAIL="${ADMIN_EMAIL:-support@45rpmsoftware.com}"

# Generate a secure admin password and show it once
ADMIN_PASS=$(openssl rand -base64 18)
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  WordPress admin password — save this now:"
echo ""
echo "  ${ADMIN_PASS}"
echo ""
echo "  You will use it to log in at ${SITE_URL}/wp-admin"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
read -rp "Press Enter once saved to continue..."

echo ""
echo "Optional plugin keys (press Enter to skip and configure in wp-admin later):"
read -rp "  Akismet API key (https://akismet.com/account/): " AKISMET_KEY

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ready to install:"
echo "    URL:      ${SITE_URL}"
echo "    Title:    ${BLOG_TITLE}"
echo "    Admin:    ${ADMIN_USER} <${ADMIN_EMAIL}>"
echo "    Database: ${DB_NAME} @ maria-db (user: ${DB_USER})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
read -rp "Proceed? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ "${CONFIRM^^}" != "Y" ]]; then
    echo "Aborted."
    exit 0
fi

# ── WP-CLI helper — all commands target /var/www/html/blog ───────────────────
# WP_CLI_PHP_ARGS only affects child processes WP-CLI spawns, not WP-CLI's
# own PHP process. Calling php directly with -d memory_limit is the only
# reliable way to raise the limit for commands like `core download` that
# exhaust memory inside WP-CLI's own process (extracting a large zip).
wpcli() {
    docker compose -f "${COMPOSE_HOME}/docker-compose.yml" \
        exec -T -u www-data "${PHPFPM_SERVICE}" \
        php -d memory_limit=512M /usr/local/bin/wp \
        --path="${BLOG_CONTAINER_PATH}" "$@"
}

# ── Step 1: Create the blog directory ────────────────────────────────────────
echo ""
echo "--> Creating blog directory..."
mkdir -p "${BLOG_HOST_PATH}"

# The php:X-fpm-alpine image uses www-data uid 82; Ubuntu's www-data is
# uid 33. chown-ing to the name "www-data" on the host sets uid 33, which
# the container's www-data (uid 82) cannot write to. Resolve the uid/gid
# from inside the container so the value is always correct regardless of
# base image.
CONTAINER_UID=$(docker compose -f "${COMPOSE_HOME}/docker-compose.yml"     exec -T "${PHPFPM_SERVICE}" id -u www-data 2>/dev/null || echo "82")
CONTAINER_GID=$(docker compose -f "${COMPOSE_HOME}/docker-compose.yml"     exec -T "${PHPFPM_SERVICE}" id -g www-data 2>/dev/null || echo "82")
echo "    Container www-data uid=${CONTAINER_UID} gid=${CONTAINER_GID}"

chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${BLOG_HOST_PATH}"
echo "    ${BLOG_HOST_PATH}"

# ── Step 2: Download WordPress ───────────────────────────────────────────────
echo ""
echo "--> Downloading latest WordPress (en_GB locale)..."
wpcli core download --locale=en_GB
echo "    Done."

# ── Step 3: Create wp-config.php ─────────────────────────────────────────────
echo ""
echo "--> Creating wp-config.php..."
# DB_HOST is the Docker service name, not localhost — PHP-FPM reaches
# MariaDB over the Docker internal network.
wpcli config create \
    --dbname="${DB_NAME}" \
    --dbuser="${DB_USER}" \
    --dbpass="${DB_PASS}" \
    --dbhost="maria-db" \
    --dbcharset="utf8mb4" \
    --dbcollate="utf8mb4_unicode_ci" \
    --skip-check
echo "    Done."

# ── Step 4: Install WordPress (create tables and initial options) ─────────────
echo ""
echo "--> Running WordPress install..."
wpcli core install \
    --url="${SITE_URL}" \
    --title="${BLOG_TITLE}" \
    --admin_user="${ADMIN_USER}" \
    --admin_password="${ADMIN_PASS}" \
    --admin_email="${ADMIN_EMAIL}" \
    --skip-email
echo "    Done."

# ── Step 5: Install parent theme ─────────────────────────────────────────────
echo ""
echo "--> Installing Twenty Seventeen (parent theme)..."
# WordPress no longer ships with Twenty Seventeen by default in recent
# versions, so we install it explicitly from wordpress.org.
wpcli theme install twentyseventeen
echo "    Done."

# ── Step 6: Install 45rpmV2 child theme ──────────────────────────────────────
echo ""
echo "--> Installing 45rpmV2 theme..."
# Copy the zip into the htdocs tree so the container can reach it,
# install it via WP-CLI, then remove the temporary copy.
cp "${THEME_ZIP}" "${BLOG_HOST_PATH}/"
wpcli theme install "${BLOG_CONTAINER_PATH}/45rpmV2.zip" --activate
rm -f "${BLOG_HOST_PATH}/45rpmV2.zip"
echo "    Done."

# ── Step 7: Install and activate plugins ─────────────────────────────────────
echo ""
echo "--> Installing Akismet..."
wpcli plugin install akismet --activate
echo ""
echo "--> Installing Jetpack..."
wpcli plugin install jetpack --activate
echo "    Done."

# ── Step 8: Configure Akismet if a key was supplied ──────────────────────────
if [[ -n "${AKISMET_KEY}" ]]; then
    echo ""
    echo "--> Configuring Akismet API key..."
    wpcli option update wordpress_api_key "${AKISMET_KEY}"
    echo "    Done."
fi

# ── Step 9: Sensible initial options ─────────────────────────────────────────
echo ""
echo "--> Setting initial options..."

# SEO-friendly permalink structure
wpcli rewrite structure '/%year%/%monthnum%/%postname%/' --hard

# Hold comments for moderation until approved; send notification emails
wpcli option update comment_moderation 1
wpcli option update moderation_notify 1

# Enable comment threading
wpcli option update thread_comments 1

# Delete the default sample content
wpcli post delete 1 --force 2>/dev/null || true   # Hello World post
wpcli post delete 2 --force 2>/dev/null || true   # Sample page

echo "    Done."

# ── Step 10: File permissions ─────────────────────────────────────────────────
echo ""
echo "--> Setting file permissions..."
# All files owned by www-data so PHP-FPM can write uploads and auto-updates
chown -R "${CONTAINER_UID}:${CONTAINER_GID}" "${BLOG_HOST_PATH}"
# Standard WordPress permissions: dirs 755, files 644
find "${BLOG_HOST_PATH}" -type d -exec chmod 755 {} \;
find "${BLOG_HOST_PATH}" -type f -exec chmod 644 {} \;
# wp-config.php holds DB credentials — tighter permissions
chmod 600 "${BLOG_HOST_PATH}/wp-config.php"
echo "    Done."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation complete."
echo ""
echo "  Blog URL:    ${SITE_URL}"
echo "  Admin panel: ${SITE_URL}/wp-admin"
echo "  Username:    ${ADMIN_USER}"
echo ""

if [[ -z "${AKISMET_KEY}" ]]; then
    echo "  ACTION NEEDED — Akismet:"
    echo "    Get an API key at https://akismet.com/account/"
    echo "    Then set it at Settings → Akismet Anti-Spam."
    echo ""
fi

echo "  ACTION NEEDED — Jetpack:"
echo "    Jetpack requires a WordPress.com account."
echo "    Complete connection at ${SITE_URL}/wp-admin"
echo ""
echo "  Test with /etc/hosts before cutting over DNS:"
echo "    Add to /etc/hosts on your Mac:"
echo "    <hecate-ip>  45rpmsoftware.com www.45rpmsoftware.com"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
