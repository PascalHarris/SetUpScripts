## Quick Start Guide - Web Server Maintenance Script

### Quick Setup (3 Steps)

#### 1. Store Password Securely
```bash
sudo ./setup-password.sh
# Enter your database password when prompted
```

#### 2. Update Configuration
Edit `setup.cfg` with your settings:
- Update paths (COMPOSE_HOME, MAINT_HOME, etc.)
- Update email and account details
- Update your domain list in SITES array
- Update DB_CONTAINER name to match your container

#### 3. Run the Script
```bash
sudo ./maintain-webserver.sh
```

### Password Storage Options

**RECOMMENDED: Use password file**

```bash
# Automatic setup
sudo ./setup-password.sh

# Manual setup
echo -n "your_password" | sudo tee /etc/webserver-maint/db.passwd > /dev/null
sudo chmod 400 /etc/webserver-maint/db.passwd
```

**ALTERNATIVE: Use environment variable**

```bash
export DB_PASSWORD='your_password'
sudo -E ./maintain-webserver.sh
```

### Key Files

| File | Purpose | Required? |
|------|---------|-----------|
| `maintain-webserver.sh` | Main script | Yes |
| `setup.cfg` | Configuration | Yes |
| `/etc/webserver-maint/db.passwd` | Secure password storage | Yes (recommended) |
| `setup-password.sh` | Password setup helper | No (convenience) |
| `README.md` | Full documentation | No (reference) |

### Common Issues & Quick Fixes

**"Configuration file not found"**
→ Make sure `setup.cfg` is in the same directory, or use `--config /path/to/setup.cfg`

**"Database password not found"**
→ Run `sudo ./setup-password.sh` to set up secure password storage

**"Required configuration variable 'X' is not set"**
→ Check that variable exists in `setup.cfg` and isn't commented out

**"Insecure permissions" warning**
→ Run `sudo chmod 400 /etc/webserver-maint/db.passwd`

### Configuration Quick Reference

```bash
# Essential Settings (must customise)
COMPOSE_HOME=/your/lemp-compose          # Your Docker Compose directory
MAINT_HOME=/your/maint-compose           # Maintenance container directory
OWNER_ACCOUNT=youruser                   # File ownership account
SUPPORT_EMAIL=you@example.com            # Let's Encrypt notifications
DB_CONTAINER=your_mariadb_container      # Your database container name

# Domain Configuration
SITES=(
    'www.domain1.com;domain1.com'
    'www.domain2.com;domain2.com;domain2.co.uk'
)
```

### Verify Setup

After configuration, verify everything works:

```bash
# 1. Check password file exists and has correct permissions
sudo ls -la /etc/webserver-maint/db.passwd
# Should show: -r-------- 1 root root (400 permissions)

# 2. Validate configuration
sudo ./maintain-webserver.sh --config setup.cfg
# Should start without configuration errors

# 3. Check logs
# Watch for any errors during execution
```

### Cron Setup Example

```bash
# Edit root crontab
sudo crontab -e

# Add line (weekly maintenance on Sunday at 2 AM):
0 2 * * 0 /path/to/maintain-webserver.sh >> /var/log/webserver-maint.log 2>&1
```

### Getting Help

1. Read `README.md` for comprehensive documentation
2. Check logs for error messages
3. Verify all file paths in `setup.cfg` exist
4. Ensure Docker containers are running
5. Test password retrieval: `sudo cat /etc/webserver-maint/db.passwd`
