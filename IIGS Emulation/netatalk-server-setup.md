# Netatalk server changes for the Apple IIgs (GSport AppleTalk bridge)

## Why this is needed

The GSport AppleTalk bridge cannot cope with a **router-less** AppleTalk network.
When there is no seed router, Netatalk parks itself in the *startup range*
(`net 0-65534`, address `65280.x`), and native EtherTalk nodes like your Mac SE
self-assign into that same range and talk fine. The GSport bridge, however,
starts on net `0` and only learns a network number from a router's RTMP
broadcasts — with nothing routing, it never learns one, so **discovery works but
sessions fail** ("No response from the server"). Setting the GSport network hint
to `65280` was not enough.

The fix: make Netatalk a **seed router** with a small, fixed network number
(net `1`). It then broadcasts RTMP, the bridge learns net `1`, and directed
sessions address correctly.

> This server currently works for your Mac SE, so **every change below is backed
> up first and has an explicit rollback** at the end. The seed-router change is
> transparent to the Mac SE — it re-homes to net 1 automatically — but if
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

## Step 1 — Make atalkd a seed router (fixes "No response")

Edit `atalkd.conf` so the single interface line reads:

```
eth0 -router -phase 2 -net 1 -addr 1.100 -zone "A2"
```

- `-router` makes atalkd seed the network and emit RTMP.
- `-net 1` is the network number the bridge will use — remember it for the
  GSport hint (Step 6).
- `-addr 1.100` is the server's own node on net 1 (any free node works).
- `-zone "A2"` names the zone the IIgs Chooser/AppleShare will show.

(This is the exact pattern the "IIgs via a Pi bridge" guides use.)

---

## Step 2 — Ensure IIgs-compatible authentication (fixes the login box)

The IIgs only understands **guest**, **cleartext**, and **randnum** — not the
DHX/DHX2 methods Netatalk prefers. Look at your default-server line in
`afpd.conf` and make sure the UAM list includes `uams_guest.so` and
`uams_clrtxt.so` (randnum optional). A known-good line:

```
- -transall -uamlist uams_guest.so,uams_clrtxt.so,uams_randnum.so,uams_dhx2.so -nosavepassword
```

- The leading `-` is the "default server" marker — keep it.
- `-transall` enables both DDP (AppleTalk) and TCP.
- Keeping `uams_dhx2.so` preserves modern-Mac logins; the IIgs just picks guest.

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
cd /opt/gsport && ./gsportfb
```

Then on the IIgs: Control Panel → **AppleShare** → select the server → **log in
as Guest first** (stock System 6.0.1 has a cleartext-password bug; guest proves
the path end-to-end). Turn on GSport's **Show AppleTalk Diagnostics** and confirm
the bridge now settles on net `1`.

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

- **Mac SE stops seeing the server after the change**: it may not have re-homed
  yet — reboot the Mac SE, or roll back. A seed router changing the net number
  mid-session can drop existing clients until they rejoin.
- **`nbplkup` still shows `65280.x`**: atalkd didn't accept the seed line —
  re-check `atalkd.conf` syntax and that you did a *full* restart. Check the
  atalkd log for a "seeding"/"router" line vs "config for no router".
- **IIgs sees the server but login fails**: UAM issue (Step 2). Use Guest. For
  passworded logins you need randnum (with `afppasswd`) or Marsha Jackson's
  patched AppleTalk CDEV on the IIgs, because stock 6.0.1 sends cleartext
  passwords incorrectly.
- **AppleTalk kernel module**: atalkd needs the kernel `appletalk` (DDP) module;
  it auto-loads or errors at start. If atalkd won't start, check
  `dmesg | grep -i appletalk` and that the module is present for your kernel.
- **Keep it single-segment**: the Pi/GSport, the server, and the Mac SE must be
  on the same physical Ethernet (same switch/broadcast domain). EtherTalk is
  layer 2 and will not cross a router.
