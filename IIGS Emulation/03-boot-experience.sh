#!/usr/bin/env bash
#
# 03-boot-experience.sh [dpi-vga|vga]
#
# Blue boot splash + quiet boot, and pins the video output to 640x480.
#
#   dpi-vga  (DEFAULT) GPIO VGA666 hat. Ensures the vc4-kms-vga666 overlay + the
#            gpio=2-21=a2 pinmux are present (adds them only if missing), and pins
#            the KMS "VGA-1" connector to 640x480 (it defaults to 1024x768).
#   vga      HDMI->VGA adapter path, pins "HDMI-A-1" to 640x480.
#
# DESIGN NOTE (learned the hard way): this script is deliberately MINIMAL and
# ADDITIVE. It does NOT rewrite your config.txt structure, does NOT touch
# disable_fw_kms_setup, and does NOT change the console= setting. An earlier
# version did all three and blacked out the display; those behaviours are gone.
# The only file it changes structurally is cmdline.txt (the video= pin), plus
# adding the two overlay lines to config.txt if (and only if) they are absent.
#
# Composite / vga-composite modes were removed from this rebuild -- they required
# the risky config.txt rewriting. They can be re-added and tested separately.
#
# Always run with a way to roll back: it backs up both files first, and the
# reset only ever touches cmdline video= tokens.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

MODE="${1:-dpi-vga}"
R="0.106"; G="0.247"; B="0.749"   # plymouth floats for #1B3FBF (blue)

BOOT_DIR="/boot/firmware"; [[ -d "$BOOT_DIR" ]] || BOOT_DIR="/boot"
CONFIG_TXT="$BOOT_DIR/config.txt"
CMDLINE="$BOOT_DIR/cmdline.txt"
ts=$(date +%s)
cp "$CONFIG_TXT" "$CONFIG_TXT.bak.$ts"
cp "$CMDLINE"    "$CMDLINE.bak.$ts"
echo "[03] backups: *.bak.$ts   (roll back: cp those over config.txt/cmdline.txt)"

echo "[03] video mode: $MODE"
case "$MODE" in
  dpi-vga)
    # Ensure overlay + pinmux exist -- ADD ONLY IF MISSING; never reorganise.
    if ! grep -q '^dtoverlay=vc4-kms-vga666' "$CONFIG_TXT"; then
      printf '\n[all]\n# VGA666 DPI hat\ndtoverlay=vc4-kms-vga666\ngpio=2-21=a2\n' >> "$CONFIG_TXT"
      echo "  added vc4-kms-vga666 + gpio=2-21=a2 (were missing)"
    else
      grep -q '^gpio=2-21=a2' "$CONFIG_TXT" || echo 'gpio=2-21=a2' >> "$CONFIG_TXT"
      echo "  overlay already present -- config.txt left untouched"
    fi
    # Pin VGA-1 to 640x480 (defaults to 1024x768). Drop any stale VGA-1 / inert HDMI pin.
    sed -i 's# video=VGA-1:[^ ]*##g; s# video=HDMI-A-1:[^ ]*##g' "$CMDLINE"
    sed -i 's/$/ video=VGA-1:640x480@60/' "$CMDLINE"
    echo "  VGA-1 pinned to 640x480"
    ;;
  vga)
    # HDMI->VGA adapter. Does NOT remove the VGA666 overlay if present -- to make
    # HDMI the sole output, delete the vga666/gpio lines from config.txt by hand.
    sed -i 's# video=HDMI-A-1:[^ ]*##g; s# video=VGA-1:[^ ]*##g' "$CMDLINE"
    sed -i 's/$/ video=HDMI-A-1:640x480@60/' "$CMDLINE"
    echo "  HDMI-A-1 pinned to 640x480 (use an active HDMI->VGA adapter)"
    ;;
  *) echo "usage: $0 [dpi-vga|vga]" >&2; exit 2 ;;
esac

echo "[03] quiet boot (additive; console left as-is)"
for f in quiet splash logo.nologo vt.global_cursor_default=0 \
         loglevel=0 consoleblank=0 plymouth.ignore-serial-consoles; do
  grep -qw -- "$f" "$CMDLINE" || sed -i "s/\$/ $f/" "$CMDLINE"
done
sed -i 's/  */ /g; s/ *$//' "$CMDLINE"

echo "[03] verify -- confirm BEFORE rebooting:"
echo "    cmdline: $(cat "$CMDLINE")"
echo "    config vga666: $(grep -c '^dtoverlay=vc4-kms-vga666' "$CONFIG_TXT") line(s)"
echo "    (after reboot: cat /sys/class/graphics/fb0/virtual_size  -> want 640,480)"

echo "[03] install/refresh solid-blue plymouth theme 'iigsblue'"
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
  update-initramfs -u 2>/dev/null || true
fi

echo "[03] done. Reboot, then check fb0/virtual_size is 640,480."
