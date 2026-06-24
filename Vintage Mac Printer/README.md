# Raspberry Pi as an AppleTalk PostScript RIP for an Epson WF-3540

Turn an old Raspberry Pi into a PostScript RIP that vintage Macs print to over
AppleTalk using the LaserWriter driver, while a modern Epson WF-3540 (on Wi-Fi)
does the physical printing. The Pi fully rasterises text and graphics — it does
not dump PostScript at the printer.

## How it works

```
Vintage Mac (LaserWriter 7.1 / 8.1 / 8.5.1 + colour PPD)
   | AppleTalk / PAP (DDP)
   v
papd  (Netatalk 2.x)                 <-- needs AppleTalk kernel module
   | local CUPS submission (job stays application/postscript)
   v
CUPS queue on the Pi
   | pstops -> Ghostscript (pdftoraster/gstoraster) -> rastertoescpr
   v  socket:// or lpd:// over the LAN
Epson WF-3540 (Wi-Fi, reached via the router)
```

The actual RIP is **CUPS + Ghostscript**. A normal CUPS queue built around the
Epson's ESC/P-R driver already accepts PostScript and rasterises it; we simply
feed that queue from papd instead of from a modern client.

## Read this before you start (honest caveats)

1. **AppleTalk is the hard part, not the printing.** Raspberry Pi OS does **not**
   ship the `appletalk` kernel module, and Netatalk 3.x **removed** AppleTalk
   (DDP/PAP) entirely. To support LaserWriter 7.1/8.x over AppleTalk you must:
   (a) build/obtain the `appletalk` kernel module, and (b) build **Netatalk 2.x**
   from source. Both are one-off but fiddly. Sources:
   - Netatalk dropped DDP at 3.0; 2.2 is required for AppleTalk:
     https://github.com/rdmark/Netatalk-2.x
   - AppleTalk kernel module notes: https://netatalk.io/docs/AppleTalk-Kernel-Module
   - papd + CUPS integration: https://netatalk.io/manual/en/AppleTalk

2. **Pi 1 performance.** A Pi 1 (single-core ARMv6, 256–512 MB RAM) will RIP
   correctly but **slowly**, especially full-page colour at higher resolution.
   Large colour pages may take tens of seconds to minutes and are memory-bound.
   It works; it is not fast. Building the kernel module on the Pi 1 itself can
   take well over an hour — consider cross-compiling or building on a faster Pi.

3. **LaserWriter 7.1 colour is best-effort.** 7.1 predates rich colour
   PostScript. It will read the PPD and print, but colour behaviour under 7.1 is
   not guaranteed. 8.x is the tested-good path (Netatalk's own docs report
   LaserWriter 7 on System 7.1.1 and LaserWriter 8 on Mac OS 8.6 working through
   papd to a CUPS printer).

4. **Shortcut if you only need 8.5.1:** LaserWriter 8.5.1 can print via LPR over
   TCP/IP. If you can live without 7.1/8.1, skip AppleTalk entirely: create the
   CUPS queue (Part 3), enable the CUPS LPD service, and point a Desktop Printer
   (LPR) on the Mac at the Pi. None of the kernel-module/Netatalk work is needed.
   The rest of this guide assumes you want the full AppleTalk path.

---

## Part 0 — One-shot install (optional)

If you would rather not run Parts 1–4 by hand, `bootstrap-pi-rip.sh` does the
unattended heavy lifting (packages, kernel module, Netatalk 2.x) and then runs
the interactive configurator for you. Correct order:

```bash
# After flashing Raspberry Pi OS and connecting by ETHERNET:
sudo apt update && sudo apt full-upgrade -y && sudo reboot   # do this FIRST
# then, from this folder (must contain setup-pi-rip.sh and the .ppd):
sudo ./bootstrap-pi-rip.sh                 # add --hold-kernel to pin the kernel
```

The upgrade-and-reboot first step is not optional: you must build the AppleTalk
module against the kernel you will actually be running, or it will fail to load
after a later reboot. The script checks for this and refuses to proceed if the
running kernel is stale.

**Caveat:** Phase 2 (kernel module) is the fragile step and could not be tested
against a real Pi. If it fails, the script stops cleanly and you fall back to the
manual kernel build in Part 2. Parts 1–4 below remain the authoritative manual
procedure and the place to look when something needs adjusting.

---

Use a current Raspberry Pi OS (Lite is fine). Then:

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y cups cups-client cups-filters ghostscript \
                    printer-driver-escpr avahi-daemon \
                    build-essential git autoconf automake libtool \
                    libssl-dev libgcrypt-dev libdb-dev libwrap0-dev \
                    libpam0g-dev libcups2-dev pkg-config
sudo usermod -aG lpadmin "$USER"
sudo cupsctl --remote-admin WebInterface=yes   # optional: web UI on :631
```

`printer-driver-escpr` is the open-source Epson ESC/P-R driver and lists the
**WF-3540** among supported models (OpenPrinting / Debian). The WF-3540 is a
colour inkjet (max 5760×1440), so colour output is fully supported on the Pi
side.

Give the Epson a fixed address (DHCP reservation on your router is easiest) so
the CUPS device URI does not drift.

---

## Part 2 — AppleTalk kernel module

Check first — you may already have it:

```bash
sudo modprobe appletalk && lsmod | grep appletalk
grep -i appletalk /proc/net/protocols
```

If `modprobe` fails, you must build it. The module source lives in the kernel
tree under `net/appletalk` and is enabled with `CONFIG_ATALK=m`.

**Method A — build just the module against your running kernel (faster):**

```bash
sudo apt install -y raspberrypi-kernel-headers bc bison flex libssl-dev
# Get kernel source matching the running kernel:
sudo wget -O /usr/local/bin/rpi-source \
  https://raw.githubusercontent.com/RPi-Distro/rpi-source/master/rpi-source
sudo chmod +x /usr/local/bin/rpi-source
rpi-source            # downloads + prepares the source tree for your kernel

cd ~/linux*           # the tree rpi-source created
scripts/config --module CONFIG_ATALK
make prepare
make M=net/appletalk modules        # builds only appletalk.ko
sudo make M=net/appletalk modules_install
sudo depmod -a
sudo modprobe appletalk && lsmod | grep appletalk
```

**Method B — full kernel rebuild** following the official Raspberry Pi
"Building the kernel" documentation, with `Networking support -> Networking
options -> Appletalk protocol support` set to `M`. This is the most reliable but
slowest path; on a Pi 1 prefer cross-compiling per those docs.

Make it load at boot:

```bash
echo appletalk | sudo tee /etc/modules-load.d/appletalk.conf
```

Notes:
- Known kernel bug (v6.8 and earlier) mishandles AppleTalk across **multiple**
  interfaces. We sidestep it by running AppleTalk on the **wired interface only**
  — never over Wi-Fi.
- rpi-source occasionally lags brand-new kernels. If it refuses, either pin an
  older kernel (`sudo apt install --allow-downgrades ...` / `rpi-update` to a
  known tag) or use Method B.

---

## Part 3 — Build Netatalk 2.x (atalkd + papd)

Debian's `netatalk` package is 3.x (no AppleTalk), so build the 2.x fork, which
compiles cleanly on modern systems and enables DDP, papd, atalkd and timelord by
default:

```bash
git clone https://github.com/rdmark/Netatalk-2.x.git
cd Netatalk-2.x
git checkout branch-netatalk-2-x        # if not already the default branch
./bootstrap                              # if present; otherwise autoreconf -fi
./configure --enable-systemd --sysconfdir=/etc --with-uams-path=/usr/lib/netatalk
make -j"$(nproc)"
sudo make install
```

Confirm AppleTalk and CUPS were compiled in:

```bash
afpd -V | grep -i 'Transport layers'    # expect: TCP/IP AppleTalk
which atalkd papd nbplkup
```

If `configure` complains about libdb/libgcrypt versions, install the `-dev`
packages from Part 1; the fork carries the community patches for modern
toolchains, but exact dependency names can vary by OS release — check the repo
README if a check fails. (Flagged because this is the step most likely to need
local adaptation.)

The 2.x repo also offers an automated Debian install script if you prefer not to
build by hand — see its README.

---

## Part 4 — Run the setup script

With the kernel module loaded and Netatalk 2.x installed, run the interactive
configurator (in this same folder, beside the PPD):

```bash
sudo ./setup-pi-rip.sh
```

It will:
- verify CUPS, the AppleTalk module, and atalkd/papd,
- pick the wired interface,
- **discover network printers** and let you choose the Epson (or type a URI),
- choose the Pi-side ESC/P-R driver automatically (falls back to driverless or a
  PPD you supply),
- prompt for the **Chooser name** and **AppleTalk zone** (with defaults),
- create the CUPS RIP queue,
- install the **Mac-side colour PPD** and write `atalkd.conf` + `papd.conf`,
- start the services and verify NBP registration with `nbplkup`.

Manual equivalents, if you want to do it by hand:

```bash
# CUPS queue (real Epson). Adjust URI/driver to taste.
sudo lpadmin -p EpsonRIP -E \
  -v socket://192.168.1.50:9100 \
  -m "$(lpinfo -m | grep -i WF-3540 | grep -i escpr | head -n1 | awk '{print $1}')"
echo "RIP test" | lp -d EpsonRIP      # should print from the Pi directly

# /etc/atalk/atalkd.conf  (seed router, single zone, wired iface)
eth0 -seed -phase 2 -net 1-1000 -addr 1000.142 -zone "RIP"

# /etc/atalk/papd.conf
"Epson WF-3540 RIP:LaserWriter@RIP":\
    :pr=EpsonRIP:\
    :pd=/etc/atalk/Epson-WF3540-RIP-Colour.ppd:\
    :op=root:

sudo systemctl enable --now atalkd ; sleep 20
sudo systemctl enable --now papd
nbplkup            # should list your printer name
```

papd's CUPS integration matters here: when `pr=` names a CUPS queue (rather than
an lpd queue), papd submits the job to CUPS, so the PostScript runs through the
CUPS/Ghostscript filter chain and is rasterised. That is what makes this a real
RIP and not a passthrough.

---

## Part 5 — The vintage Mac

1. **Install the PPD.** Copy `Epson-WF3540-RIP-Colour.ppd` into
   `System Folder:Extensions:Printer Descriptions` on the Mac (via AppleShare,
   a disk image, or a floppy). The file name is 8.3-clean for old systems.
2. **Chooser.** Open the Chooser, click the **LaserWriter** icon, select the
   zone you set (e.g. `RIP`), select the printer name, then **Setup/Create** and
   choose the PPD above when prompted.
   - LaserWriter 8.x: pick the PPD explicitly in the Setup dialog.
   - LaserWriter 7.1: selecting the printer is usually enough; colour is
     best-effort as noted.
3. **Print.** Choose Colour in the print dialog (Color/Grayscale popup, enabled
   by `*ColorDevice: True` in the PPD). Watch the Pi:

```bash
lpstat -o                 # queued jobs
journalctl -u papd -f     # papd receiving PAP jobs
tail -f /var/log/cups/error_log
```

---

## The two PPDs (don't confuse them)

- **`Epson-WF3540-RIP-Colour.ppd` (Mac side):** describes a generic **colour
  PostScript Level 2** device to the LaserWriter driver. It only needs to be a
  valid PPD, declare colour, and list page sizes the Epson can print. Validated
  with `cupstestppd` → `PASS`. Edit the `*ImageableArea` margins if you need
  tighter layout; they are conservative generic values, not the Epson's exact
  hardware margins.
- **escpr PPD (Pi side):** the real Epson driver, selected automatically by the
  script via `lpinfo -m`. This is what turns raster into ESC/P-R colour.

---

## Troubleshooting

- **`atalkd` errors "Address family not supported by protocol"** → the AppleTalk
  kernel module is not loaded. Revisit Part 2.
- **Printer not in Chooser** → confirm `nbplkup` lists it on the Pi; confirm the
  Mac is on the **same wired segment**; give atalkd a minute to stabilise after
  start; check `journalctl -u atalkd`.
- **Job prints garbage / PostScript text** → the queue is treating input as raw.
  Confirm the CUPS queue has the escpr PPD (not a "raw" queue) and that
  `echo test | lp -d EpsonRIP` prints normally from the Pi.
- **Colour prints as greyscale** → check the Color/Grayscale setting in the Mac
  print dialog and `*ColorModel` in the queue; verify the escpr PPD's colour
  options on the Pi (`lpoptions -p EpsonRIP -l`).
- **Slow on Pi 1** → expected. Lower the Mac-side `*DefaultResolution` to
  360dpi, or accept the wait. Consider a Pi 2/3 if throughput matters.

## File manifest

- `bootstrap-pi-rip.sh` — one-shot installer (packages + kernel module +
  Netatalk 2.x, then runs the configurator). Optional; see Part 0.
- `setup-pi-rip.sh` — interactive configurator (shellcheck-clean).
- `Epson-WF3540-RIP-Colour.ppd` — Mac-side colour PostScript PPD (validated).
- `README.md` — this guide.
