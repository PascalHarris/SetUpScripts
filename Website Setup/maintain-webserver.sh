#!/bin/bash
#
# Web Server Maintenance Script
# Handles database backup, site backup, and SSL certificate renewal
#
# Requires on the HOST running this script: docker, docker-compose, curl, tar
#
# Usage: ./maintain-webserver.sh [--config /path/to/setup.cfg]
#

set -euo pipefail  # Exit on error, undefined variables, and pipe failures

# Default configuration file location
CONFIG_FILE="./setup.cfg"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--config /path/to/setup.cfg]"
            exit 1
            ;;
    esac
done

# Load configuration file
if [ ! -f "$CONFIG_FILE" ]; then
    echo "ERROR: Configuration file '$CONFIG_FILE' not found"
    echo "Please create a configuration file or specify its location with --config"
    exit 1
fi

# Source configuration, filtering out comments and empty lines
eval "$(grep -v '^\s*#' "$CONFIG_FILE" | grep -v '^\s*$')"

# Validate required configuration variables
# NOTE: DB_CONTAINER should now be the docker-compose SERVICE name (e.g.
# "maria-db" as defined in lemp-compose/docker-compose.yml), not a raw
# container name -- see the DB backup step below for why.
REQUIRED_VARS=(
    "COMPOSE_HOME"
    "MAINT_HOME"
    "SUPPORT_EMAIL"
    "OWNER_ACCOUNT"
    "MAILSERVER_CERT"
    "DB_USER"
    "DB_CONTAINER"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: Required configuration variable '$var' is not set in $CONFIG_FILE"
        exit 1
    fi
done

# FIX: SITES is an array, so it can't go through the scalar REQUIRED_VARS
# check above (indirect expansion of an array name doesn't test emptiness
# correctly). Validate it separately so a missing/empty SITES in the
# config fails with a clear message instead of an "unbound variable"
# error later under `set -u`.
if [ "${#SITES[@]:-0}" -eq 0 ]; then
    echo "ERROR: No SITES defined in $CONFIG_FILE"
    exit 1
fi

# Function to retrieve database password securely
get_db_password() {
    local password=""
    
    # Method 1: Check for password file (most secure for this use case)
    local password_file="/etc/webserver-maint/db.passwd"
    if [ -f "$password_file" ]; then
        # Verify file permissions for security
        local perms=$(stat -c %a "$password_file")
        if [ "$perms" != "600" ] && [ "$perms" != "400" ]; then
            echo "WARNING: Password file $password_file has insecure permissions ($perms)"
            echo "         Should be 600 or 400. Run: chmod 600 $password_file"
        fi
        password=$(cat "$password_file")
        echo "$password"
        return 0
    fi
    
    # Method 2: Check environment variable
    if [ -n "${DB_PASSWORD:-}" ]; then
        echo "$DB_PASSWORD"
        return 0
    fi
    
    # Method 3: Prompt user (fallback, not ideal for automated scripts)
    echo "ERROR: Database password not found" >&2
    echo "Please either:" >&2
    echo "  1. Create password file: /etc/webserver-maint/db.passwd (recommended)" >&2
    echo "  2. Set environment variable: export DB_PASSWORD='your_password'" >&2
    echo "  3. Add DB_PASSWORD to a separate credentials file and source it" >&2
    exit 1
}

# Function to log messages with timestamps
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Function to log errors
log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Start timing
start_time=$(date +%s)

# Check if running as root
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    log_error "Not running as root"
    echo "Log back in as root, or use sudo, and try again."
    exit 1
fi

# Validate directory existence
if [ ! -d "$COMPOSE_HOME" ]; then
    log_error "Docker directory '$COMPOSE_HOME' doesn't exist"
    exit 1
fi

if [ ! -d "$MAINT_HOME" ]; then
    log_error "Docker maintenance directory '$MAINT_HOME' doesn't exist"
    exit 1
fi

# FIX: anchor every relative operation below (docker-compose commands,
# the site tar backup) to $COMPOSE_HOME explicitly, instead of relying on
# the caller's current directory. `docker-compose exec` (used for the DB
# backup below) also needs to run from the compose file's directory to
# resolve the project.
cd "$COMPOSE_HOME"

log "Site maintenance starting"

# Retrieve database password securely
DB_PASSWORD=$(get_db_password)
if [ -z "$DB_PASSWORD" ]; then
    log_error "Failed to retrieve database password"
    exit 1
fi

# Backup Database
log "Backing up database"
cat > "$COMPOSE_HOME/db-data/backupdb.sh" <<EOF
#!/bin/bash
/opt/bitnami/mariadb/bin/mysqldump --user=$DB_USER --password=$DB_PASSWORD --lock-tables --all-databases > /bitnami/db_backup.sql
EOF

rm -f "$COMPOSE_HOME/db-data/db_backup.sql"
chmod +x "$COMPOSE_HOME/db-data/backupdb.sh"
# FIX: address the DB service by its docker-compose SERVICE name rather
# than a container name. Compose's container-naming scheme has changed
# before (v1 "project_service_N" -> v2 "project-service-N"), which
# silently breaks a hardcoded/stale container name -- the service name in
# docker-compose.yml doesn't change. -T also drops TTY allocation, which
# `-i -t` would otherwise require and which fails under cron/unattended
# execution ("the input device is not a TTY").
docker-compose exec -T --user root "$DB_CONTAINER" bash -lc /bitnami/backupdb.sh

# Backup Site
log "Backing up site files"
backup_date=$(date +"%Y%m%d_%H%M%S")
backup_file="site_backup_${backup_date}.tar.gz"
# FIX: --exclude/--exclude-from must precede the source path (".") -- GNU
# tar treats them as positional and silently ignores them (now errors)
# when they appear after non-option arguments, which was also causing
# "file changed as we read it" (the growing archive was being read back
# into itself since its own exclude never took effect).
tar cpzf "$backup_file" \
    --exclude="$backup_file" \
    --exclude-from <(find . -size +"${BACKUP_MAX_FILE_SIZE:-100M}") \
    .
chown "$OWNER_ACCOUNT:$OWNER_ACCOUNT" "$backup_file"
log "Backup created: $backup_file"

# Renew Certificates
log "Renewing SSL certificates"
cd "$COMPOSE_HOME"
docker-compose stop

cd "$MAINT_HOME"
# FIX: docker-compose only recreates a container when its config changes,
# not on every `up`, so this can silently keep reusing a months-old image
# whose OS/package repos have since gone EOL or changed underneath it.
# Pull + force-recreate guarantees a current image every run.
docker-compose pull
docker-compose up -d --force-recreate
sleep 5

certdir="$COMPOSE_HOME/certificates"
if [ ! -d "$certdir" ]; then
    log "Certificates directory not found - creating it"
    mkdir -p "$certdir"
fi

maint_id="$(docker ps -q)"
if [ -z "$maint_id" ]; then
    log_error "No maintenance container found running"
    exit 1
fi
log "Docker maintenance container: $maint_id"

# Build certificate renewal commands
no_domains_found=true
fullcommand=""

for site in "${SITES[@]}"; do
    # FIX: lego v5 moved these from global flags (before the sub-command)
    # to command-level flags placed AFTER "run". See:
    # https://ldez.github.io/blog/2026/05/11/lego-v5/
    #   v4:  lego --http --email=... --domains=... --path=... run
    #   v5:  lego run --http --email=... --domains=... --path=...
    # --accept-tos added defensively: a fresh /etc/lego with no existing
    # account will need ToS acceptance to register. Drop it if /etc/lego
    # is a persistent volume with an already-registered account.
    command="lego run --http --accept-tos --email=\"$SUPPORT_EMAIL\" "
    domain_found=false
    
    # Split domains by semicolon
    IFS=';' read -ra domain_array <<< "$site"
    
    for domain in "${domain_array[@]}"; do
        # Validate domain name format
        domain_name=$(echo "$domain" | grep -P '(?=^.{5,254}$)(^(?:(?!\d+\.)[a-zA-Z0-9_\-]{1,63}\.?)+(?:[a-zA-Z]{2,})$)' || true)
        
        if [ -n "$domain_name" ]; then
            no_domains_found=false
            domain_found=true
            command="${command}--domains=\"${domain_name}\" "
        fi
    done
    
    if [ "$domain_found" = true ]; then 
        command="${command}--path=\"/etc/lego\""
        fullcommand="${fullcommand}${command}"$'\n'
    fi
done

if [ "$no_domains_found" = true ]; then 
    log_error "No valid domain names found in configuration"
    exit 1
fi

# FIX: the maintenance container's base OS/package manager has changed
# under this script before (Debian Buster going EOL, then an apparent
# move to a tdnf/Photon-based image), breaking the in-container
# wget/curl/xz-utils install each time it happens. Fetch and extract the
# lego binary on the HOST instead -- which we control, and which already
# has working curl + tar (proven by the site backup step above) -- then
# hand the binary to the container with `docker cp`. The container's
# package manager is no longer involved in this step at all.
log "Fetching lego release on host"
lego_tmp=$(mktemp -d)
lego_url=$(curl -s https://api.github.com/repositories/37038121/releases/latest \
    | grep browser_download_url \
    | grep linux_amd64 \
    | grep -v '\.sbom\.' \
    | cut -d '"' -f 4 \
    | head -n 1 || true)
# The `|| true` above stops a failed/empty pipeline from tripping
# `set -e pipefail` right here -- we want to reach the explicit check
# below and log a clear error instead of a bare pipeline failure.

if [ -z "$lego_url" ]; then
    log_error "Could not determine the latest lego download URL"
    rm -rf "$lego_tmp"
    exit 1
fi

curl -sL "$lego_url" -o "$lego_tmp/lego.tar.gz"
tar -xzf "$lego_tmp/lego.tar.gz" -C "$lego_tmp" lego

if [ ! -x "$lego_tmp/lego" ]; then
    log_error "lego binary not found after extracting release archive"
    rm -rf "$lego_tmp"
    exit 1
fi

docker cp "$lego_tmp/lego" "$maint_id":/tmp/lego
docker exec --user root "$maint_id" bash -lc "mv /tmp/lego /usr/local/bin/lego && chmod +x /usr/local/bin/lego"
rm -rf "$lego_tmp"

# Create and execute certificate renewal script
log "Creating certificate renewal script"
cat > ./public/updatecerts.sh <<EOF
#!/bin/bash
set -e

mkdir -p /etc/lego/certificates
rm -rf /etc/lego/certificates/*

# Run certificate renewals
$fullcommand

# Copy certificates to nginx
cp /etc/lego/certificates/* /opt/bitnami/nginx/conf/bitnami/certs
EOF

chmod +x ./public/updatecerts.sh

log "Executing certificate renewal script"
# FIX: dropped -t (TTY allocation). This script is designed to run
# unattended (config file, structured logging, non-interactive password
# handling), and `docker exec -t` fails with "the input device is not a
# TTY" when there's no controlling terminal, e.g. under cron.
docker exec -i --user root "$maint_id" bash -lc ./updatecerts.sh

# Backup and update certificates
log "Updating certificate locations"
mkdir -p "$MAILSERVER_CERT"
cd "$COMPOSE_HOME/certificates" || exit 1

# Backup existing certificates
mkdir -p bak
cp -f server.crt server.key ./bak/ 2>/dev/null || true
rm -f ./*.crt ./*.key
cp -f ./bak/* . 2>/dev/null || true

# Copy new certificates
cd "$MAINT_HOME" || exit 1
cp -f "$MAINT_HOME/certificates/"*.crt "$COMPOSE_HOME/certificates/"
cp -f "$MAINT_HOME/certificates/"*.key "$COMPOSE_HOME/certificates/"

# Copy to mail server with .pem extension
for cert_file in "$MAINT_HOME/certificates/"*.crt; do
    if [ -f "$cert_file" ]; then
        base_name=$(basename "$cert_file" .crt)
        cp -f "$cert_file" "$MAILSERVER_CERT/${base_name}.pem"
    fi
done

# Set correct permissions
chmod 0664 "$COMPOSE_HOME/certificates/"*
chown "$OWNER_ACCOUNT:root" "$COMPOSE_HOME/certificates/"*
chmod 0664 "$MAILSERVER_CERT/"*
chown "$OWNER_ACCOUNT:root" "$MAILSERVER_CERT/"*

# Restart services
log "Restarting Docker services"
docker-compose stop
cd "$COMPOSE_HOME"
docker-compose up -d

# Calculate and display runtime
end_time=$(date +%s)
runtime=$((end_time - start_time))
log "Maintenance completed successfully in $runtime seconds"

# Cleanup sensitive data from memory
unset DB_PASSWORD

exit 0
