#!/bin/bash
# appletalk-server-setup.sh — Main control script for AppleTalk server setup
# Orchestrates file server and print server installation on Raspberry Pi
# For Apple IIgs and vintage Macintosh compatibility

set -e

# Colours for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No colour

# Check for root privileges
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}This script must be run as root.${NC}"
    echo "Please re-run it using: sudo ./appletalk-server-setup.sh"
    exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "========================================="
echo "AppleTalk Server Setup for Raspberry Pi"
echo "========================================="
echo ""
echo "This script will set up your Raspberry Pi as:"
echo "  1. AppleTalk file server (AFP) for Apple IIgs and vintage Macs"
echo "  2. LaserWriter 8 compatible PostScript RIP print server"
echo ""
echo "Supported systems:"
echo "  - Apple IIgs (GS/OS)"
echo "  - Macintosh System 6.0.x"
echo "  - Macintosh System 7.x"
echo "  - Mac OS 8.x and 9.x"
echo ""

# Ask what to install
echo "What would you like to set up?"
echo ""
echo "1) File server only (recommended first)"
echo "2) Print server only"
echo "3) Both file server and print server"
echo "4) Exit"
echo ""
read -p "Enter your choice (1-4): " SETUP_CHOICE

case $SETUP_CHOICE in
    1)
        echo ""
        echo "Setting up AppleTalk file server..."
        if [ -f "$SCRIPT_DIR/setup-fileserver.sh" ]; then
            bash "$SCRIPT_DIR/setup-fileserver.sh"
        else
            echo -e "${RED}Error: setup-fileserver.sh not found in $SCRIPT_DIR${NC}"
            exit 1
        fi
        ;;
    2)
        echo ""
        echo "Setting up LaserWriter print server..."
        if [ -f "$SCRIPT_DIR/setup-printserver.sh" ]; then
            bash "$SCRIPT_DIR/setup-printserver.sh"
        else
            echo -e "${RED}Error: setup-printserver.sh not found in $SCRIPT_DIR${NC}"
            exit 1
        fi
        ;;
    3)
        echo ""
        echo "Setting up both file server and print server..."
        echo "Installing file server first..."
        if [ -f "$SCRIPT_DIR/setup-fileserver.sh" ]; then
            bash "$SCRIPT_DIR/setup-fileserver.sh"
        else
            echo -e "${RED}Error: setup-fileserver.sh not found in $SCRIPT_DIR${NC}"
            exit 1
        fi
        
        echo ""
        echo "Now installing print server..."
        if [ -f "$SCRIPT_DIR/setup-printserver.sh" ]; then
            bash "$SCRIPT_DIR/setup-printserver.sh"
        else
            echo -e "${RED}Error: setup-printserver.sh not found in $SCRIPT_DIR${NC}"
            exit 1
        fi
        ;;
    4)
        echo "Exiting..."
        exit 0
        ;;
    *)
        echo -e "${RED}Invalid choice. Exiting.${NC}"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}Setup complete!${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "Your Raspberry Pi is ready for use with vintage Apple computers."
echo ""
echo "Network Information:"
echo "  Hostname: $(hostname)"
echo "  IP Address: $(hostname -I | awk '{print $1}')"
echo ""
echo "Next steps:"
echo "  - Configure shares in /etc/netatalk/AppleVolumes.default"
echo "  - Test connection from your vintage Mac or Apple IIgs"
echo "  - Check status: sudo systemctl status netatalk"
echo ""
