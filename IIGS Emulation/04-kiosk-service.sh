#!/usr/bin/env bash
#
# 04-kiosk-service.sh
# Installs a systemd service that launches GSport on the console at boot and
# restarts it if it exits. It retains the blue plymouth splash on the
# framebuffer right up until GSport draws over it (no black flash, no console).
#
# Runs as root for reliable access to /dev/fb0, /dev/tty1 and /dev/input/*.
# A non-root alternative (groups video+input + setcap) is noted in comments.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

DEST=/opt/gsport
BIN="$DEST/gsportfb"
test -x "$BIN" || { echo "missing $BIN; run 02-build-gsport.sh first" >&2; exit 1; }

# Install starter config if none present (does not overwrite an existing one).
if [[ ! -f "$DEST/config.txt" && -f "$(dirname "$0")/gsport.config.txt" ]]; then
  install -m 0644 "$(dirname "$0")/gsport.config.txt" "$DEST/config.txt"
fi

echo "[04] disable getty on tty1 (the kiosk owns the console)"
systemctl disable --now getty@tty1.service 2>/dev/null || true

echo "[04] write /etc/systemd/system/gsport-kiosk.service"
cat > /etc/systemd/system/gsport-kiosk.service <<EOF
[Unit]
Description=Apple IIgs (GSport) kiosk
After=multi-user.target systemd-user-sessions.service
Conflicts=getty@tty1.service

[Service]
Type=simple
WorkingDirectory=$DEST
# Wait briefly for the framebuffer, then hand the blue splash over to GSport.
ExecStartPre=/bin/sh -c 'for i in \$(seq 1 20); do [ -e /dev/fb0 ] && break; sleep 0.5; done'
ExecStartPre=-/sbin/modprobe snd_pcm_oss
ExecStartPre=-/usr/bin/plymouth quit --retain-splash
ExecStart=$BIN
Restart=always
RestartSec=2
# Bind to the physical console.
StandardInput=tty
StandardOutput=journal
StandardError=journal
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
User=root
# Non-root alternative: User=pi with 'usermod -aG video,input,tty pi' and the
# cap_net_raw setcap from 02-build-gsport.sh. Root is used here for simplicity.

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable gsport-kiosk.service

echo "[04] done."
echo "    - Put ROM03 at $DEST/ROM and disk images in $DEST/images"
echo "    - Reboot: sudo reboot"
echo "    - Console: F4 = GSport config (ROM, RAM, ZipGS speed, Ethernet/AppleTalk)"
echo "    - SSH remains available for all other configuration."
