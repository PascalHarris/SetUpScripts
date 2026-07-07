# Raspberry Pi -> Apple IIgs (GSport, framebuffer kiosk, networked)

Turns a bare **Raspberry Pi 4 (8GB is fine; any RAM is plenty)** running
**Raspberry Pi OS Lite (64-bit)** into an Apple IIgs that boots straight into
the emulator behind a blue screen, with VGA output, Uthernet (TCP/IP for BBSs
via Marinetti), AppleTalk (EtherTalk bridging to an AppleShare server), analog
sound, and an optional USB RS232 serial bridge.

Emulator: **GSport** (david-schmidt fork) -- the only buildable IIgs emulator
that still has BOTH Uthernet AND AppleTalk, plus a native Linux **framebuffer**
driver (no X11/desktop), ideal for a kiosk. Its Uthernet (TFE) + AppleTalk
(atbridge) core was compiled from source and verified to link libpcap and
contain the bridge symbols. The build script fixes the shipped Pi vars file
(ARM arch flag + missing -lpcap).

---

## What works / partial / dropped

FULLY: max RAM (14MB) + ZipGS accel; analog sound (OSS shim -> 3.5mm jack);
VGA (HDMI->VGA), 640x480 -- the primary output; BBS over IP (Uthernet +
Marinetti, wired only); blue boot screen; USB RS232 via socat bridge
(simultaneous with Ethernet); SSH.

PARTIAL: AppleTalk (LocalTalk->EtherTalk; needs ROM03 + a Netatalk 2.x /
A2SERVER AppleShare server; wired only). Simultaneous VGA + composite (VGA is
solid; composite-at-once is experimental/reversible on Pi 4, or a DPI VGA666
hat for guaranteed simultaneity -- see CAVEATS.md).

DROPPED (per request): reading physical floppy drives. GSport mounts image
files only; you still mount .po/.2mg/.woz images you already have via the disk
slots in gsport.config.txt.

Host-folder sharing (e.g. /home/pi/shared) is not a GSport feature; share it
over AppleTalk from a Netatalk 2.x server on the Pi, or sync a ProDOS image.
See CAVEATS.md.

---

## Ownership / permissions

01 and 02 `chown -R` the whole `/opt/gsport` tree to your login user (via
`$SUDO_USER`), so you can drop in the ROM, disk images and edit config over SSH
without sudo. The kiosk runs as **root**, so it reads everything regardless of
owner. One nuance: saving settings from the F4 menu rewrites `config.txt` as
root, so that one file can flip back to root-owned; re-run
`sudo chown $USER /opt/gsport/config.txt` if you want to edit it afterwards, or
run the kiosk as your user (the non-root option in 04-kiosk-service.sh).

If you truly want everything world-writable (single-user box, not critical):
`sudo chmod -R a+rwX /opt/gsport` -- note `+rw` alone drops dir-traverse under
the default umask (use `a+rwX`), and it is not sticky (files created later, e.g.
gsport.log, follow the creating umask, so you would re-run it periodically). The
`gsportfb` binary runs as root, so leaving it world-writable is the one real
escalation risk; user-owned 0755 is the sensible default the scripts set.

---

## Requirements you supply

1. A IIgs **ROM03** you legally own, as the FILE `/opt/gsport/ROM` (256KB;
   see the ROM section below). AppleTalk requires ROM03 specifically.
2. **Wired Ethernet**, the only active interface (01 disables onboard WiFi).
3. For VGA: an active **HDMI->VGA adapter**. For RS232: a **USB RS232 adaptor**.

---

## Run order (on the Pi, over SSH)

```sh
chmod +x *.sh
sudo ./01-system-prep.sh                 # packages, ssh, OSS+analog audio, wifi off, ownership
sudo ./02-build-gsport.sh                # build GSport fb (Uthernet+AppleTalk), setcap
#  --> SANITY CHECK (below) before continuing
sudo ./03-boot-experience.sh vga         # blue boot + VGA  (or: composite | vga-composite)
sudo ./04-kiosk-service.sh               # launch GSport on tty1 at boot
sudo ./05-serial-bridge.sh /dev/ttyUSB0 9600 6502   # OPTIONAL USB RS232 bridge
# copy ROM03 to /opt/gsport/ROM, copy disk images to /opt/gsport/images
sudo reboot
```

After reboot: blue screen -> GSport. SSH stays available throughout. Press
**F4** on the console for the GSport config menu.

---

## Sanity check after step 02 (confirm GSport works before kiosk/boot changes)

Two parts. The inspection checks run fine over SSH; the launch test must be done
**at the Pi with a monitor + USB keyboard attached**, because the framebuffer
driver draws to the physical console (/dev/fb0) and reads the physical keyboard,
not your SSH session.

At this point step 03 has NOT run, so the Pi is at its stock **HDMI** output --
use an ordinary HDMI monitor for the test.

1) Build inspection (over SSH is fine):
```sh
ls -l /opt/gsport/gsportfb                          # binary exists, executable
ldd /opt/gsport/gsportfb | grep -Ei 'pcap|not found'  # libpcap present; nothing "not found"
getcap /opt/gsport/gsportfb                          # cap_net_raw...+eip is set
```

2) Launch test (at the console; put your ROM at /opt/gsport/ROM first):
```sh
cd /opt/gsport
./gsportfb            # sudo only if you skipped the setcap/ownership step
```
You should see the Apple IIgs self-test / boot screen on the HDMI monitor.
If it doesn't appear, read the logs it writes in that directory:
```sh
cat /opt/gsport/gsport.err /opt/gsport/gsport.log
```
Quit it cleanly from a second SSH session:
```sh
sudo pkill gsportfb
```
Common causes if it exits immediately: no ROM at /opt/gsport/ROM, or a ROM whose
size isn't exactly 131072 (ROM01) or 262144 (ROM03) bytes.

---

## Does step 03 stop GSport showing on an HDMI monitor?

Depends on the mode you pass to `03-boot-experience.sh`:

- `vga` (default): the framebuffer is driven out the **HDMI port** at 640x480.
  A normal HDMI monitor works directly -- the HDMI->VGA adapter is only what
  converts that same signal to VGA, it is optional for testing. **GSport runs on
  HDMI. Not blocked.**
- `vga-composite`: HDMI/VGA remains the primary output, composite is the
  experimental extra. **HDMI monitor works. Not blocked.**
- `composite`: this adds `dtoverlay=vc4-kms-v3d,composite`, and that overlay
  parameter **disables HDMI entirely** on the Pi. An HDMI monitor will show
  nothing -- only the composite (TRRS) output is live. **This mode DOES block
  HDMI.** Switch back with `sudo ./03-boot-experience.sh vga` (+ reboot) or the
  generated `/opt/gsport/revert-video.sh`.

So: keep an HDMI monitor for setup/testing (default and vga/vga-composite modes
all use it); only the pure `composite` mode turns HDMI off.

---

## AppleTalk / AppleShare file sharing (connecting to a Netatalk server)

There is no "Chooser" on the IIgs — server mounting lives in the **graphical**
Control Panel's **AppleShare** icon. Getting there involves both sides:

GSport (host) side — F4 -> Ethernet Card Configuration:
- **AppleTalk Bridging = On**, and **Use Interface Number** = your `eth0` (the
  screen prints an "Interface List:" with the numbers).
- **AppleTalk Network Hint** = the server's AppleTalk net number (see below).
  This lives under developer settings; it is easier to set in `config.txt` as
  `g_appletalk_network_hint = <n>` than to scroll the menu.

IIgs (guest) side — boot GS/OS (the System 6.0.4 disk), then:
- Control Panel (text, Ctrl-Open-Apple-Esc) -> **Slots** -> **Slot 1 = AppleTalk**.
  On ROM03 it is slot 1, NOT slot 7 (slot 7 is greyed out — that is the ROM01
  location). Restart.
- Install the networking software if absent: GS/OS Installer -> Customize ->
  **"Network: AppleShare"**. Without it there is no AppleShare control panel
  (you may see AFP Mounter, which errors that AppleTalk components are missing).
- Apple menu -> **Control Panel** (graphical) -> **AppleShare** icon -> pick the
  server -> **log in as Guest first** (stock 6.0.1 has a cleartext-password bug).

The network number: the GSport bridge cannot use a router-less AppleTalk network
(it never learns a net number and directed sessions fail with "No response from
the server" even though the server is visible). The server must run as a **seed
router** with a fixed net number, and the hint must match it. Full server steps,
with rollback, are in **`netatalk-server-setup.md`**.

## Telnet to BBSs (TCP/IP via Marinetti + Uthernet)

Runs at the same time as AppleTalk with no conflict — Uthernet is slot 3, TCP/IP
is a separate stack from AppleTalk (slot 1). Turn the card on with
`g_ethernet = 1` (already set) or F4 -> Uthernet Card in Slot 3 = On, then on the
IIgs install Marinetti 3.0b11 and telnet with Spectrum or ANSITerm.

The one trap: GSport emulates the CS8900A = **Uthernet I**, so you must use the
**Uthernet (I)** Marinetti link layer, NOT Uthernet II — and set its slot to 3.
Full steps, with rollback, in **`marinetti-bbs-setup.md`**.

## Files

- `01-system-prep.sh`    packages, ssh, OSS+analog audio, wifi off, dirs, ownership
- `02-build-gsport.sh`   clone GSport, patch fb vars (arch + libpcap), build, setcap, ownership
- `03-boot-experience.sh [vga|composite|vga-composite]` boot splash + video mode
- `04-kiosk-service.sh`  systemd unit: GSport on the console at boot
- `05-serial-bridge.sh`  socat bridge: USB RS232 <-> GSport TCP serial port
- `gsport.config.txt`    starter config (disk slots; RAM/accel; AppleTalk+Uthernet keys)
- `netatalk-server-setup.md`  server-side seed-router + UAM config, with rollback
- `marinetti-bbs-setup.md`    TCP/IP for BBSs (Marinetti + Uthernet I), with rollback

See `CAVEATS.md` for honest limits and the experimental/source-patch items.

---

## ROM (must be ROM 03 = 256KB)

GSport detects the ROM purely by file size: 131072 bytes -> ROM 01, 262144
bytes -> ROM 03. Anything else is rejected. There is no ROM 4 / Mark Twain
support -- a 256KB Mark Twain image would be misdetected as ROM 03 and patched
at the wrong addresses, so it won't boot. AppleTalk needs ROM 03.

Assemble a ROM 03 from two 128KB chip halves (FC-FD half first), or use a
ready 256KB image, then:
```sh
cat "..._Banks_FC-FD_..." "..._Banks_FF-FE_..." > /opt/gsport/ROM   # if assembling
stat -c %s /opt/gsport/ROM        # must be 262144
```
Point GSport at it via F4 -> ROM File Selection -> /opt/gsport/ROM.
