#!/bin/bash
#
# Web Server Maintenance Script
# Handles database backup, site backup, and SSL certificate renewal
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
docker exec -i -t --user root "$DB_CONTAINER" bash -lc /bitnami/backupdb.sh

# Backup Site
log "Backing up site files"
backup_date=$(date +"%Y%m%d_%H%M%S")
backup_file="site_backup_${backup_date}.tar.gz"
tar cpzf "$backup_file" . \
    --exclude="$backup_file" \
    --exclude-from <(find . -size +"${BACKUP_MAX_FILE_SIZE:-100M}")
chown "$OWNER_ACCOUNT:$OWNER_ACCOUNT" "$backup_file"
log "Backup created: $backup_file"

# Renew Certificates
log "Renewing SSL certificates"
cd "$COMPOSE_HOME"
docker-compose stop

cd "$MAINT_HOME"
docker-compose up -d
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
    command="lego --http --email=\"$SUPPORT_EMAIL\" "
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
        command="${command}--path=\"/etc/lego\" run"
        fullcommand="${fullcommand}${command}"$'\n'
    fi
done

if [ "$no_domains_found" = true ]; then 
    log_error "No valid domain names found in configuration"
    exit 1
fi

# Create and execute certificate renewal script
log "Creating certificate renewal script"
cat > ./public/updatecerts.sh <<EOF
#!/bin/bash
set -e

mkdir -p /etc/lego/certificates
rm -f /etc/lego/certificates/*
cd /tmp
rm -f *

# Install required packages
install_packages wget xz-utils

# Download and install lego
curl -s https://api.github.com/repositories/37038121/releases/latest \\
    | grep browser_download_url \\
    | grep linux_amd64 \\
    | cut -d '"' -f 4 \\
    | wget -i -

mv *.tar.gz lego.tar.gz
tar -xf lego.tar.gz
mv lego /usr/local/bin/lego
rm -f *

# Run certificate renewals
$fullcommand

# Copy certificates to nginx
cp /etc/lego/certificates/* /opt/bitnami/nginx/conf/bitnami/certs
EOF

chmod +x ./public/updatecerts.sh

log "Executing certificate renewal script"
docker exec -i -t --user root "$maint_id" bash -lc ./updatecerts.sh

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
