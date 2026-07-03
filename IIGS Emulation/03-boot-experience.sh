#!/usr/bin/env bash
#
# 03-boot-experience.sh [vga|composite|vga-composite]
#
# Boots silently behind a solid blue screen (no rainbow splash, no Linux boot
# text) until the kiosk service starts GSport, and selects the video output.
#
#   vga            (DEFAULT) VGA via an HDMI->VGA adapter, 640x480. Rock solid.
#   composite      Composite (TRRS jack), PAL. HDMI/VGA disabled.
#   vga-composite  EXPERIMENTAL, Pi 4 only: VGA (HDMI) as primary, AND an
#                  attempt to bring composite up as a SECOND connector.
#                  config.txt/cmdline only -> fully reversible, cannot brick
#                  boot. Whether composite actually appears depends on
#                  firmware/kernel; if it doesn't, you simply get VGA (harmless).
#                  A guaranteed simultaneous route exists but needs extra
#                  hardware (DPI VGA666 hat) -- see CAVEATS.md.
#
# The blue value lives in ONE place below; it is an APPROXIMATION of the IIgs
# boot blue -- tune it against a reference photo.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

MODE="${1:-vga}"
BLUE_HEX="1B3FBF"            # <-- tune this one value
R="0.106"; G="0.247"; B="0.749"   # plymouth floats for #1B3FBF

BOOT_DIR="/boot/firmware"; [[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"
CONFIG_TXT="$BOOT_DIR/config.txt"
CMDLINE="$BOOT_DIR/cmdline.txt"
ts=$(date +%s)
cp "$CONFIG_TXT" "$CONFIG_TXT.bak.$ts"
cp "$CMDLINE"    "$CMDLINE.bak.$ts"
echo "[03] backups: *.bak.$ts"

set_kv() {
  local k="$1" v="$2"
  if grep -qE "^#?$k=" "$CONFIG_TXT"; then
    sed -i "s/^#\?$k=.*/$k=$v/" "$CONFIG_TXT"
  else
    echo "$k=$v" >> "$CONFIG_TXT"
  fi
}

# Reset any prior video state we may have written.
sed -i 's/^\(dtoverlay=vc4-kms-v3d\),composite/\1/' "$CONFIG_TXT"
sed -i 's/ vc4.tv_norm=[A-Z]*//g; s# video=Composite-1:[^ ]*##g; s# video=HDMI-A-1:[^ ]*##g' "$CMDLINE"

echo "[03] firmware: kill rainbow splash"
set_kv disable_splash 1

echo "[03] video mode: $MODE"
case "$MODE" in
  vga)
    set_kv enable_tvout 0
    set_kv hdmi_force_hotplug 1   # output even if the VGA dongle gives no EDID
    sed -i 's/$/ video=HDMI-A-1:640x480M@60/' "$CMDLINE"
    echo "  VGA-over-HDMI 640x480; use an active HDMI->VGA adapter"
    ;;
  composite)
    set_kv enable_tvout 1
    sed -i 's/^\(dtoverlay=vc4-kms-v3d\)\([^,].*\)\?$/\1,composite/' "$CONFIG_TXT"
    grep -q '^dtoverlay=vc4-kms-v3d,composite' "$CONFIG_TXT" || \
      echo 'dtoverlay=vc4-kms-v3d,composite' >> "$CONFIG_TXT"
    sed -i 's/$/ vc4.tv_norm=PAL/' "$CMDLINE"
    echo "  composite (PAL); HDMI disabled in this mode"
    ;;
  vga-composite)
    # EXPERIMENTAL: keep HDMI/VGA (no ',composite' param, which would kill HDMI)
    # and ASK for composite as an additional connector via enable_tvout + a
    # composite video= line. Reversible; if the stack refuses, you get VGA only.
    set_kv enable_tvout 1
    set_kv hdmi_force_hotplug 1
    sed -i 's/$/ video=HDMI-A-1:640x480M@60/' "$CMDLINE"
    sed -i 's/$/ video=Composite-1:720x576@50i vc4.tv_norm=PAL/' "$CMDLINE"
    cat > /opt/gsport/revert-video.sh <<EOF
#!/usr/bin/env bash
# One-shot revert to plain VGA if vga-composite misbehaves.
sudo $(readlink -f "$0") vga && echo "Reverted to VGA. Reboot."
EOF
    chmod +x /opt/gsport/revert-video.sh
    echo "  EXPERIMENTAL vga-composite set (VGA primary + composite attempt)."
    echo "  Verify with a monitor attached. Revert: /opt/gsport/revert-video.sh"
    echo "  Reliable simultaneous output needs a DPI VGA666 hat (see CAVEATS.md)."
    ;;
  *) echo "usage: $0 [vga|composite|vga-composite]" >&2; exit 2 ;;
esac

echo "[03] quiet boot + no cursor (cmdline.txt, single line)"
for f in quiet splash logo.nologo vt.global_cursor_default=0 \
         loglevel=0 consoleblank=0 plymouth.ignore-serial-consoles; do
  grep -qw -- "$f" "$CMDLINE" || sed -i "s/\$/ $f/" "$CMDLINE"
done
sed -i 's/  */ /g' "$CMDLINE"

echo "[03] install solid-blue plymouth theme 'iigsblue'"
TH=/usr/share/plymouth/themes/iigsblue
install -d "$TH"
cat > "$TH/iigsblue.plymouth" <<EOF
[Plymouth Theme]
Name=iigsblue
Description=Solid Apple IIgs-style blue
ModuleName=script
[script]
ImageDir=$TH
ScriptFile=$TH/iigsblue.script
EOF
cat > "$TH/iigsblue.script" <<EOF
Window.SetBackgroundTopColor($R, $G, $B);
Window.SetBackgroundBottomColor($R, $G, $B);
EOF

if command -v plymouth-set-default-theme >/dev/null; then
  plymouth-set-default-theme iigsblue || true
  update-initramfs -u 2>/dev/null || \
    echo "  NOTE: if plymouth doesn't appear, add 'auto_initramfs=1' to config.txt"
else
  echo "  plymouth missing? re-run 01-system-prep.sh"
fi

echo "[03] done."
