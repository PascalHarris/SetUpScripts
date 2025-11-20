#!/bin/bash
#
# Setup Script for Web Server Maintenance Password Storage
# This script helps you securely store the database password
#

set -euo pipefail

PASSWORD_DIR="/etc/webserver-maint"
PASSWORD_FILE="$PASSWORD_DIR/db.passwd"

echo "Web Server Maintenance - Password Setup"
echo "========================================"
echo

# Check if running as root
if [[ $(/usr/bin/id -u) -ne 0 ]]; then
    echo "ERROR: This script must be run as root"
    echo "Please use: sudo $0"
    exit 1
fi

# Create directory if it doesn't exist
if [ ! -d "$PASSWORD_DIR" ]; then
    echo "Creating password directory: $PASSWORD_DIR"
    mkdir -p "$PASSWORD_DIR"
    chmod 700 "$PASSWORD_DIR"
else
    echo "Password directory already exists: $PASSWORD_DIR"
fi

# Check if password file already exists
if [ -f "$PASSWORD_FILE" ]; then
    echo
    echo "WARNING: Password file already exists: $PASSWORD_FILE"
    read -p "Do you want to overwrite it? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Aborting."
        exit 0
    fi
fi

# Prompt for password
echo
echo "Please enter the MariaDB root password:"
read -s password
echo
echo "Please confirm the password:"
read -s password_confirm
echo

if [ "$password" != "$password_confirm" ]; then
    echo "ERROR: Passwords do not match"
    exit 1
fi

if [ -z "$password" ]; then
    echo "ERROR: Password cannot be empty"
    exit 1
fi

# Write password to file
echo -n "$password" > "$PASSWORD_FILE"

# Set secure permissions (owner read-only)
chmod 400 "$PASSWORD_FILE"
chown root:root "$PASSWORD_FILE"

# Verify
if [ -f "$PASSWORD_FILE" ]; then
    perms=$(stat -c %a "$PASSWORD_FILE")
    echo "Password file created successfully: $PASSWORD_FILE"
    echo "Permissions: $perms (owner read-only)"
    echo
    echo "The maintenance script will now be able to retrieve the password securely."
else
    echo "ERROR: Failed to create password file"
    exit 1
fi

# Clear sensitive variables
unset password password_confirm

echo
echo "Setup complete!"
echo
echo "Next steps:"
echo "1. Test the maintenance script: sudo /path/to/maintain-webserver.sh"
echo "2. Consider adding the script to cron for automated execution"
echo "3. Keep backups of the password file in a secure location"
