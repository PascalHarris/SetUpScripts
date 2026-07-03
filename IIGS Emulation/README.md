# Raspberry Pi -> Apple IIgs (GSport, framebuffer kiosk, networked)

Turns a bare **Raspberry Pi 4 (8GB is fine; any RAM is plenty)** running
**Raspberry Pi OS Lite (64-bit, Bookworm)** into an Apple IIgs that boots
straight into the emulator behind a blue screen, with VGA output, Uthernet
(TCP/IP for BBSs via Marinetti), AppleTalk (EtherTalk bridging to an AppleShare
server), analog sound, and an optional USB RS232 serial bridge.

Emulator: **GSport** (david-schmidt fork) -- the only buildable IIgs emulator
that still has BOTH Uthernet AND AppleTalk, plus a native Linux **framebuffer**
driver (no X11/desktop), ideal for a kiosk. Its Uthernet (TFE) + AppleTalk
(atbridge) core was compiled from source and verified to link libpcap and
contain the bridge symbols. The build script fixes the shipped Pi vars file
(ARM arch flag + missing -lpcap).

---

## What works / partial / dropped

FULLY:
- Max RAM (GSport ceiling 14MB) + ZipGS acceleration (Unlimited >= 14MHz)
- Analog sound via the OSS shim, routed to the 3.5mm jack
- VGA output (HDMI->VGA adapter), 640x480 -- the primary output
- BBS over IP: Uthernet + Marinetti (wired Ethernet only)
- Blue boot screen, no rainbow splash, no Linux boot text
- USB RS232 serial via a socat bridge (runs at the same time as Ethernet)
- SSH for configuration

PARTIAL / CONDITIONAL:
- AppleTalk: LocalTalk->EtherTalk bridge. Needs ROM03 + an AppleShare server
  (netatalk / A2SERVER / classic Mac). Not AFP-over-IP. Wired only.
- Simultaneous VGA + composite: VGA is solid; composite-at-the-same-time is an
  experimental, reversible attempt (Pi 4). Guaranteed simultaneity needs a DPI
  VGA666 hat. See CAVEATS.md.

DROPPED (per request):
- Reading physical floppy drives. GSport mounts image files only; the physical-
  disk imaging workflow has been removed. You still mount .po/.2mg/.woz images
  you already have, via the disk slots in gsport.config.txt.

---

## Networking peripherals are simultaneous

Serial (slots 1/2), Uthernet (slot 3) and AppleTalk are independent and run at
once. AppleTalk claims the printer port (slot 1), so put RS232 on the modem
port (slot 2 / TCP 6502). No need to choose between serial and Ethernet.

---

## Requirements you supply

1. A IIgs **ROM03** you legally own, at `/opt/gsport/ROM` (none is downloaded).
2. **Wired Ethernet**, as the only active interface (01 disables onboard WiFi).
3. For VGA: an active **HDMI->VGA adapter**. For RS232: a **USB RS232 adaptor**.

---

## Run order (on the Pi, over SSH)

```sh
chmod +x *.sh
sudo ./01-system-prep.sh                 # packages, ssh, OSS+analog audio, wifi off
sudo ./02-build-gsport.sh                # build GSport fb (Uthernet+AppleTalk), setcap
sudo ./03-boot-experience.sh vga         # blue boot + VGA  (or: composite | vga-composite)
sudo ./04-kiosk-service.sh               # launch GSport on tty1 at boot
sudo ./05-serial-bridge.sh /dev/ttyUSB0 9600 6502   # OPTIONAL USB RS232 bridge
# copy ROM03 to /opt/gsport/ROM, copy disk images to /opt/gsport/images
sudo reboot
```

After reboot: blue screen -> GSport. SSH stays available throughout. Press
**F4** on the console for the GSport config menu.

---

## Files

- `01-system-prep.sh`    packages, ssh, OSS+analog audio routing, wifi off, dirs
- `02-build-gsport.sh`   clone GSport, patch fb vars (arch + libpcap), build, setcap
- `03-boot-experience.sh [vga|composite|vga-composite]` boot splash + video mode
- `04-kiosk-service.sh`  systemd unit: GSport on the console at boot
- `05-serial-bridge.sh`  socat bridge: USB RS232 <-> GSport TCP serial port
- `gsport.config.txt`    starter config (disk slots; RAM/accel/net via F4)

See `CAVEATS.md` for honest limits and the experimental/source-patch items.
