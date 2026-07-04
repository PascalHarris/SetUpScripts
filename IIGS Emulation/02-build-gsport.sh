#!/usr/bin/env bash
#
# 02-build-gsport.sh
# Clone, patch and build GSport's Raspberry Pi FRAMEBUFFER target with
# Uthernet (TFE) + AppleTalk (atbridge) enabled, then install it.
#
# Two fixes to the shipped vars_fbrpilinux are required and applied here:
#   (a) it targets -march=armv6 (Pi 1/Zero); corrected for the running CPU
#   (b) it omits -lpcap, so the TFE/atbridge networking code would fail to
#       link. We add it.
#
# This build approach (TFE + atbridge + -lpcap) was verified to compile and
# link against libpcap from this exact source. The ARM arch substitution
# should be confirmed on your specific Pi/OS (32- vs 64-bit).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

SRC=/opt/gsport/build
REPO=https://github.com/david-schmidt/gsport.git
DEST=/opt/gsport

echo "[02] fetch source"
rm -rf "$SRC"
git clone --depth 1 "$REPO" "$SRC"
cd "$SRC/src"

VARS=vars_fbrpilinux
# Normalise CRLF so our sed patterns match reliably.
sed -i 's/\r$//' "$VARS"

echo "[02] select correct -march for $(uname -m)"
case "$(uname -m)" in
  aarch64)
    # 64-bit Pi OS: drop the armv6/-m32 assumptions; let gcc default for the arch.
    sed -i 's/-march=armv6//g; s/-m32//g' "$VARS" ;;
  armv7l)
    sed -i 's/-march=armv6/-march=armv7-a/g' "$VARS" ;;
  armv6l)
    : ;;  # Pi 1 / Zero: shipped value is correct
  *)
    echo "  unexpected arch; leaving -march untouched" ;;
esac

echo "[02] add -lpcap so Uthernet/AppleTalk link"
# EXTRA_LIBS as shipped is '-ldl'; append -lpcap if absent.
if ! grep -qE '^EXTRA_LIBS\b.*-lpcap' "$VARS"; then
  sed -i 's/^\(EXTRA_LIBS *=.*\)$/\1 -lpcap/' "$VARS"
fi
echo "  EXTRA_LIBS -> $(grep '^EXTRA_LIBS' "$VARS")"
echo "  CCOPTS     -> $(grep '^CCOPTS'     "$VARS")"

echo "[02] build framebuffer target (gsportfb)"
rm -f vars && ln -s "$VARS" vars
make clean >/dev/null 2>&1 || true
make
# Makefile moves the binary one level up (to $SRC).
test -f "$SRC/gsportfb"

echo "[02] also build X11 fallback (gsportx) in case /dev/fb0 is unavailable"
# Build with a native X11 vars derived from vars_x86linux (arch-neutral).
sed -i 's/\r$//' vars_x86linux
cp vars_x86linux vars_native_x
sed -i 's/-m32//g; s/-march=i686//g' vars_native_x
grep -qE '^EXTRA_LIBS\b.*-lpcap' vars_native_x || \
  sed -i 's/^\(EXTRA_LIBS *=.*\)$/\1 -lpcap/' vars_native_x
rm -f vars && ln -s vars_native_x vars
make clean >/dev/null 2>&1 || true
make || echo "  (X11 fallback build failed; framebuffer build is what matters)"

echo "[02] install binaries + support files"
install -m 0755 "$SRC/gsportfb" "$DEST/gsportfb"
[[ -f "$SRC/gsportx" ]] && install -m 0755 "$SRC/gsportx" "$DEST/gsportx" || true
# GSport needs parallel.rom next to it (ImageWriter emulation) and a boot image.
install -m 0644 "$SRC/src/parallel.rom" "$DEST/parallel.rom" 2>/dev/null || true
[[ -f "$SRC/lib/NoBoot.po" ]] && install -m 0644 "$SRC/lib/NoBoot.po" "$DEST/NoBoot.po" || true

echo "[02] grant raw-socket capability (Uthernet/AppleTalk promiscuous, no root)"
setcap cap_net_raw,cap_net_admin+eip "$DEST/gsportfb" || \
  echo "  setcap failed; the kiosk service runs on tty1 and can fall back to root"

# Re-assert login-user ownership (files above were installed as root).
# Binary stays 0755 and root-runnable via systemd; owner just lets you replace it.
OWNER="${SUDO_USER:-pi}"
chown -R "$OWNER":"$OWNER" "$DEST"
echo "[02] $DEST owned by $OWNER"

echo "[02] done. Sanity-check per README, then put your ROM03 at /opt/gsport/ROM."
