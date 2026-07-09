# Netatalk server changes for the Apple IIgs (GSport AppleTalk bridge)

## Why this is needed

The GSport AppleTalk bridge cannot form AFP **sessions** on a network where it
can't learn its own AppleTalk network number. Discovery (NBP name lookup) is
broadcast and works regardless — the server shows up in the IIgs AppleShare
browser. But *opening* a session is directed traffic, and the emulated IIgs has
to know its own network number to build the source address. It learns that
number only from a **router's RTMP broadcasts**.

On a router-less network (Netatalk non-seed, sitting in the startup range
`65280.x`), nothing broadcasts RTMP, so the bridge stays on net `0`. The IIgs
then discovers the server but **never sends the session request** — it can't
address it. A packet capture shows exactly this: `nbp-lkup`/`nbp-reply` succeed,
then nothing is ever sent to the server's session socket (`.128`). The result is
"No response from the server", against *any* server — including a genuine Mac's
built-in File Sharing, which is how we confirmed the fault is the IIgs/bridge,
not Netatalk.

Two things that seemed like fixes but were NOT:
- **A static network hint alone** (`g_appletalk_network_hint = 65280` or `0`)
  does not work. It tells the bridge to *assume* a number; it does not make the
  IIgs *learn* one, so the session is still never initiated.
- **A named zone** (e.g. `-zone "A2"` / `-zone "AppleTalk"`) makes the server go
  *invisible* to the IIgs — the bridge doesn't relay named zones to it.

The fix that actually works (tested with the IIgs, an LC475 on 7.6.1, and a
modern Mac all mounting simultaneously): run Netatalk as a **seed router** so it
broadcasts RTMP, and use the **default zone `"*"`** so nothing is hidden. The
bridge then learns the seeded net number, the IIgs addresses the session
correctly, and it mounts. Set the GSport hint to the same net number to remove
any doubt.

> This server may already work for genuine Macs, so **every change below is
> backed up first and has an explicit rollback** at the end. The seed-router
> change is transparent to real Macs — they re-home automatically — but if
> anything misbehaves, the rollback restores the exact prior state.

## Confirmed facts about your server

- Netatalk **2.2.4**, `DDP(AppleTalk) Support: Yes` (from `afpd -V`).
- Config directory: **`/usr/local/etc/netatalk/`** (source build).
- Current `atalkd.conf`: `eth0 -phase 2 -net 0-65534 -addr 65280.142` (non-seed).

---

## Step 0 — Back everything up (do not skip)

```sh
cd /usr/local/etc/netatalk
sudo cp -a atalkd.conf            atalkd.conf.bak
sudo cp -a afpd.conf              afpd.conf.bak
sudo cp -a AppleVolumes.default   AppleVolumes.default.bak
ls -l *.bak
```

Note the current `atalkd.conf` contents somewhere too — atalkd **rewrites this
file on startup** (it fills in assigned addresses), so the live file will change
shape after a restart. That is normal; the `.bak` is your source of truth.

---

## Step 1 — Make atalkd a seed router with the default zone (fixes "No response")

Edit `atalkd.conf` so the single interface line reads:

```
eth0 -router -phase 2 -net 1 -addr 1.100 -zone "*"
```

- `-router` makes atalkd seed the network and **broadcast RTMP** — this is the
  active ingredient. RTMP is how the bridge learns the network number, which is
  what lets the IIgs open a session instead of just discovering the name.
- `-net 1` is the network number the bridge will learn — use it for the GSport
  hint (Step 6).
- `-addr 1.100` is the server's own node on net 1 (any free node works).
- `-zone "*"` is the **default ("this cable") zone**. Use `"*"`, not a named
  zone: the bridge does not relay a *named* zone to the IIgs, so a named zone
  (`"A2"`, `"AppleTalk"`, etc.) makes the server go invisible in the IIgs
  browser. `"*"` avoids that while still satisfying atalkd's requirement that a
  Phase 2 seed name a zone.

Note: a fixed `-net` requires a zone, so you cannot "drop the zone" while keeping
`-net 1` — atalkd won't start. `"*"` is the way to have a seed net without a
named zone.

---

## Step 2 — Ensure IIgs-compatible authentication (fixes the login box)

The IIgs only understands **guest**, **cleartext**, and **randnum** — not the
DHX/DHX2 methods Netatalk prefers. Look at your default-server line in
`afpd.conf` and make sure the UAM list includes `uams_guest.so` and
`uams_clrtxt.so`. A known-good line:

```
- -transall -uamlist uams_guest.so,uams_clrtxt.so,uams_dhx.so -mimicmodel RackMac
```

- The leading `-` is the "default server" marker — keep it.
- `-transall` enables both DDP (AppleTalk) and TCP.
- `uams_guest.so` + `uams_clrtxt.so` are all an old client needs (guest, or a
  cleartext login). Keeping `uams_dhx.so`/`uams_dhx2.so` preserves modern-Mac
  logins; the IIgs just picks guest or cleartext.

> **Do NOT add `uams_randnum.so` unless you have actually configured it.**
> randnum needs its own password database (`afppasswd`); advertising it without
> that setup makes old clients (Mac SE, LC475, IIgs) fail *after* a successful
> GetStatus with "No response from the server" — discovery works, the status
> reply comes back, then the session silently dies. This was a real trap in
> testing: adding randnum to a previously-working afpd.conf broke every old
> client until it was removed. If you want passworded (non-guest) logins, either
> set up `afppasswd` for randnum, or use cleartext with Marsha Jackson's patched
> AppleTalk CDEV (stock System 6.0.1 sends cleartext passwords incorrectly).

Note: most old clients (including the IIgs) are happy with just guest +
cleartext, so in practice you usually do **not** need to touch `afpd.conf` at all
for the IIgs — it is the network-number/seed-router side (Step 1) that matters.

---

## Step 3 — Make sure there is a share the IIgs can mount

In `AppleVolumes.default`, comment the bare `~` home-dirs line and add an
explicit volume (the `prodos` option gives Apple II-friendly naming):

```
#~
/srv/a2share  "A2Share"  options:prodos
```

Create it and make it reachable (guest maps to a low-privilege user, so world-
readable is simplest for a first test):

```sh
sudo mkdir -p /srv/a2share
sudo chmod 0777 /srv/a2share      # loosen for the guest test; tighten later
```

---

## Step 4 — Restart Netatalk

atalkd caches its config, so a **full restart** is required (not just afpd).
Find how it is started on this box, then restart it:

```sh
# find the mechanism:
systemctl list-units 2>/dev/null | grep -i -e atalk -e netatalk
ls /etc/init.d/ 2>/dev/null | grep -iE 'atalk|netatalk'

# then use ONE of (whichever exists):
sudo systemctl restart netatalk
#   or
sudo service netatalk restart
#   or
sudo /etc/init.d/netatalk restart
```

atalkd takes ~10-30s to come up (it retries `zip_getnetinfo`). Wait for it to
settle before testing.

---

## Step 5 — Verify on the server

```sh
# NBP entities should now register on net 1 (e.g. 1.100:...):
nbplkup

# atalkd should report seeding net 1, not "config for no router":
sudo journalctl -u netatalk --no-pager | tail -30
#   or check /var/log/syslog / your atalkd log

# confirm the daemons are running:
pgrep -a atalkd; pgrep -a afpd
```

If `nbplkup` shows addresses starting `1.`, the seed worked.

---

## Step 6 — GSport (IIgs) side

Set the bridge's network hint to **1** to match the seed. On the Pi running
GSport (quit GSport first so it does not overwrite the file on exit):

```sh
sudo pkill gsportfb
grep -q '^g_appletalk_network_hint' /opt/gsport/config.txt \
  && sed -i 's/^g_appletalk_network_hint = .*/g_appletalk_network_hint = 1/' /opt/gsport/config.txt \
  || echo 'g_appletalk_network_hint = 1' >> /opt/gsport/config.txt
cd /opt/gsport && sudo ./gsportfb
```

> **Launch GSport with `sudo`** (or apply `setcap`). The bridge needs raw,
> promiscuous access to `eth0`; without it the bridge is silently deaf and the
> server simply won't appear — this exact mistake made the server "vanish" in
> testing. To avoid needing `sudo` every time, apply the capability once:
> `sudo setcap cap_net_raw,cap_net_admin+eip /opt/gsport/gsportfb` (re-apply after
> any rebuild, which clears it). The kiosk service runs as root, so it's only the
> manual launch that needs this.

Then on the IIgs: Control Panel → **AppleShare** → select the server → **log in
as Guest first** (stock System 6.0.1 has a cleartext-password bug; guest proves
the path end-to-end). Turn on GSport's **Show AppleTalk Diagnostics** and confirm
the bridge now settles on net `1`.

Confirm success by watching the wire on the server during the connect — this is
the diagnostic that actually resolves problems here:

```sh
sudo tcpdump -i eth0 -n atalk
```

The IIgs should appear as a **`1.x`** node (it learned net 1 from RTMP) and send
an `atp-req` to the server's session socket **`1.100.128`**. Discovery alone
(`nbp-lkup`/`nbp-reply`) with nothing sent to `.128` means it still hasn't
learned the net number — see troubleshooting.

---

## ROLLBACK — restore the working state

If the IIgs still fails, or the Mac SE stops connecting, put everything back:

```sh
cd /usr/local/etc/netatalk
sudo cp -a atalkd.conf.bak           atalkd.conf
sudo cp -a afpd.conf.bak             afpd.conf
sudo cp -a AppleVolumes.default.bak  AppleVolumes.default

# restart Netatalk the same way you did in Step 4, e.g.:
sudo systemctl restart netatalk
```

Then revert the GSport hint (0 = auto, which is the original behaviour):

```sh
sudo pkill gsportfb
sed -i 's/^g_appletalk_network_hint = .*/g_appletalk_network_hint = 0/' /opt/gsport/config.txt
cd /opt/gsport && ./gsportfb
```

Verify the Mac SE can connect again (`nbplkup` back to `65280.x`). You are now
exactly where you started.

---

## Troubleshooting

Read the wire with `sudo tcpdump -i eth0 -n atalk` during a connect — it settled
every problem here. Identify each machine by its address (the IIgs is a startup-
range or `1.x` node; ignore an already-mounted Mac's ~10s keep-alive chatter).

- **IIgs can't see the server at all**: almost always (a) GSport not launched
  with `sudo`/`setcap` so the bridge is deaf, or (b) a **named zone** on the
  seed line hiding it — use `-zone "*"`. Also confirm the F4 interface number is
  your `eth0`.
- **IIgs sees the server but "No response" on connect, and tcpdump shows
  `nbp-lkup`/`nbp-reply` but NOTHING sent to socket `.128`**: the IIgs hasn't
  learned its network number, so it can't open the session. This is *the* core
  failure. Fix = a seed **router** actively broadcasting RTMP (`-router`, Step 1)
  — a static `network_hint` alone does NOT fix it. Confirm the IIgs then shows as
  a `1.x` node and sends an `atp-req` to `1.100.128`. If it *still* shows net 0
  and never hits `.128` even with an RTMP router live on the wire, the bridge
  isn't processing RTMP — that's the edge of GSport's AppleTalk bridge.
- **The same failure against a genuine Mac's File Sharing** confirms the fault is
  the IIgs/bridge, not the server — don't keep editing Netatalk in that case.
- **IIgs sees the server but login fails**: UAM issue (Step 2). Use Guest. Do
  NOT advertise `uams_randnum.so` unless `afppasswd` is configured — it breaks
  the session after GetStatus for old clients (this silently broke *all* old
  clients in testing). For passworded logins, set randnum up properly, or use
  Marsha Jackson's patched AppleTalk CDEV (stock 6.0.1 sends cleartext wrongly).
- **Real Macs drop after the change**: they may not have re-homed — reboot them.
  The default zone `"*"` and net 1 are transparent to them once rejoined.
- **AppleTalk kernel module**: atalkd needs the kernel `appletalk` (DDP) module;
  it auto-loads or errors at start. If atalkd won't start, check
  `dmesg | grep -i appletalk`.
- **Keep it single-segment**: the Pi/GSport, the server, and any real Macs must
  be on the same physical Ethernet (same switch/broadcast domain). EtherTalk is
  layer 2 and will not cross a router.
