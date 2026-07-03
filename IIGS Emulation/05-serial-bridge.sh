#!/usr/bin/env bash
#
# 05-serial-bridge.sh [DEVICE] [BAUD] [SCC_PORT]
#   DEVICE   = USB serial device          (default /dev/ttyUSB0)
#   BAUD     = line speed, must match IIgs (default 9600)
#   SCC_PORT = GSport TCP port to bridge   (default 6502 = IIgs modem port/slot 2)
#
# GSport's Linux build exposes each emulated SCC serial port as a TCP listener
# (6501 = printer/slot 1, 6502 = modem/slot 2); the real-serial-device backend
# is Mac-only and is NOT compiled on the Pi. So to use a physical USB RS232
# adaptor we bridge GSport's TCP socket to the device with socat.
#
# Slot guidance: use 6502 (modem/slot 2) for RS232. Slot 1 may be taken by
# AppleTalk. Serial and Uthernet (slot 3) run simultaneously -- no conflict.
#
# This installs a systemd service that keeps the bridge up and reconnects (the
# TCP side only exists once GSport has initialised that SCC port).

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

DEVICE="${1:-/dev/ttyUSB0}"
BAUD="${2:-9600}"
SCC_PORT="${3:-6502}"

command -v socat >/dev/null || { echo "socat missing; run 01-system-prep.sh"; exit 1; }

echo "[05] bridge $DEVICE <-> 127.0.0.1:$SCC_PORT @ ${BAUD}baud"

cat > /etc/systemd/system/gsport-serial.service <<EOF
[Unit]
Description=GSport USB RS232 bridge ($DEVICE <-> tcp/$SCC_PORT)
After=gsport-kiosk.service
Wants=gsport-kiosk.service

[Service]
Type=simple
# socat pipes the physical serial device to GSport's TCP serial socket.
# retry/forever handles the socket not existing until the IIgs opens the port.
ExecStart=/usr/bin/socat -d \\
  $DEVICE,b$BAUD,raw,echo=0,nonblock \\
  TCP:127.0.0.1:$SCC_PORT,retry,interval=2,forever
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gsport-serial.service
echo "[05] done."
echo "    - In GSport F4 -> Serial Port Configuration: set the port you bridged"
echo "      (slot 2) to 'Only use socket $SCC_PORT'."
echo "    - Set the SAME baud on the IIgs side and on this bridge ($BAUD)."
echo "    - Start now without reboot:  sudo systemctl start gsport-serial"
echo "    - For a fixed name across reboots, add a udev rule by adaptor serial#"
echo "      so it is always $DEVICE."
