# CAVEATS — honest limits

## 1. Serial + Ethernet together: yes

The emulated SCC serial ports (slots 1/2, exposed as TCP 6501/6502) and the
Uthernet card (slot 3) are independent in the IIgs and in GSport. They run
simultaneously. AppleTalk, when enabled, runs as LocalTalk through the printer
port (slot 1) -- confirmed in scc.c (`case 3: localtalk`). So:
- RS232 -> modem port (slot 2 / socket 6502).
- AppleTalk -> printer port (slot 1).
- Uthernet -> slot 3.
All three can be active at once. If you don't use AppleTalk, either serial
port is free for RS232.

Note: the F4 menu offers "Use real port if avail", but the real-serial-device
(termios) backend is only in scc_macdriver.c, which is NOT compiled on Linux.
On the Pi the working path is the TCP socket + the socat bridge (05 script).
Porting the termios code to Linux is possible but is a source change.

## 2. VGA + composite simultaneously (the one weak spot)

VGA via HDMI->VGA is solid and is the default. Getting composite live AT THE
SAME TIME on a Pi 4 is the hard part:
- `03-boot-experience.sh vga-composite` keeps HDMI/VGA and ASKS for composite as
  a second connector via enable_tvout + a composite `video=` line. It is
  config.txt/cmdline only, so it is fully reversible and cannot brick boot
  (revert: `/opt/gsport/revert-video.sh`). BUT whether the firmware/kernel
  actually brings composite up as a secondary output this way is not guaranteed,
  and I could not test it on hardware. If it doesn't appear, you simply get VGA.
- The stock documented composite method (`,composite` on the overlay) DISABLES
  HDMI, so it cannot be used for simultaneity.
- The GUARANTEED simultaneous route is hardware: VGA from a **DPI VGA666 hat**
  (GPIO, separate pixel pipeline from the composite VEC), with composite from
  the 3.5mm jack. Reliable, but it consumes most of the GPIO header. Not
  auto-scripted because it needs that hardware.

Composite is low-res (PAL/NTSC), which suits the IIgs natively; VGA upscales.

## 3. Sound

GSport writes to /dev/dsp (OSS). `01-system-prep.sh` loads `snd_pcm_oss` and
pins the ALSA default to the analog jack (VGA-over-HDMI carries no audio;
composite shares the same analog jack). On-board analog audio is PWM and a bit
hissy -- for cleaner sound, use a USB sound card and point /etc/asound.conf at
it instead.

## 4. AppleTalk

Bridges LocalTalk->EtherTalk Phase 2 (802.3 + SNAP). Requires **ROM03** and an
AppleShare-compatible server (Netatalk 2.x / A2SERVER / classic Mac). It does NOT
do AFP-over-IP, so a modern NAS will not answer. Wired Ethernet only; WiFi is
unsupported by the layer-2 promiscuous mechanism (Uthernet and AppleTalk both
rely on it), and the binary needs cap_net_raw (setcap in 02, or run as root).

Hard-won gotchas from getting this working:
- **IIgs side: Slot 1 = AppleTalk, not Slot 7.** On ROM03 the AppleTalk option is
  in slot 1 (printer port); slot 7's AppleTalk is greyed out (that's the ROM01
  location). AppleTalk then uses the printer port, so put RS232 on slot 2.
- **No Chooser.** Server mounting is the **AppleShare** icon in the *graphical*
  Control Panel, not a Chooser menu. If it's missing, install "Network:
  AppleShare" from the GS/OS Installer (AFP Mounter erroring about missing
  AppleTalk components is the tell).
- **Network number is the usual failure.** The bridge starts on net 0 and learns
  its number only from a seed router's RTMP. On a router-less network the server
  sits in the startup range (65280.x) and the bridge can't open sessions -> the
  server is *visible* but selecting it gives "No response from the server".
  Fix: run the server as a seed router with a fixed net (e.g. net 1) and set
  GSport's `g_appletalk_network_hint` to match. Setting the hint to the startup
  net (65280) alone is usually NOT enough. See netatalk-server-setup.md.
- **Login: use Guest first.** The IIgs only does guest/cleartext/randnum (not
  DHX/DHX2), and stock System 6.0.1's CDEV sends cleartext passwords wrongly, so
  guest is the reliable first mount. Ensure afpd offers uams_guest.so.
- **Same physical segment.** EtherTalk is layer 2 — no routers between the Pi,
  the server, and any other AppleTalk machines.

## 4b. Uthernet / BBS (TCP/IP)

Runs simultaneously with AppleTalk (Uthernet = slot 3, AppleTalk = slot 1;
separate stacks on the same `eth0`). The gotcha: GSport emulates the **CS8900A =
Uthernet I**, and the W5100 **Uthernet II is not emulated**. So on the IIgs you
must use the **Uthernet (I)** Marinetti link layer, not the more commonly
documented Uthernet II ("UtherLL") one, and set its slot to 3 to match GSport.
DHCP is the easy path (hands over IP + DNS). See marinetti-bbs-setup.md.

## 5. Framebuffer on Bookworm

`fbdriver.c` opens /dev/fb0. On Pi OS Lite this normally exists via DRM fbdev
emulation. If it is missing after boot, the X11 fallback binary (`gsportx`,
also built by 02) can be launched under a minimal X server. The kiosk service
prefers the framebuffer binary.

## 6. The blue shade

`#1B3FBF` is an APPROXIMATION of the IIgs boot blue, not a citable exact value.
Tune it in one place in `03-boot-experience.sh`.

## 7. Not hardware-tested

The build approach was compiled and verified off-Pi. The boot/splash/video/
audio and the vga-composite attempt follow current Raspberry Pi documentation
but must be verified on your actual Pi 4.
