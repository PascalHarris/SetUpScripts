#!/usr/bin/env bash
#
# 06-keyboard-remap.sh
#
# Sets up a compact ADB keyboard (via a Griffin iMate USB-ADB adapter, or any
# plain HID keyboard) for authentic Apple IIgs use under GSport, using keyd.
# keyd remaps at the kernel evdev layer -- BELOW GSport -- so it works on the
# bare framebuffer kiosk with no X/Wayland.
#
# What it configures:
#   * Command <-> Option swap, so GSport sees Open-Apple / Option the right way.
#   * A Delete-key fix (compact keyboards send Backspace; GSport's framebuffer
#     driver has a keymap bug that turns Backspace into Left-Arrow -- see note).
#   * Command+Shift+<number row>  ->  F1..F12   (no function keys on the board).
#   * Ctrl+Command+Delete         ->  emulated IIgs reset (soft, in-emulator).
#   * Ctrl+Command+Shift+Delete   ->  HARD restart of the whole emulator process
#                                     (deliberately harder to reach = more
#                                     destructive; needs the kiosk service).
#
# Re-runnable: backs up any existing /etc/keyd/default.conf first.

set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Run as root (sudo)." >&2; exit 1; }

KIOSK_SVC="gsport-kiosk.service"    # matches 04-kiosk-service.sh
CONF=/etc/keyd/default.conf

# --- 1. install keyd (apt if available, else build from source) --------------
need_build=0
if ! command -v keyd >/dev/null 2>&1; then
  echo "[06] installing keyd"
  apt-get update -qq || true
  apt-get install -y keyd 2>/dev/null || need_build=1
  command -v keyd >/dev/null 2>&1 || need_build=1
  if [[ "$need_build" == 1 ]]; then
    echo "[06] keyd not packaged here -- building from source"
    apt-get install -y build-essential git
    d=$(mktemp -d)
    git clone --depth 1 https://github.com/rvaiya/keyd "$d/keyd"
    make -C "$d/keyd"
    make -C "$d/keyd" install
    rm -rf "$d"
  fi
else
  echo "[06] keyd already present"
fi

# --- 2. write the config -----------------------------------------------------
install -d /etc/keyd
if [[ -f "$CONF" ]]; then
  cp "$CONF" "$CONF.bak.$(date +%s)"
  echo "[06] backed up existing config"
fi

cat > "$CONF" <<'EOF'
# /etc/keyd/default.conf  -- Apple IIgs (GSport) keyboard, managed by 06-keyboard-remap.sh

[ids]
# All keyboards. For a single dedicated board, replace * with its vendor:product
# (shown by `keyd monitor` when you plug it in) so nothing else is remapped.
*

[main]
# Command <-> Option swap: on a Mac ADB keyboard these read "back to front" to
# GSport; swapping makes physical Command act as IIgs Open-Apple and physical
# Option act as IIgs Option.
leftmeta = leftalt
leftalt  = leftmeta
# Uncomment if your keyboard has RIGHT-hand Command/Option keys too:
# rightmeta = rightalt
# rightalt  = rightmeta

# Delete-key fix. Compact keyboards emit Backspace, but GSport's framebuffer
# driver maps Backspace to the IIgs Left-Arrow (0x3B) instead of Delete (0x33)
# -- a bug in fbdriver.c (the X11 driver is correct). Emitting KEY_DELETE makes
# GSport produce the IIgs Delete (0x33), i.e. a real destructive backspace.
# This is also patched at source in 02-build-gsport.sh; the line is harmless if
# the binary is already fixed, so it is safe to keep either way.
backspace = delete

# Command+Shift+<number row> -> F1..F12. After the swap, physical Command is the
# 'alt' modifier, so the trigger layer is alt+shift. Explicit bindings in a
# composite layer emit the BARE key (the alt/shift are consumed), so GSport gets
# a clean F4 etc., not Alt-Shift-F4.
[alt+shift]
1 = f1
2 = f2
3 = f3
4 = f4
5 = f5
6 = f6
7 = f7
8 = f8
9 = f9
0 = f10
minus = f11
equal = f12

# Ctrl+Command+Delete -> emulated IIgs reset. GSport reads this as
# Ctrl + Open-Apple(alt) + Reset(F12) held together = the in-emulator reset.
# (Composite layers must be defined AFTER the layers they combine.)
[control+alt]
backspace = C-A-f12

# Ctrl+Command+SHIFT+Delete -> hard restart of the emulator PROCESS (fresh IIgs,
# bypasses any in-emulator reset hang). The extra Shift makes the nuclear option
# deliberately harder to reach. Needs GSport running under the kiosk service,
# which has Restart=always. If you also want this to work while launching GSport
# by hand, use instead:  backspace = command(pkill -x gsportfb)
[control+alt+shift]
backspace = command(systemctl restart gsport-kiosk.service)
EOF

# keyd runs command() actions as root; the systemctl line above needs that.

# --- 3. enable + load --------------------------------------------------------
systemctl enable --now keyd
keyd reload 2>/dev/null || systemctl restart keyd

echo "[06] verify config parsed cleanly:"
if journalctl -u keyd -n 20 --no-pager 2>/dev/null | grep -qiE 'error|failed|invalid'; then
  echo "  WARNING: keyd logged an error -- check: journalctl -eu keyd"
else
  echo "  no parse errors logged."
fi

cat <<'NOTE'

[06] done. Test WITHOUT rebooting:
  sudo keyd monitor      # shows post-remap output
    - press Command            -> expect 'leftalt' (swap)
    - Command+Shift+4          -> expect a bare 'f4'
    - press Delete             -> expect 'delete' (was sending left-arrow)
  Then in GSport:
    - Command+Shift+4          -> F4 config menu
    - Delete                   -> deletes the character to the left
    - Ctrl+Command+Delete      -> emulated reset
    - Ctrl+Command+Shift+Del   -> emulator relaunches (needs the kiosk service;
                                  confirm with: journalctl -u gsport-kiosk -f)
NOTE
