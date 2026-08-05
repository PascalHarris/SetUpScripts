#!/usr/bin/env bash
#
# 03-boot-experience.sh [vga|dpi-vga|composite|vga-composite]
#
# Boots silently behind a solid blue screen (no rainbow splash, no Linux boot
# text) until the kiosk service starts GSport, and selects the video output.
#
#   vga            (DEFAULT) VGA via an HDMI->VGA adapter, 640x480. Rock solid.
#   dpi-vga        VGA via a GPIO VGA666 (DPI) hat. TESTED on a Kiro VGA666 +
#                  Pi 4 / Bookworm. Brings up the KMS "VGA-1" connector at
#                  640x480; HDMI stays enabled as a connector. See notes below.
#   composite      Composite (TRRS jack), PAL. HDMI/VGA disabled.
#   vga-composite  EXPERIMENTAL, Pi 4 only: VGA (HDMI) as primary, AND an
#                  attempt to bring composite up as a SECOND connector.
#                  config.txt/cmdline only -> fully reversible, cannot brick
#                  boot. If the stack refuses, you simply get VGA (harmless).
#
# WHAT MADE dpi-vga WORK (all three were needed; each alone = black screen):
#   1. disable_fw_kms_setup=0  -- Bookworm defaults this to 1, which stops the
#      firmware setting up the DPI pipeline. Must be 0 for VGA666.
#   2. dtoverlay=vc4-kms-vga666 -- the correct KMS overlay for a VGA666 board
#      (legacy vga666/dpi24/dpi_mode/display_default_lcd are IGNORED under KMS).
#   3. gpio=2-21=a2  -- Pi 4 pinmux: forces GPIO 2-21 into DPI (ALT2) mode.
#   The connector is named VGA-1 (NOT DPI-1) and comes up at 640x480 with no
#   video= line needed. I2C/SPI must be off (they share GPIO 2/3 with DPI).
#
# MIRRORING REALITY: GSport draws to ONE framebuffer (/dev/fb0). VGA(DPI),
#   composite and HDMI are separate KMS connectors with incompatible modes, so
#   there is no clean simultaneous mirror -- pick ONE output; switching is a
#   one-command re-run. HDMI is a reboot-time fallback. (See CAVEATS.md.)
#
# The blue value lives in ONE place below; tune it against a reference photo.

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

# --- config.txt helpers -----------------------------------------------------
# NOTE: config.txt has conditional sections ([cm4], [cm5], [all], ...). Our
# additive lines go in a delimited block under an explicit [all] so a section
# filter can't swallow them, and so we can remove them cleanly on the next run.
MARK_BEGIN="# BEGIN iigs-video managed block"
MARK_END="# END iigs-video managed block"

# Replace-or-append a firmware key=value (edits in place if the key exists).
set_kv() {
  local k="$1" v="$2"
  if grep -qE "^#?$k=" "$CONFIG_TXT"; then
    sed -i "s/^#\?$k=.*/$k=$v/" "$CONFIG_TXT"
  else
    echo "$k=$v" >> "$CONFIG_TXT"
  fi
}

strip_block() { sed -i "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$CONFIG_TXT"; }

# write_block "<line1>\n<line2>..."  -- fresh managed [all] block at end of file
write_block() {
  { printf '\n%s\n[all]\n' "$MARK_BEGIN"
    printf '%b\n' "$1"
    printf '%s\n' "$MARK_END"; } >> "$CONFIG_TXT"
}

# --- reset any prior video state so modes switch cleanly --------------------
strip_block
sed -i 's/^\(dtoverlay=vc4-kms-v3d\),composite/\1/' "$CONFIG_TXT"
sed -i 's/^\(dtoverlay=vc4-kms-v3d\),nohdmi/\1/'    "$CONFIG_TXT"
sed -i 's/ vc4.tv_norm=[A-Z]*//g; s# video=Composite-1:[^ ]*##g; s# video=HDMI-A-1:[^ ]*##g; s# video=VGA-1:[^ ]*##g; s# video=DPI-1:[^ ]*##g' "$CMDLINE"
sed -i 's/  */ /g; s/ *$//' "$CMDLINE"

echo "[03] firmware: kill rainbow splash"
set_kv disable_splash 1

echo "[03] video mode: $MODE"
case "$MODE" in
  vga)
    set_kv disable_fw_kms_setup 1     # stock default; HDMI path is happy with it
    set_kv enable_tvout 0
    set_kv hdmi_force_hotplug 1       # output even if the VGA dongle gives no EDID
    sed -i 's/$/ video=HDMI-A-1:640x480M@60/' "$CMDLINE"
    echo "  VGA-over-HDMI 640x480; use an active HDMI->VGA adapter"
    ;;
  dpi-vga)
    # GPIO VGA666 hat (DPI) -- TESTED config. All three lines below are required.
    set_kv disable_fw_kms_setup 0     # (1) let firmware set up the DPI pipeline
    set_kv enable_tvout 0
    # I2C/SPI share GPIO 2/3 with the DPI bus -- make sure they are OFF.
    sed -i 's/^dtparam=i2c_arm=on/dtparam=i2c_arm=off/; s/^dtparam=spi=on/dtparam=spi=off/' "$CONFIG_TXT"
    # (2) overlay + (3) Pi 4 pinmux, in a managed [all] block
    write_block 'dtoverlay=vc4-kms-vga666\ngpio=2-21=a2'
    # No video= line: the VGA-1 connector comes up at 640x480 on its own.
    # HDMI left ENABLED (proven-working state); GSport (/dev/fb0) shows on VGA-1.
    echo "  VGA666 DPI hat -> connector VGA-1 @ 640x480 (HDMI left enabled)."
    echo "  Uses GPIO 2-21; I2C/SPI on those pins forced off."
    echo "  RGB666 renders as ~RGB444 on Pi 4 (mild banding) -- OK for retro."
    echo "  If a fussy VGA monitor won't sync, add: video=VGA-1:640x480@60 to cmdline.txt"
    ;;
  composite)
    set_kv disable_fw_kms_setup 1
    set_kv enable_tvout 1
    sed -i 's/^\(dtoverlay=vc4-kms-v3d\)\([^,].*\)\?$/\1,composite/' "$CONFIG_TXT"
    grep -q '^dtoverlay=vc4-kms-v3d,composite' "$CONFIG_TXT" || \
      echo 'dtoverlay=vc4-kms-v3d,composite' >> "$CONFIG_TXT"
    sed -i 's/$/ vc4.tv_norm=PAL/' "$CMDLINE"
    echo "  composite (PAL); HDMI disabled in this mode"
    ;;
  vga-composite)
    # EXPERIMENTAL: keep HDMI/VGA and ASK for composite as an additional
    # connector. Reversible; if the stack refuses, you get VGA only.
    set_kv disable_fw_kms_setup 1
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
    ;;
  *) echo "usage: $0 [vga|dpi-vga|composite|vga-composite]" >&2; exit 2 ;;
esac

echo "[03] quiet boot + no cursor (cmdline.txt, single line)"
for f in quiet splash logo.nologo vt.global_cursor_default=0 \
         loglevel=0 consoleblank=0 plymouth.ignore-serial-consoles; do
  grep -qw -- "$f" "$CMDLINE" || sed -i "s/\$/ $f/" "$CMDLINE"
done
sed -i 's/  */ /g' "$CMDLINE"

# --- verify the video config physically landed (lesson learned!) ------------
echo "[03] verify -- these lines are now in $CONFIG_TXT / $CMDLINE:"
grep -nE 'disable_fw_kms_setup|enable_tvout|hdmi_force_hotplug|dtoverlay=vc4-kms|gpio=2-21' "$CONFIG_TXT" \
  | sed 's/^/    config.txt:/'
echo "    cmdline.txt: $(cat "$CMDLINE")"
echo "    (reboot, then check: for c in /sys/class/drm/card*-*; do echo \$c \$(cat \$c/status); done)"

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
