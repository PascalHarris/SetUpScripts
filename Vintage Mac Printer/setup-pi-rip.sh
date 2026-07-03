#!/usr/bin/env bash
# =============================================================================
# setup-pi-rip.sh
#
# Configure a Raspberry Pi as an AppleTalk PostScript RIP front-end for a
# modern CUPS-driven inkjet (default target: Epson WF-3540).
#
# Pipeline this script wires up:
#   Vintage Mac (LaserWriter driver, colour PPD)
#        | AppleTalk / PAP
#        v
#   papd (Netatalk 2.x) on the Pi
#        | local CUPS submission (job stays application/postscript)
#        v
#   CUPS queue on the Pi  -> Ghostscript RIP -> escpr filter -> ESC/P-R
#        | socket:// or lpd:// over the LAN
#        v
#   Epson WF-3540 (on Wi-Fi, reachable via the router)
#
# WHAT THIS SCRIPT DOES
#   1. Verifies prerequisites (root, CUPS, Netatalk 2.x with AppleTalk, the
#      AppleTalk kernel module, the escpr driver).
#   2. Discovers network printers via CUPS and lets you pick the Epson
#      (or enter a device URI by hand).
#   3. Creates a local CUPS queue that RIPs PostScript to the Epson.
#   4. Prompts for an AppleTalk-visible printer name and an AppleTalk zone
#      (with sensible defaults) and writes atalkd.conf + papd.conf.
#   5. Installs the Mac-side colour PPD (if present beside this script) and
#      points papd at it.
#   6. Restarts the AppleTalk services and verifies NBP registration.
#
# WHAT THIS SCRIPT DELIBERATELY DOES NOT DO
#   - It does NOT build the AppleTalk kernel module or compile Netatalk 2.x.
#     Those are one-off, environment-specific steps covered in the README,
#     because blindly scripting a kernel build is unsafe. This script only
#     checks that they are already in place and stops with guidance if not.
#
# Tested logic against CUPS 2.4 tooling. AppleTalk/papd behaviour follows the
# Netatalk 2.x manual. Anything not directly verifiable is flagged inline.
#
# Usage:  sudo ./setup-pi-rip.sh
# =============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Constants / defaults
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly MAC_PPD_SRC="${SCRIPT_DIR}/Epson-WF3540-RIP-Colour.ppd"
readonly DEFAULT_QUEUE="EpsonRIP"
readonly DEFAULT_ATALK_NAME="Epson WF-3540 RIP"
readonly DEFAULT_ZONE="RIP"
readonly PRINTER_MATCH="WF-3540"   # used to auto-pick the CUPS driver model

# Candidate Netatalk config directories, most-likely first. Detected at runtime
# because the path depends on how Netatalk 2.x was built (--sysconfdir).
readonly ATALK_DIRS=(/etc/atalk /usr/local/etc/atalk /etc/netatalk /usr/local/etc/netatalk)

# ----------------------------------------------------------------------------
# Small helpers
# ----------------------------------------------------------------------------
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
note() { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

# Prompt with a default value. $1=prompt text, $2=default. Echoes the answer.
ask() {
    local prompt="$1" default="${2:-}" reply
    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " reply || true
        printf '%s' "${reply:-$default}"
    else
        read -r -p "$prompt: " reply || true
        printf '%s' "$reply"
    fi
}

confirm() {
    local reply
    read -r -p "$1 [y/N]: " reply || true
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

backup_file() {
    [[ -f "$1" ]] || return 0
    local bak
    bak="$1.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$1" "$bak"
    note "Backed up $1 -> $bak"
}

# ----------------------------------------------------------------------------
# 0. Preconditions
# ----------------------------------------------------------------------------
[[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo $0)."

note "Checking prerequisites"

command -v lpadmin >/dev/null 2>&1 || die "CUPS client tools not found. Install: apt install cups cups-client"
command -v lpinfo  >/dev/null 2>&1 || die "lpinfo not found (part of CUPS server). Install: apt install cups"
command -v gs      >/dev/null 2>&1 || warn "Ghostscript (gs) not found. The RIP needs it: apt install ghostscript"

# Is CUPS actually running? lpinfo needs the scheduler.
if ! lpstat -r >/dev/null 2>&1; then
    die "cupsd is not running. Start it: systemctl enable --now cups"
fi

# AppleTalk kernel module: required for papd/atalkd (DDP). Not in stock
# Raspberry Pi OS; see README section 'AppleTalk kernel module'.
if ! grep -qi appletalk /proc/net/protocols 2>/dev/null \
   && ! lsmod | grep -q '^appletalk' \
   && ! modprobe appletalk 2>/dev/null; then
    die "AppleTalk kernel support is missing. Build/install the 'appletalk' module first (README)."
fi
note "AppleTalk kernel support present."

# papd / atalkd present? (Netatalk 2.x built with AppleTalk.)
command -v atalkd >/dev/null 2>&1 || die "atalkd not found. Build Netatalk 2.x with AppleTalk (README)."
command -v papd   >/dev/null 2>&1 || die "papd not found. Build Netatalk 2.x with papd enabled (README)."

# Locate the Netatalk config directory.
ATALK_DIR=""
for d in "${ATALK_DIRS[@]}"; do
    if [[ -d "$d" ]]; then ATALK_DIR="$d"; break; fi
done
if [[ -z "$ATALK_DIR" ]]; then
    ATALK_DIR="$(ask "Netatalk config dir not auto-detected. Enter path" "/etc/atalk")"
    mkdir -p "$ATALK_DIR"
fi
note "Using Netatalk config directory: $ATALK_DIR"

# ----------------------------------------------------------------------------
# 1. Choose the network interface AppleTalk will run on (wired only)
# ----------------------------------------------------------------------------
# The pre-6.9 AppleTalk kernel module mishandles multiple interfaces, and you
# must never route AppleTalk over Wi-Fi. So we bind a single wired interface.
note "Selecting the wired interface for AppleTalk"
WIRED_IFACES=()
for _ifpath in /sys/class/net/eth* /sys/class/net/en*; do
    [[ -e "$_ifpath" ]] && WIRED_IFACES+=("$(basename "$_ifpath")")
done
if [[ ${#WIRED_IFACES[@]} -eq 0 ]]; then
    IFACE="$(ask "No eth*/en* interface auto-detected. Enter interface name" "eth0")"
else
    printf 'Detected wired interfaces: %s\n' "${WIRED_IFACES[*]}"
    IFACE="$(ask "Interface to use for AppleTalk" "${WIRED_IFACES[0]}")"
fi
[[ -e "/sys/class/net/$IFACE" ]] || warn "Interface $IFACE not currently present; continuing anyway."

# ----------------------------------------------------------------------------
# 2. Discover / choose the target printer (the real Epson)
# ----------------------------------------------------------------------------
note "Discovering network printers via CUPS (this can take ~10s)"
# lpinfo -v lists device URIs. We keep only network backends.
mapfile -t DEVICES < <(lpinfo -v 2>/dev/null | awk '$1=="network"{ $1=""; sub(/^ /,""); print }')

PRINTER_URI=""
if [[ ${#DEVICES[@]} -gt 0 ]]; then
    echo "Available network devices:"
    local_i=1
    for d in "${DEVICES[@]}"; do
        printf '  %2d) %s\n' "$local_i" "$d"
        local_i=$((local_i + 1))
    done
    printf '  %2d) Enter a device URI manually\n' "$local_i"
    choice="$(ask "Choose the printer to use as the RIP target" "1")"
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DEVICES[@]} )); then
        PRINTER_URI="${DEVICES[$((choice - 1))]}"
    fi
fi

if [[ -z "$PRINTER_URI" ]]; then
    echo "Enter the printer device URI manually."
    echo "Examples:  socket://192.168.1.50:9100   or   lpd://192.168.1.50/PASSTHRU/WF-3540"
    PRINTER_URI="$(ask "Device URI")"
    [[ -n "$PRINTER_URI" ]] || die "No device URI provided."
fi
note "Target printer URI: $PRINTER_URI"

# ----------------------------------------------------------------------------
# 3. Choose the CUPS driver (PPD/model) for the Epson on the Pi side
# ----------------------------------------------------------------------------
# This PPD drives the REAL Epson (ESC/P-R). Distinct from the Mac-side PPD.
note "Selecting the Pi-side CUPS driver for the Epson"
MODEL=""
# Prefer an exact escpr match for the WF-3540.
MODEL="$(lpinfo -m 2>/dev/null | grep -i "$PRINTER_MATCH" | grep -i escpr | head -n1 | awk '{print $1}' || true)"
[[ -z "$MODEL" ]] && MODEL="$(lpinfo -m 2>/dev/null | grep -i "$PRINTER_MATCH" | head -n1 | awk '{print $1}' || true)"

if [[ -n "$MODEL" ]]; then
    note "Matched driver: $MODEL"
    DRIVER_ARG=(-m "$MODEL")
else
    warn "No '$PRINTER_MATCH' driver found via lpinfo -m."
    echo "Options:"
    echo "  1) Use IPP-Everywhere / driverless (good if the Epson is on AirPrint)"
    echo "  2) Supply a PPD file path (e.g. an escpr PPD you downloaded)"
    echo "  3) Pick a model string from 'lpinfo -m' yourself"
    opt="$(ask "Choose" "1")"
    case "$opt" in
        1) DRIVER_ARG=(-m everywhere) ;;
        2) ppd="$(ask "Path to PPD")"; [[ -f "$ppd" ]] || die "PPD not found: $ppd"; DRIVER_ARG=(-P "$ppd") ;;
        3) ms="$(ask "Model string from lpinfo -m")"; [[ -n "$ms" ]] || die "No model string."; DRIVER_ARG=(-m "$ms") ;;
        *) die "Invalid option." ;;
    esac
fi

# ----------------------------------------------------------------------------
# 4. Names and zone
# ----------------------------------------------------------------------------
note "Naming"
QUEUE="$(ask "Internal CUPS queue name (no spaces)" "$DEFAULT_QUEUE")"
QUEUE="${QUEUE// /_}"
ATALK_NAME="$(ask "Name shown to Macs in the Chooser" "$DEFAULT_ATALK_NAME")"
ZONE="$(ask "AppleTalk zone to publish the printer in" "$DEFAULT_ZONE")"

# ----------------------------------------------------------------------------
# 5. Create the CUPS queue (the actual RIP)
# ----------------------------------------------------------------------------
note "Creating CUPS queue '$QUEUE'"
lpadmin -p "$QUEUE" -v "$PRINTER_URI" "${DRIVER_ARG[@]}" -E \
        -o printer-error-policy=retry-job
cupsenable "$QUEUE" || true
cupsaccept "$QUEUE" || true
note "CUPS queue created. Test later with: echo hi | lp -d $QUEUE"

# ----------------------------------------------------------------------------
# 6. Install the Mac-side colour PPD (advertised by papd via 'pd=')
# ----------------------------------------------------------------------------
MAC_PPD_DEST="$ATALK_DIR/$(basename "$MAC_PPD_SRC")"
if [[ -f "$MAC_PPD_SRC" ]]; then
    cp -f "$MAC_PPD_SRC" "$MAC_PPD_DEST"
    note "Installed Mac-side PPD at $MAC_PPD_DEST"
else
    warn "Mac-side PPD not found at $MAC_PPD_SRC. papd will fall back to the CUPS PPD."
    MAC_PPD_DEST=""
fi

# ----------------------------------------------------------------------------
# 7. Write atalkd.conf  (seed router on the wired interface, one named zone)
# ----------------------------------------------------------------------------
# NOTE: We seed because a named zone needs a seed router when no other
# AppleTalk router exists (the normal case on a modern LAN). If you KNOW there
# is already an AppleTalk router on this segment, do NOT seed: replace the line
# below with just '<iface>' and let it learn the zone.
ATALKD_CONF="$ATALK_DIR/atalkd.conf"
backup_file "$ATALKD_CONF"
cat > "$ATALKD_CONF" <<EOF
# Generated by setup-pi-rip.sh on $(date)
# Single wired interface, seed router, one zone. Phase 2 (EtherTalk).
$IFACE -seed -phase 2 -net 1-1000 -addr 1000.142 -zone "$ZONE"
EOF
note "Wrote $ATALKD_CONF"

# ----------------------------------------------------------------------------
# 8. Write papd.conf  (advertise the AppleTalk printer -> local CUPS queue)
# ----------------------------------------------------------------------------
# papd CUPS integration: a bare queue name as 'pr' submits to CUPS (NOT lpd),
# so the PostScript is RIPped by the CUPS filter chain. 'pd' advertises the
# Mac-facing PPD. 'op=root' sets the operator.
PAPD_CONF="$ATALK_DIR/papd.conf"
backup_file "$PAPD_CONF"
{
    echo "# Generated by setup-pi-rip.sh on $(date)"
    echo "\"$ATALK_NAME:LaserWriter@$ZONE\":\\"
    echo "    :pr=$QUEUE:\\"
    if [[ -n "$MAC_PPD_DEST" ]]; then
        echo "    :pd=$MAC_PPD_DEST:\\"
    fi
    echo "    :op=root:"
} > "$PAPD_CONF"
note "Wrote $PAPD_CONF"

# ----------------------------------------------------------------------------
# 9. (Re)start AppleTalk services
# ----------------------------------------------------------------------------
note "Starting AppleTalk services"
# atalkd must be up and stable before papd registers. Service unit names can
# vary between Netatalk 2.x packagings; try systemd first, fall back to binaries.
start_service() {
    local svc="$1"
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl enable "$svc" >/dev/null 2>&1 || true
        systemctl restart "$svc"
        return 0
    fi
    return 1
}

if ! start_service atalkd; then
    warn "No atalkd systemd unit; start atalkd manually after this script."
fi
note "Waiting for atalkd to stabilise (NBP/ZIP can take up to a minute)..."
sleep 20
if ! start_service papd; then
    warn "No papd systemd unit; start papd manually after this script."
fi

# ----------------------------------------------------------------------------
# 10. Verify
# ----------------------------------------------------------------------------
note "Verifying AppleTalk registration (nbplkup)"
if command -v nbplkup >/dev/null 2>&1; then
    sleep 3
    if nbplkup 2>/dev/null | grep -qi "$ATALK_NAME"; then
        nbplkup | grep -i "$ATALK_NAME" || true
        note "SUCCESS: '$ATALK_NAME' is registered on AppleTalk."
    else
        warn "Did not see '$ATALK_NAME' in nbplkup yet. Give it a minute, then re-run: nbplkup"
        warn "If it never appears, check: journalctl -u atalkd -u papd"
    fi
else
    warn "nbplkup not found; cannot auto-verify. Check Chooser on the Mac."
fi

cat <<EOF

-----------------------------------------------------------------------------
Done. Summary:
  Wired interface : $IFACE
  AppleTalk zone  : $ZONE
  Chooser name    : $ATALK_NAME
  CUPS queue      : $QUEUE  ->  $PRINTER_URI
  Mac-side PPD    : ${MAC_PPD_DEST:-<CUPS default>}

Next on the VINTAGE MAC:
  1. Copy Epson-WF3540-RIP-Colour.ppd into the Mac's
     "Printer Descriptions" folder (System Folder:Extensions:Printer Descriptions).
  2. Open the Chooser, select the LaserWriter driver, pick zone "$ZONE",
     select "$ATALK_NAME", click Setup/Create, and choose that PPD.
  3. Print a test page. Watch the Pi with: lpstat -o ; journalctl -u papd -f
-----------------------------------------------------------------------------
EOF
