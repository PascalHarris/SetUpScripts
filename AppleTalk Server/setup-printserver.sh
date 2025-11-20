#!/bin/bash
# setup-printserver.sh — Configure Raspberry Pi as LaserWriter 8 PostScript RIP server
# For vintage Macintosh System 6 and 7 with LaserWriter driver

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
    echo "Please re-run it using: sudo ./setup-printserver.sh"
    exit 1
fi

echo "========================================="
echo "LaserWriter 8 PostScript RIP Setup"
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

# Install CUPS and dependencies
echo "Installing CUPS and print system dependencies..."
PRINT_DEPS=(cups cups-bsd cups-filters cups-daemon ghostscript cron xinetd)

apt-get update -qq

for pkg in "${PRINT_DEPS[@]}"; do
    if is_installed "$pkg"; then
        echo "  ✓ $pkg already installed"
    else
        echo "  Installing $pkg..."
        apt-get install -y "$pkg" >/dev/null 2>&1
    fi
done

# Check if netatalk is installed (needed for papd)
echo ""
echo "Checking Netatalk for PAP (Printer Access Protocol)..."
NETATALK_VERSION=$(get_netatalk_version)

if [ -z "$NETATALK_VERSION" ]; then
    echo -e "${YELLOW}⚠ Netatalk not found${NC}"
    echo "Netatalk is required for vintage Mac printer support via AppleTalk"
    read -p "Would you like to install the file server first? (Y/n): " INSTALL_FS
    if [[ ! "$INSTALL_FS" =~ ^[Nn]$ ]]; then
        echo "Please run the file server setup script first:"
        echo "  sudo ./setup-fileserver.sh"
        exit 1
    else
        echo "Continuing without AppleTalk printer support..."
        echo "Only IPP and socket printing will be available"
        NETATALK_AVAILABLE=false
    fi
else
    echo -e "  ${GREEN}✓ Netatalk $NETATALK_VERSION found${NC}"
    NETATALK_AVAILABLE=true
fi

# Determine netatalk config directory
if [ "$NETATALK_AVAILABLE" = true ]; then
    if [ -d "/usr/local/etc/netatalk" ]; then
        NETATALK_CONFIG="/usr/local/etc/netatalk"
    elif [ -d "/etc/netatalk" ]; then
        NETATALK_CONFIG="/etc/netatalk"
    else
        echo -e "${YELLOW}⚠ Cannot find netatalk config directory${NC}"
        NETATALK_AVAILABLE=false
    fi
fi

# Start and enable CUPS
echo ""
echo "Configuring CUPS..."
systemctl enable cups >/dev/null 2>&1
systemctl start cups >/dev/null 2>&1
sleep 3

# Add pi user to lpadmin group
usermod -a -G lpadmin pi 2>/dev/null || true
echo "  ✓ Added pi user to lpadmin group"

# Configure CUPS for network access
echo "Configuring CUPS for network printing..."
CUPSD_CONF="/etc/cups/cupsd.conf"
cp "$CUPSD_CONF" "$CUPSD_CONF.bak.$(date +%Y%m%d_%H%M%S)"

cat > "$CUPSD_CONF" << 'EOF'
# CUPS configuration for LaserWriter 8 compatibility
LogLevel warn
MaxLogSize 0

# Listen on all interfaces
Port 631
Listen /var/run/cups/cups.sock
Listen 0.0.0.0:631

# Web interface
WebInterface Yes
DefaultAuthType Basic

# Allow network access
<Location />
  Order allow,deny
  Allow all
</Location>

<Location /admin>
  Order allow,deny
  Allow all
</Location>

<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow all
</Location>

# Browsing
Browsing On
BrowseLocalProtocols dnssd

# Default policy - allow all to print
<Policy default>
  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
    Allow all
  </Limit>
  
  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order deny,allow
    Allow all
  </Limit>
  
  <Limit All>
    Order deny,allow
    Allow all
  </Limit>
</Policy>
EOF

echo -e "  ${GREEN}✓ CUPS configured for network access${NC}"

# Configure PostScript MIME types
echo ""
echo "Configuring PostScript handling..."

# Backup MIME files
if [ -f /etc/cups/mime.types ]; then
    cp /etc/cups/mime.types /etc/cups/mime.types.bak
fi
if [ -f /etc/cups/mime.convs ]; then
    cp /etc/cups/mime.convs /etc/cups/mime.convs.bak
fi

# Ensure PostScript MIME types exist
if [ ! -f /etc/cups/mime.types ]; then
    cat > /etc/cups/mime.types << 'EOF'
# Basic MIME types
text/plain		txt
application/pdf		pdf string(0,%PDF)
EOF
fi

# Add PostScript types including vintage Mac formats
if ! grep -q "^application/postscript.*%!PS-Adobe" /etc/cups/mime.types; then
    cat >> /etc/cups/mime.types << 'EOF'

# PostScript - including vintage Mac LaserWriter output
application/postscript		ps string(0,%!PS-Adobe)
application/postscript		ps string(0,%!PS)
application/postscript		ps (contains \004%!PS)
application/postscript		ps string(0,\004%!PS-Adobe)
application/postscript		ps string(0,\004%!PS)
application/postscript		ps string(0,\001\002\003\004)
EOF
fi

echo -e "  ${GREEN}✓ PostScript MIME types configured${NC}"

# Create Ghostscript filter for PostScript RIP
echo "Creating PostScript RIP filter..."
mkdir -p /usr/lib/cups/filter

cat > /usr/lib/cups/filter/pstoraster << 'EOF'
#!/bin/bash
# pstoraster - Convert PostScript to raster using Ghostscript
# Handles vintage Mac LaserWriter PostScript

# CUPS filter interface
JOB="$1"
USER="$2"
TITLE="$3"
COPIES="$4"
OPTIONS="$5"
FILE="${6:--}"

# Log to CUPS error log
exec 2>>/var/log/cups/error_log
echo "DEBUG: pstoraster - Job $JOB, User $USER, File $FILE" >&2

# Create temp file
TEMP_PS=$(mktemp /tmp/ps_XXXXXX.ps)
trap "rm -f $TEMP_PS" EXIT

# Read input
if [ "$FILE" = "-" ]; then
    cat > "$TEMP_PS"
else
    cat "$FILE" > "$TEMP_PS"
fi

# Strip Mac binary PostScript header if present
if head -c 4 "$TEMP_PS" | od -t x1 | grep -q "01 02 03 04"; then
    echo "DEBUG: Removing Mac binary PostScript header" >&2
    # Mac binary PS: 4-byte signature + 4-byte PS length + 4-byte resource length
    # Skip 12 bytes of header, extract PS portion
    dd if="$TEMP_PS" of="${TEMP_PS}.clean" bs=1 skip=12 2>/dev/null
    mv "${TEMP_PS}.clean" "$TEMP_PS"
fi

# Parse options
RESOLUTION="600"
PAGESIZE="letter"

for option in $(echo "$OPTIONS" | tr ' ' '\n'); do
    case "$option" in
        Resolution=*) RESOLUTION="${option#*=}" ;;
        PageSize=*|media=*) PAGESIZE="${option#*=}" ;;
    esac
done

echo "DEBUG: Resolution=$RESOLUTION, PageSize=$PAGESIZE" >&2

# Run Ghostscript
gs -dNOPAUSE -dBATCH -dSAFER \
   -dNOPLATFONTS \
   -dFIXEDMEDIA \
   -dFitPage \
   -dCompatibilityLevel=1.4 \
   -sDEVICE=cups \
   -r${RESOLUTION}x${RESOLUTION} \
   -sPAPERSIZE=$PAGESIZE \
   -sOutputFile=- \
   "$TEMP_PS" 2>>/var/log/cups/error_log

exit $?
EOF

chmod +x /usr/lib/cups/filter/pstoraster
echo -e "  ${GREEN}✓ PostScript RIP filter created${NC}"

# Create LaserWriter PPD
echo "Creating LaserWriter 8 compatible PPD..."
mkdir -p /usr/share/ppd/custom

cat > /usr/share/ppd/custom/LaserWriter8.ppd << 'EOF'
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "LW8.PPD"
*Manufacturer: "Apple"
*Product: "(LaserWriter 8 RIP)"
*ModelName: "LaserWriter 8 RIP Server"
*ShortNickName: "LaserWriter 8 RIP"
*NickName: "Apple LaserWriter 8 RIP (Raspberry Pi)"
*PSVersion: "(2016.0) 0"
*LanguageLevel: "2"
*ColorDevice: False
*DefaultColorSpace: Gray
*FileSystem: False
*Throughput: "8"
*LandscapeOrientation: Plus90
*TTRasterizer: Type42

*cupsVersion: 1.4
*cupsManualCopies: False
*cupsFilter: "application/postscript 0 pstoraster"

*% Standard fonts
*DefaultFont: Courier
*Font Courier: Standard "(001.000)" Standard ROM
*Font Courier-Bold: Standard "(001.000)" Standard ROM
*Font Courier-BoldOblique: Standard "(001.000)" Standard ROM
*Font Courier-Oblique: Standard "(001.000)" Standard ROM
*Font Helvetica: Standard "(001.000)" Standard ROM
*Font Helvetica-Bold: Standard "(001.000)" Standard ROM
*Font Helvetica-BoldOblique: Standard "(001.000)" Standard ROM
*Font Helvetica-Oblique: Standard "(001.000)" Standard ROM
*Font Times-Roman: Standard "(001.000)" Standard ROM
*Font Times-Bold: Standard "(001.000)" Standard ROM
*Font Times-BoldItalic: Standard "(001.000)" Standard ROM
*Font Times-Italic: Standard "(001.000)" Standard ROM
*Font Symbol: Special "(001.000)" Special ROM

*% Page sizes
*OpenUI *PageSize: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: Letter
*PageSize Letter/US Letter: "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
*PageSize A4: "<</PageSize[595 842]/ImagingBBox null>>setpagedevice"
*PageSize Legal/US Legal: "<</PageSize[612 1008]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageSize

*OpenUI *PageRegion: PickOne
*OrderDependency: 10 AnySetup *PageRegion
*DefaultPageRegion: Letter
*PageRegion Letter: "<</PageSize[612 792]/ImagingBBox null>>setpagedevice"
*PageRegion A4: "<</PageSize[595 842]/ImagingBBox null>>setpagedevice"
*PageRegion Legal: "<</PageSize[612 1008]/ImagingBBox null>>setpagedevice"
*CloseUI: *PageRegion

*DefaultImageableArea: Letter
*ImageableArea Letter: "18 18 594 774"
*ImageableArea A4: "18 18 577 824"
*ImageableArea Legal: "18 18 594 990"

*DefaultPaperDimension: Letter
*PaperDimension Letter: "612 792"
*PaperDimension A4: "595 842"
*PaperDimension Legal: "612 1008"

*% Resolution
*OpenUI *Resolution: PickOne
*OrderDependency: 10 AnySetup *Resolution
*DefaultResolution: 600dpi
*Resolution 300dpi: "<</HWResolution[300 300]>>setpagedevice"
*Resolution 600dpi: "<</HWResolution[600 600]>>setpagedevice"
*CloseUI: *Resolution
EOF

echo -e "  ${GREEN}✓ LaserWriter 8 PPD created${NC}"

# Restart CUPS
echo ""
echo "Restarting CUPS..."
systemctl restart cups
sleep 3

# Set up printer
echo ""
echo "Printer Setup"
echo "-------------"
echo "Do you want to add a printer now?"
read -p "(Y/n): " ADD_PRINTER

if [[ ! "$ADD_PRINTER" =~ ^[Nn]$ ]]; then
    echo ""
    echo "Printer connection options:"
    echo "1) USB printer"
    echo "2) Network printer (IP address)"
    echo "3) Manual device URI"
    echo "4) Skip for now"
    read -p "Select option (1-4): " PRINTER_TYPE
    
    case $PRINTER_TYPE in
        1)
            echo "Scanning for USB printers..."
            USB_DEVICES=($(lpinfo -v 2>/dev/null | grep "usb:" | awk '{print $2}'))
            if [ ${#USB_DEVICES[@]} -eq 0 ]; then
                echo "No USB printers found"
                exit 0
            fi
            echo "Found:"
            for i in "${!USB_DEVICES[@]}"; do
                echo "  $((i+1))) ${USB_DEVICES[$i]}"
            done
            read -p "Select printer: " USB_SEL
            DEVICE_URI="${USB_DEVICES[$((USB_SEL-1))]}"
            ;;
        2)
            read -p "Enter printer IP address: " PRINTER_IP
            # Try socket first (most common for PostScript printers)
            if timeout 2 bash -c "echo > /dev/tcp/$PRINTER_IP/9100" 2>/dev/null; then
                DEVICE_URI="socket://$PRINTER_IP:9100"
                echo "Using socket (port 9100)"
            elif timeout 2 bash -c "echo > /dev/tcp/$PRINTER_IP/515" 2>/dev/null; then
                read -p "Enter printer queue name (or press Enter for default): " QUEUE
                DEVICE_URI="lpd://$PRINTER_IP/${QUEUE:-printer}"
                echo "Using LPD (port 515)"
            else
                echo "No response on standard ports, defaulting to socket"
                DEVICE_URI="socket://$PRINTER_IP:9100"
            fi
            ;;
        3)
            read -p "Enter device URI: " DEVICE_URI
            ;;
        4)
            echo "Skipping printer setup"
            exit 0
            ;;
        *)
            echo "Invalid option"
            exit 1
            ;;
    esac
    
    read -p "Enter printer name (e.g., LaserWriter): " PRINTER_NAME
    if [ -z "$PRINTER_NAME" ]; then
        PRINTER_NAME="LaserWriter"
    fi
    
    echo ""
    echo "Adding printer '$PRINTER_NAME'..."
    lpadmin -p "$PRINTER_NAME" \
            -v "$DEVICE_URI" \
            -P /usr/share/ppd/custom/LaserWriter8.ppd \
            -E \
            -o printer-is-shared=true
    
    # Set as default
    lpoptions -d "$PRINTER_NAME" >/dev/null 2>&1
    
    echo -e "${GREEN}✓ Printer '$PRINTER_NAME' added${NC}"
    
    # Configure PAP if netatalk is available
    if [ "$NETATALK_AVAILABLE" = true ]; then
        echo ""
        echo "Configuring AppleTalk PAP for LaserWriter 8..."
        
        PAPD_CONF="$NETATALK_CONFIG/papd.conf"
        
        # Backup existing papd.conf
        if [ -f "$PAPD_CONF" ]; then
            cp "$PAPD_CONF" "$PAPD_CONF.bak.$(date +%Y%m%d_%H%M%S)"
        fi
        
        # Create papd.conf
        cat > "$PAPD_CONF" << EOF
# papd.conf - Printer Access Protocol configuration
# LaserWriter 8 compatible printer

$PRINTER_NAME:\\
    :pr=|/usr/bin/lp -d $PRINTER_NAME:\\
    :op=daemon:
EOF
        
        echo -e "  ${GREEN}✓ PAP configured${NC}"
        
        # Restart netatalk to activate PAP
        echo "  Restarting netatalk..."
        systemctl restart netatalk
        sleep 2
        
        if systemctl is-active netatalk >/dev/null 2>&1; then
            echo -e "  ${GREEN}✓ Netatalk restarted${NC}"
        else
            echo -e "  ${YELLOW}⚠ Netatalk may need attention${NC}"
            echo "  Check: sudo journalctl -u netatalk -n 20"
        fi
    fi
else
    PRINTER_NAME="(none configured)"
fi

# Display completion message
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}LaserWriter 8 Print Server Setup Complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Server Information:"
echo "  IP Address: $(hostname -I | awk '{print $1}')"
echo "  Hostname: $(hostname)"
echo "  CUPS Web Interface: http://$(hostname -I | awk '{print $1}'):631"
echo ""

if [ "$NETATALK_AVAILABLE" = true ]; then
    echo "Printing from System 6/7 (LaserWriter 8 driver):"
    echo ""
    echo "Method 1 - AppleTalk (Recommended):"
    echo "  1. Open Chooser from Apple menu"
    echo "  2. Click LaserWriter 8 (or LaserWriter) icon"
    echo "  3. Ensure AppleTalk is 'Active'"
    echo "  4. Select '$PRINTER_NAME' from the list"
    echo "  5. Click 'Setup' or 'Select'"
    echo ""
else
    echo -e "${YELLOW}Note: AppleTalk PAP not available${NC}"
    echo "Install file server for AppleTalk support"
    echo ""
fi

echo "Method 2 - IPP (Mac OS 8/9 and later):"
echo "  Use printer at: ipp://$(hostname -I | awk '{print $1}'):631/printers/$PRINTER_NAME"
echo ""
echo "Troubleshooting:"
echo "  Check CUPS status: sudo systemctl status cups"
echo "  View print jobs: lpstat -t"
echo "  View CUPS logs: sudo tail -f /var/log/cups/error_log"
if [ "$NETATALK_AVAILABLE" = true ]; then
    echo "  Check PAP config: cat $NETATALK_CONFIG/papd.conf"
    echo "  Test AppleTalk: nbplookup"
fi
echo ""
echo "Test printing:"
echo "  echo '%!PS' | lp -d $PRINTER_NAME"
echo ""
