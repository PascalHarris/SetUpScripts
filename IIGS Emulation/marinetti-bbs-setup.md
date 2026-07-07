# TCP/IP for BBSs on the IIgs (Marinetti + Uthernet)

## Does this conflict with AppleTalk? No.

They are two independent cards in two different slots, using two different
network stacks:

- **AppleTalk** = printer port (slot 1), for the AppleShare file server.
- **Uthernet** = slot 3, TCP/IP for telnet/BBS via the Marinetti stack.

On the IIgs they never touch. In GSport they are separate subsystems that share
only the raw `eth0` feed — exactly how your Mac SE carries EtherTalk and TCP/IP
on one wire. You can leave both on at once. AppleTalk does not carry telnet
traffic, so "set up Ethernet for BBSs" means installing **Marinetti** (the IIgs
TCP/IP stack); it is separate from the AppleShare software.

## CRITICAL: use the Uthernet **I** link layer, not Uthernet II

GSport emulates the **CS8900A** chip = the original **Uthernet I**. The newer
Uthernet II (W5100) is a completely different chip and is **not** emulated by
GSport (or any emulator). Marinetti has separate link-layer modules for each:

- **"Uthernet"** link layer (CS8900A / Uthernet I)  <- THIS ONE.
- **"Uthernet II"** link layer (Ewen Wannop's "UtherLL", W5100)  <- will NOT work
  here; it talks to registers the emulated card doesn't have.

Most modern write-ups and the popular GS/OS starter images are built around
Uthernet II, so double-check you are selecting the plain **Uthernet** (I) link
layer. If your TCP/IP control panel only lists Uthernet II, you need to add the
Uthernet I link-layer module before this will work.

---

## Step 1 — GSport: turn the Uthernet card on

Already keyed in `config.txt`. Quit GSport first (it rewrites the file on exit):

```sh
sudo pkill gsportfb
sed -i 's/^g_ethernet = .*/g_ethernet = 1/' /opt/gsport/config.txt
cd /opt/gsport && ./gsportfb
```

Or in F4 -> Ethernet Card Configuration -> **Uthernet Card in Slot 3 = On**,
leaving AppleTalk Bridging = On and the same interface number. On launch GSport
logs `Uthernet support is ON.` once it has the interface.

## Step 2 — IIgs: install Marinetti

Boot GS/OS. Get **Marinetti 3.0b11** (the `Marinetti3.0b11.po` installer from
a2retrosystems.com), mount it, run the installer, follow its quickstart, and
restart. This adds a **TCP/IP** control panel. Marinetti needs System 6.0.1+.

## Step 3 — IIgs: add the Uthernet I link layer

If the Uthernet (I) link layer isn't already present, install it and reboot so
it appears in the TCP/IP control panel's link-layer list. (Link-layer config is
stored in `*:System:TCPIP:`.) Remember: **Uthernet, not Uthernet II.**

## Step 4 — Configure the TCP/IP control panel

Open **TCP/IP** and "Set up connection":

1. **Set the link layer to Uthernet, and set its SLOT to 3** (to match GSport).
   Set the slot *first* — no other settings take effect until the slot is right.
   This is the single most common cause of "won't connect."
2. Addressing: tick **DHCP** so your router hands the IIgs an IP *and* DNS.
   (Static also works: set IP / mask / gateway / DNS for your LAN yourself.)
3. Optionally tick "connect when GS/OS boots".
4. Save, then **Connect**.

## Step 5 — Telnet into a BBS

Marinetti has no bundled telnet client. Good options:
- **Spectrum** (Ewen Wannop, freeware) — supports Marinetti and Telnet.
- **ANSITerm** — proper ANSI/colour, best for the full BBS look.

Point it at the BBS host and port (usually 23) and connect.

---

## Notes / gotchas

- **Addressing is per-stack.** Marinetti's IP (via DHCP) is completely separate
  from the AppleTalk net-1 world; nothing you set for AppleShare applies here.
- **DNS:** if hostnames don't resolve, set a DNS server manually in Marinetti
  (your router's IP, or e.g. 1.1.1.1). DHCP usually supplies it, but not always.
- **Same layer-2 requirements as AppleTalk:** wired-only, `cap_net_raw`/root,
  same physical segment — already satisfied by the AppleTalk setup, so TCP/IP
  comes along for free.
- **First-connect quirk:** some IIgs telnet apps fail the first attempt and work
  on the second; a known Marinetti-era annoyance, not your setup.

---

## Rollback / disable Uthernet

TCP/IP is additive and doesn't affect AppleTalk, but to turn it off:

```sh
sudo pkill gsportfb
sed -i 's/^g_ethernet = .*/g_ethernet = 0/' /opt/gsport/config.txt
cd /opt/gsport && ./gsportfb
```

(or F4 -> Uthernet Card in Slot 3 = Off). On the IIgs you can leave Marinetti
installed; with the card off it simply won't connect. Nothing here changes the
AppleTalk/AppleShare configuration.
