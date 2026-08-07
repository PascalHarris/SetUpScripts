# Experimental vsync cursor build

`experimental-vsync-cursor.sh` produces **one binary** and installs nothing:

    ~/gsport-vsync-build/gsportfb.vsync

This document is what to do with it. Your live `/opt/gsport/gsportfb` is untouched
until you deliberately swap it in below, and every step is reversible.

## What it changes (and the honest odds)

GSport's framebuffer driver writes the emulated screen straight into the live
framebuffer with no vertical-blank sync and no back buffer. When the mouse moves,
GS/OS erases and redraws the pointer, and the display can catch that mid-write —
the shimmer you see. The patch waits for one vblank before each frame's writes
(in `fbdriver.c`, `FBIO_WAITFORVSYNC`), so the small cursor-sized writes land
during blank instead of mid-scanout.

Two honest caveats, unchanged from when we discussed it:

1. **It may do nothing.** Under the full-KMS `vc4drmfb` emulation, the legacy
   `FBIO_WAITFORVSYNC` ioctl may not be implemented. If it isn't, the call is a
   harmless no-op and the shimmer stays — the binary still runs fine, it just
   won't have helped.
2. **Timing.** Blocking each frame on vblank could in theory nudge emulation
   pacing. At 60 Hz it should be imperceptible, but it's untested on your box.

Nothing else about the emulator changes.

## 1. Build it

    ./experimental-vsync-cursor.sh
    # -> ~/gsport-vsync-build/gsportfb.vsync   (no root needed)

Requires the build tools from `01-system-prep.sh` / `02-build-gsport.sh` to be
installed already (git, make, libpcap-dev). It clones a fresh GSport, applies the
same Pi build fixes as script 02 plus the vsync patch, and compiles — touching
nothing outside the staging dir.

## 2. Try it (reversible)

Back up the live binary, swap in the experimental one, re-apply the raw-socket
capability (a fresh binary loses it — without it AppleTalk and Uthernet break),
and restart:

    sudo cp -a /opt/gsport/gsportfb /opt/gsport/gsportfb.stock      # backup
    sudo install -m 0755 ~/gsport-vsync-build/gsportfb.vsync /opt/gsport/gsportfb
    sudo setcap cap_net_raw,cap_net_admin+eip /opt/gsport/gsportfb  # re-apply
    sudo chown pi:pi /opt/gsport/gsportfb                           # match your user

    # if you run under the kiosk service:
    sudo systemctl restart gsport-kiosk.service
    # if you run by hand:
    sudo /opt/gsport/gsportfb

Then move the mouse and watch the pointer.

- **Shimmer clearly reduced, everything else normal** -> keep it (section 3).
- **No change** -> the ioctl isn't honoured here; revert (section 4). Expected on
  some KMS builds; not worth pursuing further.
- **Anything worse** (stutter, slower feel, artefacts) -> revert (section 4).

Confirm networking still works after the swap (mount the AppleShare server, or a
BBS) — that verifies the `setcap` re-applied correctly.

## 3. Keep it

If it helps and you're happy, the swapped-in binary is already in place — you're
done. But note: **the next run of `02-build-gsport.sh` will overwrite it** with a
stock (un-patched) rebuild. To make the fix survive rebuilds, the patch has to
live in script 02. Ask and I'll fold the same `fbdriver.c` patch into
`02-build-gsport.sh`, gated behind a clear flag, so every future build includes
it. Until then, treat this binary as a manual override.

## 4. Revert

    sudo cp -a /opt/gsport/gsportfb.stock /opt/gsport/gsportfb
    sudo setcap cap_net_raw,cap_net_admin+eip /opt/gsport/gsportfb
    sudo chown pi:pi /opt/gsport/gsportfb
    sudo systemctl restart gsport-kiosk.service   # or relaunch by hand

You're back to the stock binary exactly as before. The staging dir under your
home can be deleted at any time (`rm -rf ~/gsport-vsync-build`); it holds only the
build tree and the experimental binary.
