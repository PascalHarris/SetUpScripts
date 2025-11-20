#!/bin/bash
# setup-fileserver.sh — Configure Raspberry Pi as AppleTalk file server
# For Apple IIgs and vintage Macintosh (System 6, 7, 8, 9)
# Requires Netatalk 2.x for compatibility

set -e

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No colour

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root.${NC}"
    echo "Please re-run it using: sudo ./setup-fileserver.sh"
    exit 1
fi

echo "========================================="
echo "AppleTalk File Server Setup"
echo "========================================="
echo ""

# Function to check if package is installed
is_installed() {
    dpkg -s "$1" &>/dev/null
}

# Function to get netatalk version
get_netatalk_version() {
    if command -v afpd >/dev/null 2>&1; then
        afpd -V 2>&1 | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' | head -1
    else
        echo ""
    fi
}

# Function to get major version number
get_major_version() {
    echo "$1" | cut -d. -f1
}

# Install basic dependencies
echo "Installing basic dependencies..."
BASIC_DEPS=(avahi-daemon build-essential libssl-dev libpam0g-dev libdb-dev)

for pkg in "${BASIC_DEPS[@]}"; do
    if is_installed "$pkg"; then
        echo "  ✓ $pkg already installed"
    else
        echo "  Installing $pkg..."
        apt-get update -qq
        apt-get install -y "$pkg" >/dev/null 2>&1
    fi
done

# Check for netatalk installation and version
echo ""
echo "Checking Netatalk installation..."
NETATALK_VERSION=$(get_netatalk_version)

if [ -n "$NETATALK_VERSION" ]; then
    MAJOR_VERSION=$(get_major_version "$NETATALK_VERSION")
    echo -e "  ${GREEN}✓ Netatalk $NETATALK_VERSION is installed${NC}"
    
    if [ "$MAJOR_VERSION" = "2" ]; then
        echo -e "  ${GREEN}✓ Version 2.x detected - fully compatible with vintage Macs${NC}"
        INSTALL_NETATALK=false
    else
        echo -e "  ${YELLOW}⚠ Version $MAJOR_VERSION.x detected${NC}"
        echo "  Netatalk 2.x is required for Apple IIgs and System 6/7 compatibility"
        read -p "  Remove and install Netatalk 2.2.4? (y/n): " REINSTALL
        if [[ "$REINSTALL" =~ ^[Yy]$ ]]; then
            echo "  Removing Netatalk $NETATALK_VERSION..."
            apt-get remove -y netatalk >/dev/null 2>&1 || true
            apt-get autoremove -y >/dev/null 2>&1 || true
            INSTALL_NETATALK=true
        else
            echo -e "  ${YELLOW}Continuing with Netatalk $NETATALK_VERSION${NC}"
            echo "  Note: Compatibility with older systems may be limited"
            INSTALL_NETATALK=false
        fi
    fi
else
    echo "  Netatalk not found"
    INSTALL_NETATALK=true
fi

# Install Netatalk 2.2.4 if needed
if [ "$INSTALL_NETATALK" = true ]; then
    echo ""
    echo "Installing Netatalk 2.2.4 from source..."
    echo "This provides optimal compatibility with:"
    echo "  - Apple IIgs GS/OS"
    echo "  - Macintosh System 6.0.x"
    echo "  - Macintosh System 7.x"
    echo "  - Mac OS 8.x and 9.x"
    echo ""
    
    # Create temporary build directory
    BUILD_DIR=$(mktemp -d)
    cd "$BUILD_DIR"
    
    echo "Downloading Netatalk 2.2.4..."
    wget -q https://sourceforge.net/projects/netatalk/files/netatalk/2.2.4/netatalk-2.2.4.tar.gz
    
    if [ ! -f netatalk-2.2.4.tar.gz ]; then
        echo -e "${RED}Failed to download Netatalk 2.2.4${NC}"
        echo "Please check your internet connection"
        exit 1
    fi
    
    echo "Extracting..."
    tar -xzf netatalk-2.2.4.tar.gz
    cd netatalk-2.2.4
    
    echo "Configuring build (this may take a minute)..."
    ./configure --enable-ddp --enable-cups --with-ssl-dir=/usr >/dev/null 2>&1
    
    echo "Compiling (this will take several minutes)..."
    make >/dev/null 2>&1
    
    echo "Installing..."
    make install >/dev/null 2>&1
    
    # Clean up
    cd /
    rm -rf "$BUILD_DIR"
    
    # Verify installation
    NETATALK_VERSION=$(get_netatalk_version)
    if [ -n "$NETATALK_VERSION" ]; then
        echo -e "${GREEN}✓ Netatalk $NETATALK_VERSION installed successfully${NC}"
    else
        echo -e "${RED}Installation may have failed${NC}"
        exit 1
    fi
fi

# Determine configuration directory
echo ""
echo "Configuring Netatalk..."

# Netatalk 2.x typically installs to /usr/local
if [ -d "/usr/local/etc/netatalk" ]; then
    CONFIG_DIR="/usr/local/etc/netatalk"
elif [ -d "/etc/netatalk" ]; then
    CONFIG_DIR="/etc/netatalk"
    # Create symlink for consistency
    if [ ! -e "/usr/local/etc/netatalk" ]; then
        mkdir -p /usr/local/etc
        ln -sf /etc/netatalk /usr/local/etc/netatalk
        echo "  Created symlink: /usr/local/etc/netatalk -> /etc/netatalk"
    fi
else
    # Create the directory structure
    mkdir -p /usr/local/etc/netatalk
    CONFIG_DIR="/usr/local/etc/netatalk"
fi

echo "  Configuration directory: $CONFIG_DIR"

# Backup existing configuration
echo "  Creating backups of existing configuration..."
BACKUP_SUFFIX=".bak.$(date +%Y%m%d_%H%M%S)"

for conf_file in afpd.conf AppleVolumes.default atalkd.conf; do
    if [ -f "$CONFIG_DIR/$conf_file" ]; then
        cp "$CONFIG_DIR/$conf_file" "$CONFIG_DIR/$conf_file$BACKUP_SUFFIX"
        echo "    Backed up: $conf_file"
    fi
done

# Configure AppleTalk networking (atalkd.conf)
echo ""
echo "Configuring AppleTalk networking..."

# Check for AppleTalk kernel support
echo "  Checking AppleTalk kernel support..."
if lsmod | grep -q appletalk; then
    echo -e "    ${GREEN}✓ AppleTalk kernel module is loaded${NC}"
elif modprobe appletalk 2>/dev/null; then
    echo -e "    ${GREEN}✓ AppleTalk kernel module loaded${NC}"
else
    echo -e "    ${YELLOW}⚠ AppleTalk kernel module not available${NC}"
    echo "    This may limit AppleTalk functionality"
    echo "    Continuing anyway - some systems work without it"
fi

# Detect available network interfaces
echo "  Detecting network interface..."
# Try to get the default route interface
NETWORK_IFACE=$(ip route | grep default | awk '{print $5}' | head -1)

if [ -z "$NETWORK_IFACE" ]; then
    # Fallback: get first active non-loopback interface
    AVAILABLE_IFACES=($(ip -br link show | grep -v "lo\|DOWN" | awk '{print $1}'))
    
    if [ ${#AVAILABLE_IFACES[@]} -eq 0 ]; then
        echo -e "    ${RED}✗ No active network interfaces found${NC}"
        echo "    Please ensure your network is connected"
        NETWORK_IFACE="eth0"
        echo "    Using default: $NETWORK_IFACE (may not work)"
    else
        # Prefer eth0, then wlan0, then first available
        if [[ " ${AVAILABLE_IFACES[@]} " =~ " eth0 " ]]; then
            NETWORK_IFACE="eth0"
        elif [[ " ${AVAILABLE_IFACES[@]} " =~ " wlan0 " ]]; then
            NETWORK_IFACE="wlan0"
        else
            NETWORK_IFACE="${AVAILABLE_IFACES[0]}"
        fi
        echo -e "    ${GREEN}✓ Using interface: $NETWORK_IFACE${NC}"
    fi
else
    echo -e "    ${GREEN}✓ Using default route interface: $NETWORK_IFACE${NC}"
fi

# Create atalkd.conf with auto-discovery (like applefool.com working config)
# Key change: NO explicit network range - let atalkd auto-discover
cat > "$CONFIG_DIR/atalkd.conf" << EOF
# atalkd.conf - AppleTalk network configuration
# Phase 2 EtherTalk for vintage Mac and Apple IIgs
# Uses auto-discovery for network range (recommended)

# Primary network interface: $NETWORK_IFACE
# -phase 2: Use AppleTalk Phase 2 (required for modern EtherTalk)
# -addr: Node address only (network auto-discovered)
# Note: No explicit -net range allows atalkd to discover the network automatically
$NETWORK_IFACE -phase 2 -addr 65280.142
EOF

echo -e "  ${GREEN}✓ Created atalkd.conf with auto-discovery for $NETWORK_IFACE${NC}"
echo "    (Network range will be auto-discovered by atalkd)"

# Configure AFP daemon (afpd.conf)
echo "Configuring AFP daemon..."
cat > "$CONFIG_DIR/afpd.conf" << 'EOF'
# afpd.conf - Apple Filing Protocol daemon configuration
# Compatible with Apple IIgs and vintage Macintosh

# Default AFP service
# -transall: support all AFP transports (TCP and AppleTalk)
# -uamlist: authentication methods (guest and cleartext password)
# -nosavepassword: don't save passwords
# -loginmaxfail 5: lock account after 5 failed attempts

- -transall -uamlist uams_guest.so,uams_clrtxt.so,uams_dhx.so -nosavepassword -loginmaxfail 5

# For guest-only access (no password required), use:
# - -transall -uamlist uams_guest.so -nosavepassword
EOF
echo -e "  ${GREEN}✓ Created afpd.conf${NC}"

# Configure volumes (AppleVolumes.default)
echo ""
echo "========================================="
echo "Share Configuration"
echo "========================================="
echo ""

# Ask about authentication
echo "User Authentication"
echo "-------------------"
echo "AFP can use your Raspberry Pi user accounts for authentication."
echo "Passwords are taken from the system (passwd)."
echo ""
read -p "Enter a username for AFP authentication (or press Enter for guest-only access): " AFP_USERNAME

if [ -n "$AFP_USERNAME" ]; then
    # Check if user exists
    if id "$AFP_USERNAME" &>/dev/null; then
        echo -e "  ${GREEN}✓ User '$AFP_USERNAME' found${NC}"
        USE_AUTH=true
    else
        echo -e "  ${YELLOW}⚠ User '$AFP_USERNAME' does not exist${NC}"
        read -p "  Create this user? (Y/n): " CREATE_USER
        if [[ ! "$CREATE_USER" =~ ^[Nn]$ ]]; then
            adduser --gecos "" "$AFP_USERNAME"
            echo -e "  ${GREEN}✓ User '$AFP_USERNAME' created${NC}"
            echo "  This user can now log in to AFP with their password"
            USE_AUTH=true
        else
            echo "  Continuing with guest-only access"
            USE_AUTH=false
        fi
    fi
else
    echo "  No username provided - guest-only access will be configured"
    USE_AUTH=false
fi

# Configure AFP daemon based on authentication choice
echo ""
echo "Configuring AFP daemon..."
if [ "$USE_AUTH" = true ]; then
    cat > "$CONFIG_DIR/afpd.conf" << 'EOF'
# afpd.conf - Apple Filing Protocol daemon configuration
# User authentication enabled with AppleTalk support

# AFP service with user authentication and AppleTalk DDP
# -transall: support all AFP transports (TCP and AppleTalk)
# -ddp: enable AppleTalk DDP protocol (required for vintage Macs)
# -uamlist: authentication methods (guest, cleartext, and DHX)
# -nosavepassword: don't save passwords
# -loginmaxfail 5: lock account after 5 failed attempts

- -transall -ddp -uamlist uams_guest.so,uams_clrtxt.so,uams_dhx.so -nosavepassword -loginmaxfail 5
EOF
    echo -e "  ${GREEN}✓ AFP configured with user authentication and AppleTalk DDP${NC}"
else
    cat > "$CONFIG_DIR/afpd.conf" << 'EOF'
# afpd.conf - Apple Filing Protocol daemon configuration
# Guest-only access with AppleTalk support

# AFP service with guest access and AppleTalk DDP
# -transall: support all AFP transports (TCP and AppleTalk)
# -ddp: enable AppleTalk DDP protocol (required for vintage Macs)
# -uamlist: authentication methods (guest only)

- -transall -ddp -uamlist uams_guest.so -nosavepassword
EOF
    echo -e "  ${GREEN}✓ AFP configured for guest-only access with AppleTalk DDP${NC}"
fi

# Start building AppleVolumes.default
cat > "$CONFIG_DIR/AppleVolumes.default" << 'EOF'
# AppleVolumes.default - Shared volumes configuration
# Format: path [volume_name] [options]

EOF

if [ "$USE_AUTH" = true ]; then
    cat >> "$CONFIG_DIR/AppleVolumes.default" << 'EOF'
# User home directory (requires authentication)
~/ "Home"

EOF
fi

# Now ask for shared folders
echo ""
echo "Shared Folders"
echo "--------------"
echo "Enter paths to share (press Enter with empty path to finish)"
echo ""

SHARE_COUNT=0
while true; do
    read -p "Share path (or Enter to finish): " SHARE_PATH
    
    # Break if empty
    if [ -z "$SHARE_PATH" ]; then
        if [ $SHARE_COUNT -eq 0 ]; then
            echo -e "  ${YELLOW}⚠ No shares configured${NC}"
            read -p "  Create a default 'Shared' folder at /home/pi/Shared? (Y/n): " CREATE_DEFAULT
            if [[ ! "$CREATE_DEFAULT" =~ ^[Nn]$ ]]; then
                SHARE_PATH="/home/pi/Shared"
            else
                echo "  No shares will be configured"
                break
            fi
        else
            break
        fi
    fi
    
    # Expand tilde
    SHARE_PATH="${SHARE_PATH/#\~/$HOME}"
    
    # Check if path exists
    if [ ! -d "$SHARE_PATH" ]; then
        echo -e "  ${YELLOW}⚠ Directory does not exist: $SHARE_PATH${NC}"
        read -p "  Create it? (Y/n): " CREATE_DIR
        if [[ ! "$CREATE_DIR" =~ ^[Nn]$ ]]; then
            mkdir -p "$SHARE_PATH"
            chmod 755 "$SHARE_PATH"
            echo -e "  ${GREEN}✓ Created: $SHARE_PATH${NC}"
        else
            echo "  Skipping this share"
            continue
        fi
    fi
    
    # Get volume name
    DEFAULT_NAME=$(basename "$SHARE_PATH")
    read -p "  Volume name (default: $DEFAULT_NAME): " VOLUME_NAME
    if [ -z "$VOLUME_NAME" ]; then
        VOLUME_NAME="$DEFAULT_NAME"
    fi
    
    # Ask about permissions
    echo "  Access permissions:"
    echo "    1) Read/Write for all users"
    echo "    2) Read/Write for owner, Read-only for others"
    echo "    3) Read-only for all users"
    read -p "  Select (1-3, default: 1): " PERM_CHOICE
    
    case $PERM_CHOICE in
        2)
            OPTIONS="options:upriv,usedots"
            ;;
        3)
            OPTIONS="options:upriv,usedots,ro"
            ;;
        *)
            OPTIONS="options:upriv,usedots"
            chmod 777 "$SHARE_PATH"
            ;;
    esac
    
    # Add to AppleVolumes.default
    echo "$SHARE_PATH \"$VOLUME_NAME\" $OPTIONS" >> "$CONFIG_DIR/AppleVolumes.default"
    echo -e "  ${GREEN}✓ Added share: $VOLUME_NAME${NC}"
    SHARE_COUNT=$((SHARE_COUNT + 1))
    echo ""
done

# Add help text to AppleVolumes.default
cat >> "$CONFIG_DIR/AppleVolumes.default" << 'EOF'

# Options explanation:
# upriv - use Unix privileges
# usedots - use dots in filenames (visible to Unix)
# ro - read only
# 
# To add more shares manually:
# /path/to/folder "Volume Name" options:upriv,usedots
# 
# Then restart: sudo systemctl restart netatalk
EOF

echo -e "  ${GREEN}✓ Created AppleVolumes.default with $SHARE_COUNT share(s)${NC}"

# Determine netatalk binary locations
echo ""
echo "Locating netatalk binaries..."

# Check which binaries actually exist
CNID_METAD="/usr/local/sbin/cnid_metad"
ATALKD="/usr/local/sbin/atalkd"
AFPD="/usr/local/sbin/afpd"

# Verify binaries exist
if [ ! -x "$AFPD" ]; then
    # Try alternate location
    if [ -x "/usr/sbin/afpd" ]; then
        CNID_METAD="/usr/sbin/cnid_metad"
        ATALKD="/usr/sbin/atalkd"
        AFPD="/usr/sbin/afpd"
    else
        echo -e "${RED}Error: Cannot find afpd binary${NC}"
        echo "Expected at: $AFPD or /usr/sbin/afpd"
        exit 1
    fi
fi

echo "  Using binaries:"
echo "    afpd: $AFPD"
echo "    atalkd: $ATALKD"
echo "    cnid_metad: $CNID_METAD"

# Create startup and stop scripts for proper service management
echo ""
echo "Creating netatalk startup scripts..."

cat > /usr/local/bin/start-netatalk.sh << EOF
#!/bin/bash
# Start netatalk services in proper order with adequate delays

# Paths
ATALKD=$ATALKD
CNID_METAD=$CNID_METAD
AFPD=$AFPD
CONFIG_DIR=$CONFIG_DIR

# Start CNID metadata daemon
$CNID_METAD

# Start AppleTalk daemon
$ATALKD -f \$CONFIG_DIR/atalkd.conf

# Critical: Wait for atalkd to fully initialize and auto-discover network
# This delay is essential - atalkd needs time to configure the network
# and register with the AppleTalk network before afpd starts
sleep 5

# Verify atalkd actually started
if ! pgrep -x atalkd > /dev/null; then
    echo "ERROR: atalkd failed to start" >&2
    exit 1
fi

# Start AFP daemon - will register with AppleTalk NBP
$AFPD -F \$CONFIG_DIR/afpd.conf

# Wait for afpd to register with NBP
sleep 3

# Verify afpd started
if ! pgrep -x afpd > /dev/null; then
    echo "ERROR: afpd failed to start" >&2
    exit 1
fi

exit 0
EOF

chmod +x /usr/local/bin/start-netatalk.sh
echo -e "  ${GREEN}✓ Created /usr/local/bin/start-netatalk.sh${NC}"

cat > /usr/local/bin/stop-netatalk.sh << 'EOF'
#!/bin/bash
# Stop netatalk services gracefully

killall afpd 2>/dev/null
sleep 1
killall atalkd 2>/dev/null
killall cnid_metad 2>/dev/null
exit 0
EOF

chmod +x /usr/local/bin/stop-netatalk.sh
echo -e "  ${GREEN}✓ Created /usr/local/bin/stop-netatalk.sh${NC}"

# Create systemd service that uses these scripts
echo "Creating systemd service..."
cat > /etc/systemd/system/netatalk.service << 'EOF'
[Unit]
Description=Netatalk AFP file server
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
ExecStart=/usr/local/bin/start-netatalk.sh
ExecStop=/usr/local/bin/stop-netatalk.sh
RemainAfterExit=yes
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
echo -e "  ${GREEN}✓ Created netatalk.service${NC}"

# Configure and start Avahi for network discovery
echo ""
echo "Configuring Avahi for network discovery..."
if ! is_installed avahi-daemon; then
    apt-get install -y avahi-daemon >/dev/null 2>&1
fi

systemctl enable avahi-daemon >/dev/null 2>&1
if ! systemctl is-active avahi-daemon >/dev/null 2>&1; then
    systemctl start avahi-daemon
fi
echo -e "  ${GREEN}✓ Avahi daemon configured${NC}"

# Enable and start netatalk
echo ""
echo "Enabling and starting Netatalk services..."
systemctl enable netatalk >/dev/null 2>&1

# Stop if running
if systemctl is-active netatalk >/dev/null 2>&1; then
    echo "  Stopping existing netatalk service..."
    /usr/local/bin/stop-netatalk.sh
    sleep 2
fi

# Start netatalk using the startup script
echo "  Starting netatalk..."
/usr/local/bin/start-netatalk.sh

# Brief wait for initialization
sleep 2

# Verify services are running
echo ""
echo "Verifying services..."

# Check systemd service status
if systemctl is-active netatalk >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ Netatalk service is running${NC}"
    SERVICE_OK=true
else
    echo -e "  ${YELLOW}⚠ Netatalk service had issues starting${NC}"
    SERVICE_OK=false
fi

# Check each daemon
echo ""
echo "Checking individual daemons..."

if pgrep -x cnid_metad >/dev/null; then
    echo -e "  ${GREEN}✓ cnid_metad (metadata) is running${NC}"
    CNID_OK=true
else
    echo -e "  ${YELLOW}⚠ cnid_metad is not running${NC}"
    CNID_OK=false
fi

if pgrep -x atalkd >/dev/null; then
    echo -e "  ${GREEN}✓ atalkd (AppleTalk) is running${NC}"
    ATALKD_OK=true
else
    echo -e "  ${YELLOW}⚠ atalkd (AppleTalk) is not running${NC}"
    echo -e "    ${BLUE}Note: AppleTalk is optional - AFP works over TCP/IP${NC}"
    ATALKD_OK=false
fi

if pgrep -x afpd >/dev/null; then
    echo -e "  ${GREEN}✓ afpd (file server) is running${NC}"
    AFPD_OK=true
else
    echo -e "  ${RED}✗ afpd (file server) is not running${NC}"
    AFPD_OK=false
fi

# If AFP is running, we're good even without AppleTalk
if [ "$AFPD_OK" = true ]; then
    echo ""
    echo -e "${GREEN}✓ AFP file server is operational${NC}"
    
    if [ "$ATALKD_OK" = false ]; then
        echo ""
        echo -e "${YELLOW}AppleTalk daemon (atalkd) is not running.${NC}"
        echo "This is often not a problem because:"
        echo "  • AFP works perfectly over TCP/IP without AppleTalk"
        echo "  • Modern Macs and many vintage Macs can connect via TCP/IP"
        echo "  • System 7.5+ can use TCP/IP for file sharing"
        echo ""
        echo "Your file server should be accessible via:"
        echo "  • Chooser → AppleShare (will connect via TCP/IP)"
        echo "  • IP address: $(hostname -I | awk '{print $1}')"
        echo ""
        echo "If you specifically need AppleTalk/DDP networking:"
        echo "  1. Check network interface: ip addr"
        echo "  2. Verify atalkd config: cat $CONFIG_DIR/atalkd.conf"
        echo "  3. Try starting manually: sudo $ATALKD -f $CONFIG_DIR/atalkd.conf -d"
        echo "  4. Check for errors in output"
    fi
else
    # AFP failed - this is a real problem
    echo ""
    echo -e "${RED}✗ AFP daemon failed to start - file server is not operational${NC}"
    echo ""
    echo "Troubleshooting steps:"
    echo ""
    echo "1. Try starting AFP manually to see errors:"
    echo "   sudo $AFPD -F $CONFIG_DIR/afpd.conf -d"
    echo ""
    echo "2. Check configuration:"
    echo "   cat $CONFIG_DIR/afpd.conf"
    echo "   cat $CONFIG_DIR/AppleVolumes.default"
    echo ""
    echo "3. Check systemd logs:"
    echo "   sudo journalctl -u netatalk -n 50 --no-pager"
    echo ""
    echo "4. Verify netatalk is properly installed:"
    echo "   $AFPD -V"
    echo ""
    exit 1
fi

if systemctl is-active avahi-daemon >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓ Avahi is running${NC}"
else
    echo -e "  ${YELLOW}⚠ Avahi not running (optional)${NC}"
fi

# Display network information
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}AppleTalk File Server Setup Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Network Information:"
echo "  Hostname: $(hostname)"
echo "  IP Address: $(hostname -I | awk '{print $1}')"
echo ""
echo "Configuration Files:"
echo "  AppleTalk: $CONFIG_DIR/atalkd.conf"
echo "  AFP Daemon: $CONFIG_DIR/afpd.conf"
echo "  Volumes: $CONFIG_DIR/AppleVolumes.default"
echo ""

if [ "$USE_AUTH" = true ]; then
    echo "Authentication:"
    echo "  Username: $AFP_USERNAME"
    echo "  Password: (uses system password from passwd)"
    echo "  Guest access: Also available"
    echo ""
fi

echo "Connecting from Vintage Macs:"
echo ""
echo "System 6/7/8/9:"
echo "  1. Open 'Chooser' from Apple menu"
echo "  2. Click 'AppleShare' icon"
echo "  3. Make sure AppleTalk is 'Active'"
echo "  4. Look for '$(hostname)' in the file server list"
echo "  5. Select it and click 'OK'"

if [ "$USE_AUTH" = true ]; then
    echo "  6. Choose 'Registered User' and log in as '$AFP_USERNAME'"
    echo "     OR choose 'Guest' for guest access"
else
    echo "  6. Choose 'Guest' (no password required)"
fi

echo ""
echo "Apple IIgs (GS/OS):"
echo "  1. Open 'Control Panel' and ensure AppleTalk is active"
echo "  2. Run 'AppleShare' from utilities"
echo "  3. Select '$(hostname)' from the list"
echo "  4. Mount volumes as needed"
echo ""
echo "If the server doesn't appear:"
echo "  1. Check AppleTalk is 'Active' in Chooser"
echo "  2. Wait 30 seconds for network discovery"
echo "  3. Check server status: sudo systemctl status netatalk"
echo "  4. View logs: sudo journalctl -u netatalk -f"
echo ""
echo "To add more shared folders:"
echo "  1. Edit: sudo nano $CONFIG_DIR/AppleVolumes.default"
echo "  2. Add line: /path/to/folder \"Volume Name\" options:upriv,usedots"
echo "  3. Restart: sudo systemctl restart netatalk"
echo ""
echo "To change authentication:"
echo "  1. Edit: sudo nano $CONFIG_DIR/afpd.conf"
echo "  2. For guest-only, use: - -transall -uamlist uams_guest.so"
echo "  3. For user auth, use: - -transall -uamlist uams_guest.so,uams_clrtxt.so,uams_dhx.so"
echo "  4. Restart: sudo systemctl restart netatalk"
echo ""
echo "Troubleshooting:"
echo "  Service status: sudo systemctl status netatalk"
echo "  View logs: sudo journalctl -u netatalk -n 50"
echo "  Restart service: sudo systemctl restart netatalk"
echo "  Check AppleTalk: sudo nbplookup"
echo ""
