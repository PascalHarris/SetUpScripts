#!/usr/bin/env bash
#
# 01-system-prep.sh
# Base system preparation for the IIgs kiosk.
#
# - installs build + runtime packages (incl. socat for the serial bridge)
# - enables SSH (configuration access requirement)
# - installs the OSS sound shim (GSport writes to /dev/dsp)
# - routes audio to the ANALOG 3.5mm jack (VGA-via-HDMI carries no audio, and
#   composite shares the same analog jack, so analog is the correct sink)
# - disables onboard WiFi + Bluetooth (Uthernet/AppleTalk need wired Ethernet,
#   and WiFi is explicitly unsupported by the layer-2 promiscuous mechanism)
# - creates /opt/gsport tree for the binary, ROM, images, config
#
# Idempotent where practical. The audio + wifi bits should be verified on-device.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

BOOT_DIR="/boot/firmware"; [[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"
CONFIG_TXT="$BOOT_DIR/config.txt"

echo "[01] apt update + packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  build-essential git perl \
  libpcap-dev \
  libx11-dev libxext-dev \
  plymouth plymouth-themes \
  rfkill alsa-utils socat \
  openssh-server

echo "[01] enable + start SSH"
systemctl enable --now ssh

echo "[01] OSS sound shim so /dev/dsp exists (GSport uses OSS)"
modprobe snd_pcm_oss || echo "  (modprobe now failed; will load at boot anyway)"
grep -q '^snd_pcm_oss' /etc/modules 2>/dev/null || echo 'snd_pcm_oss' >> /etc/modules

echo "[01] route audio to the analog 3.5mm jack"
# /dev/dsp (the OSS shim) follows the ALSA default device, so we pin the ALSA
# default to the on-board analog card. Resolve its card number rather than
# assuming, because numbering varies by OS/overlay set.
ANALOG_CARD=$(aplay -l 2>/dev/null | awk -F'[ :]+' \
  '/Headphones|bcm2835|Analog/ {print $2; exit}')
if [[ -n "${ANALOG_CARD:-}" ]]; then
  cat > /etc/asound.conf <<EOF
# Default ALSA output -> on-board analog jack (carries composite-jack audio).
defaults.pcm.card $ANALOG_CARD
defaults.ctl.card $ANALOG_CARD
EOF
  echo "  analog card = $ANALOG_CARD (written to /etc/asound.conf)"
  # Legacy route selector (0=auto,1=analog,2=HDMI); harmless if absent.
  amixer -c "$ANALOG_CARD" cset numid=3 1 >/dev/null 2>&1 || true
else
  echo "  WARN: could not detect analog card from 'aplay -l'."
  echo "        After boot, run 'aplay -l', then set defaults.pcm.card in"
  echo "        /etc/asound.conf. (USB sound card users: point it there instead.)"
fi

echo "[01] disable onboard WiFi + Bluetooth (wired-only requirement)"
add_overlay() { grep -q "^$1" "$CONFIG_TXT" || echo "$1" >> "$CONFIG_TXT"; }
add_overlay "dtoverlay=disable-wifi"
add_overlay "dtoverlay=disable-bt"
rfkill block wifi 2>/dev/null || true

echo "[01] create /opt/gsport tree"
install -d -m 0755 /opt/gsport /opt/gsport/images /opt/gsport/roms
cat > /opt/gsport/PUT-YOUR-ROM-HERE.txt <<'EOF'
Copy your legally-owned Apple IIgs ROM03 image to:  /opt/gsport/ROM
(No ROM is downloaded for you; ROMs are copyrighted.)
AppleTalk bridging requires a ROM03 machine specifically.
EOF

echo "[01] done. Next: sudo ./02-build-gsport.sh"
