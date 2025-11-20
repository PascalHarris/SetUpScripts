#!/bin/bash
# diagnose-appletalk.sh - Diagnose AppleTalk networking issues

echo "========================================="
echo "AppleTalk Diagnostic Script"
echo "========================================="
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Some checks require root. Run with: sudo $0"
    echo ""
fi

# Find netatalk binaries
echo "1. Locating Netatalk binaries..."
ATALKD=""
AFPD=""

if [ -x "/usr/local/sbin/atalkd" ]; then
    ATALKD="/usr/local/sbin/atalkd"
    AFPD="/usr/local/sbin/afpd"
elif [ -x "/usr/sbin/atalkd" ]; then
    ATALKD="/usr/sbin/atalkd"
    AFPD="/usr/sbin/afpd"
fi

if [ -n "$ATALKD" ]; then
    echo "   ✓ Found atalkd: $ATALKD"
    echo "   ✓ Found afpd: $AFPD"
    $ATALKD -V 2>&1 | head -1
else
    echo "   ✗ Cannot find atalkd binary"
    exit 1
fi

echo ""

# Check if daemons are running
echo "2. Checking daemon status..."
if pgrep -x atalkd >/dev/null; then
    echo "   ✓ atalkd is running (PID: $(pgrep -x atalkd))"
else
    echo "   ✗ atalkd is NOT running"
fi

if pgrep -x afpd >/dev/null; then
    echo "   ✓ afpd is running (PID: $(pgrep -x afpd))"
else
    echo "   ✗ afpd is NOT running"
fi

echo ""

# Check network interfaces
echo "3. Network interfaces..."
ip -br link show | grep -v "lo" | while read iface state rest; do
    echo "   Interface: $iface - State: $state"
done

echo ""

# Check configuration files
echo "4. Configuration files..."

CONFIG_DIRS=("/usr/local/etc/netatalk" "/etc/netatalk")
ATALKD_CONF=""
AFPD_CONF=""

for dir in "${CONFIG_DIRS[@]}"; do
    if [ -f "$dir/atalkd.conf" ]; then
        ATALKD_CONF="$dir/atalkd.conf"
        break
    fi
done

for dir in "${CONFIG_DIRS[@]}"; do
    if [ -f "$dir/afpd.conf" ]; then
        AFPD_CONF="$dir/afpd.conf"
        break
    fi
done

if [ -n "$ATALKD_CONF" ]; then
    echo "   atalkd.conf: $ATALKD_CONF"
    echo "   Contents:"
    grep -v "^#" "$ATALKD_CONF" | grep -v "^$" | sed 's/^/      /'
else
    echo "   ✗ atalkd.conf not found"
fi

echo ""

if [ -n "$AFPD_CONF" ]; then
    echo "   afpd.conf: $AFPD_CONF"
    echo "   Contents:"
    grep -v "^#" "$AFPD_CONF" | grep -v "^$" | sed 's/^/      /'
else
    echo "   ✗ afpd.conf not found"
fi

echo ""

# Check if AppleTalk is actually bound to an interface
echo "5. AppleTalk network status..."
if [ -f /proc/net/atalk ]; then
    if [ -s /proc/net/atalk ]; then
        echo "   /proc/net/atalk contents:"
        cat /proc/net/atalk | sed 's/^/      /'
    else
        echo "   ✗ /proc/net/atalk is empty (AppleTalk not active)"
    fi
else
    echo "   ✗ /proc/net/atalk doesn't exist (no AppleTalk kernel support)"
fi

echo ""

# Try to manually start atalkd to see errors
if [ "$EUID" -eq 0 ]; then
    echo "6. Attempting to start atalkd manually..."
    
    # Kill existing atalkd
    killall atalkd 2>/dev/null
    sleep 1
    
    if [ -n "$ATALKD_CONF" ]; then
        echo "   Running: $ATALKD -f $ATALKD_CONF"
        echo "   Output:"
        $ATALKD -f "$ATALKD_CONF" 2>&1 | sed 's/^/      /'
        sleep 2
        
        if pgrep -x atalkd >/dev/null; then
            echo "   ✓ atalkd started successfully"
            
            # Check if it actually configured interfaces
            echo ""
            echo "   Checking AppleTalk interface configuration..."
            if [ -f /proc/net/atalk ] && [ -s /proc/net/atalk ]; then
                echo "   ✓ AppleTalk network is active:"
                cat /proc/net/atalk | sed 's/^/      /'
            else
                echo "   ✗ atalkd running but no AppleTalk network configured"
            fi
        else
            echo "   ✗ atalkd failed to start or immediately exited"
        fi
    else
        echo "   ✗ Cannot test without atalkd.conf"
    fi
else
    echo "6. Manual atalkd test requires root (skipped)"
fi

echo ""
echo "========================================="
echo "Diagnostic Summary"
echo "========================================="
echo ""
echo "Common issues and fixes:"
echo ""
echo "1. Wrong network interface in atalkd.conf"
echo "   Solution: Edit atalkd.conf to use correct interface (eth0, wlan0, etc.)"
echo ""
echo "2. AppleTalk kernel module not loaded"
echo "   Solution: modprobe appletalk"
echo ""
echo "3. atalkd daemon not starting"
echo "   Solution: Check 'dmesg | tail' for kernel errors"
echo ""
echo "4. Permissions issues"
echo "   Solution: Ensure atalkd runs as root"
echo ""

if [ "$EUID" -ne 0 ]; then
    echo "Run this script with sudo for more detailed diagnostics:"
    echo "  sudo $0"
fi

echo ""
