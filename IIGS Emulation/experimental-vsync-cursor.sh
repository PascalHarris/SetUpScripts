#!/usr/bin/env bash
#
# experimental-vsync-cursor.sh   (EXPERIMENTAL - unproven)
#
# Builds a gsportfb binary with a once-per-frame vsync added to the framebuffer
# blit path (fbdriver.c), to try to reduce the moving-mouse-cursor shimmer that
# comes from GSport writing the screen straight into the live framebuffer with
# no vertical-blank sync.
#
# THIS SCRIPT ONLY PRODUCES A BINARY.
#   - It does NOT install or deploy anything.
#   - It never touches /opt/gsport, the kiosk service, disk images, or any config.
#   - Your running emulator is unaffected until YOU choose to swap the binary in.
#
# See  experimental-vsync-cursor.md  for how to test, deploy, and revert.
#
# Usage:  ./experimental-vsync-cursor.sh [staging-dir]
#         default staging dir: ~/gsport-vsync-build
# No root required (it only clones + compiles into your home dir).

set -euo pipefail
REPO="https://github.com/david-schmidt/gsport.git"
STAGE="${1:-$HOME/gsport-vsync-build}"
RESULT="$STAGE/gsportfb.vsync"

command -v git  >/dev/null || { echo "need git  (run 01-system-prep.sh first)"        >&2; exit 1; }
command -v make >/dev/null || { echo "need make/build tools (run 01-system-prep.sh)"  >&2; exit 1; }

echo "[vsync] clean staging dir: $STAGE"
rm -rf "$STAGE"
git clone --depth 1 "$REPO" "$STAGE"
cd "$STAGE/src"

# --- build fixes, identical to 02-build-gsport.sh (so it compiles on the Pi) ---
VARS=vars_fbrpilinux
sed -i 's/\r$//' "$VARS"
case "$(uname -m)" in
  aarch64) sed -i 's/-march=armv6//g; s/-m32//g' "$VARS" ;;
  armv7l)  sed -i 's/-march=armv6/-march=armv7-a/g' "$VARS" ;;
  armv6l)  : ;;
  *)       echo "  [vsync] unexpected arch $(uname -m); leaving -march untouched" ;;
esac
grep -qE '^EXTRA_LIBS\b.*-lpcap' "$VARS" || sed -i 's/^\(EXTRA_LIBS *=.*\)$/\1 -lpcap/' "$VARS"

# --- the experimental patch: fbdriver.c ONLY -------------------------------
# Waits for one vertical blank before the first region blit of each frame, so the
# (small, cursor-sized) writes land during blank instead of mid-scanout. Reset in
# x_push_done() so it re-arms every frame. FBIO_WAITFORVSYNC = 0x40044620.
echo "[vsync] patching fbdriver.c"
sed -i 's/\r$//' fbdriver.c
cp fbdriver.c fbdriver.c.orig
awk '
/#include "defc.h"/ { print; print "#include <sys/ioctl.h>"; print "#ifndef FBIO_WAITFORVSYNC"; print "#define FBIO_WAITFORVSYNC _IOW(0x46, 0x20, unsigned int)"; print "#endif"; print "static int g_fb_vsync_done = 0;  /* EXPERIMENTAL vsync */"; next }
/Copy sub-image to framebuffer/ { print "    if (!g_fb_vsync_done) {  /* EXPERIMENTAL: wait for vblank once per frame */"; print "        unsigned int vs_arg = 0;"; print "        ioctl(fbfd, FBIO_WAITFORVSYNC, &vs_arg);"; print "        g_fb_vsync_done = 1;"; print "    }"; print; next }
/void x_push_done\(void\)$/ { in_pd=1 }
in_pd && /^}/ { print "    g_fb_vsync_done = 0;  /* EXPERIMENTAL: re-arm for next frame */"; in_pd=0 }
{ print }
' fbdriver.c.orig > fbdriver.c

# fail loudly if upstream layout changed and the patch missed its anchors
if ! grep -q 'FBIO_WAITFORVSYNC' fbdriver.c || [ "$(grep -c g_fb_vsync_done fbdriver.c)" -lt 3 ]; then
  echo "[vsync] ERROR: patch did not apply (source layout changed?). Nothing built." >&2
  exit 1
fi
echo "[vsync] patch applied."

# --- build the framebuffer binary the same way 02 does ---------------------
echo "[vsync] building gsportfb ..."
rm -f vars && ln -s "$VARS" vars
make clean >/dev/null 2>&1 || true
make
test -f "$STAGE/gsportfb" || { echo "[vsync] ERROR: build produced no gsportfb" >&2; exit 1; }

cp "$STAGE/gsportfb" "$RESULT"
echo ""
echo "[vsync] SUCCESS - experimental binary built (NOT installed):"
echo "    $RESULT"
echo ""
echo "Nothing on your system changed. To try it, follow experimental-vsync-cursor.md"
echo "(back up /opt/gsport/gsportfb first, and re-apply setcap after swapping)."
