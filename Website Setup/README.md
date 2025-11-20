# Web Server Maintenance Script - Documentation

## Overview

This maintenance script provides a secure, configurable solution for managing web server infrastructure including database backups, site backups, and SSL certificate renewal.

## Files

- `maintain-webserver.sh` - Main maintenance script
- `setup.cfg` - Configuration file with all parameters
- `setup-password.sh` - Helper script to securely store database password
- `README.md` - This documentation

## Installation

### 1. Set Up Password Storage (Recommended Method)

The most secure approach is to store the database password in a dedicated file:

```bash
# Run the password setup script
sudo ./setup-password.sh
```

This creates `/etc/webserver-maint/db.passwd` with secure permissions (400, root-only).

**Manual setup alternative:**

```bash
# Create directory
sudo mkdir -p /etc/webserver-maint
sudo chmod 700 /etc/webserver-maint

# Create password file
echo -n "your_db_password" | sudo tee /etc/webserver-maint/db.passwd > /dev/null

# Set secure permissions
sudo chmod 400 /etc/webserver-maint/db.passwd
sudo chown root:root /etc/webserver-maint/db.passwd
```

### 2. Configure the Script

Edit `setup.cfg` with your specific settings:

```bash
# Update paths
COMPOSE_HOME=/your/lemp-compose
MAINT_HOME=/your/maint-compose
MAILSERVER_CERT=/your/mailserver-cert/path

# Update account details
OWNER_ACCOUNT=youraccount
SUPPORT_EMAIL=your-email@example.com

# Update database settings
DB_USER=root
DB_CONTAINER=your_mariadb_container_name

# Update domain list
SITES=(
    'www.yourdomain.com;yourdomain.com'
    'www.anotherdomain.com;anotherdomain.com'
)
```

### 3. Make Scripts Executable

```bash
chmod +x maintain-webserver.sh
chmod +x setup-password.sh
```

## Usage

### Basic Usage

```bash
sudo ./maintain-webserver.sh
```

### Custom Configuration File

```bash
sudo ./maintain-webserver.sh --config /path/to/custom/setup.cfg
```

### What the Script Does

1. **Database Backup**: Creates a full mysqldump of all databases
2. **Site Backup**: Creates a compressed tarball excluding large files (>100MB by default)
3. **Certificate Renewal**: Uses Let's Encrypt (via lego) to renew SSL certificates
4. **Certificate Distribution**: Copies certificates to web server and mail server locations
5. **Service Restart**: Restarts Docker containers to apply new certificates

## Password Retrieval Methods

The script supports three methods for retrieving the database password (in order of preference):

### Method 1: Password File (Recommended)

Store password in `/etc/webserver-maint/db.passwd`:

**Pros:**
- Most secure for system-level scripts
- No environment variable exposure
- Simple to implement
- Works with cron jobs

**Setup:**

```bash
sudo ./setup-password.sh
```

### Method 2: Environment Variable

Export password before running:

**Pros:**
- Flexible for different environments
- Good for containerised deployments

**Cons:**
- Visible in process list
- Must be set before each run

**Setup:**

```bash
export DB_PASSWORD='your_password'
sudo -E ./maintain-webserver.sh
```

**For systemd service:**

```ini
[Service]
EnvironmentFile=/etc/webserver-maint/environment
```

### Method 3: External Secrets Manager

For production environments, consider:

- **HashiCorp Vault**: Enterprise-grade secrets management
- **AWS Secrets Manager**: Cloud-native solution for AWS
- **Docker Secrets**: Built-in for Docker Swarm
- **Kubernetes Secrets**: For Kubernetes deployments

## Automation with Cron

To run the script automatically:

```bash
# Edit root's crontab
sudo crontab -e

# Run weekly on Sunday at 2 AM
0 2 * * 0 /path/to/maintain-webserver.sh >> /var/log/webserver-maint.log 2>&1

# Run monthly on the 1st at 3 AM
0 3 1 * * /path/to/maintain-webserver.sh >> /var/log/webserver-maint.log 2>&1
```

## Troubleshooting

### Password File Not Found

**Error:** `ERROR: Database password not found`

**Solution:** 

1. Run `setup-password.sh` to create the password file
2. Or set the `DB_PASSWORD` environment variable
3. Verify file exists: `sudo ls -la /etc/webserver-maint/db.passwd`

### Insecure Password File Permissions

**Warning:** `Password file has insecure permissions`

**Solution:**

```bash
sudo chmod 400 /etc/webserver-maint/db.passwd
sudo chown root:root /etc/webserver-maint/db.passwd
```

### Configuration Variable Missing

**Error:** `Required configuration variable 'X' is not set`

**Solution:** 

1. Check `setup.cfg` exists and is readable
2. Ensure the variable is defined (not commented out)
3. Verify no typos in variable names

### Docker Container Not Found

**Error:** `No maintenance container found running`

**Solution:**

1. Check Docker is running: `docker ps`
2. Verify `MAINT_HOME` path in `setup.cfg`
3. Ensure `docker-compose up -d` completed successfully

## Security Best Practices

1. **File Permissions**: Always verify password file is 400 or 600
2. **Backup Security**: Store backup files in secure locations
3. **Log Management**: Regularly review and rotate log files
4. **Access Control**: Limit who can read the configuration file
5. **Password Rotation**: Periodically change database passwords
6. **Audit Trail**: Monitor script execution and failures

## Support and Maintenance

- Review logs regularly: `/var/log/webserver-maint.log` (if using cron redirection)
- Test certificate renewal before expiry
- Keep Docker and lego tool updated
- Document any customisations you make

## Changelog

### Version 2.0 (Refactored)
- Moved configuration to external file
- Implemented secure password storage
- Added proper error handling
- Improved logging with timestamps
- Added configuration validation
- Better backup file naming
- Command-line argument support
- Comprehensive documentation

### Version 1.0 (Original)
- Initial version with embedded configuration
- Clear-text password in script
