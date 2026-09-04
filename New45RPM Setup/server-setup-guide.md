# 45RPM Software — new web server setup guide

This replaces the old lemp-compose + maint-compose + `maintenance.sh` setup
with a hardened, more reliable equivalent. Website content migration
(WordPress itself) is deliberately out of scope here — this is server and
stack setup only.

## Assumptions made — check these before following the steps below

Since these weren't confirmed, I've picked the safest/simplest default for
each and flagged it. Adjust and re-read before running anything on a real
box:

| Item | Assumption |
|---|---|
| Domains | Only `45rpmsoftware.com` / `www.45rpmsoftware.com` are live (matching `sites[0]` in the old script). The commented-out sites are left commented out. |
| Ubuntu version | 24.04 or 26.04 LTS (current LTS as of writing is 26.04 "Resolute Raccoon", supported until April 2031). Run `lsb_release -a` to confirm; the steps below work for either. |
| Alerts | Failure-only e-mail to `support@45rpmsoftware.com`, relayed via your existing `mail.45rpmsoftware.com` (see "Alerting"). |
| Backups | Local-only, last 4 quarterly backups kept (~1 year), no offsite copy yet. `maintenance.sh` prunes older ones automatically. Adding an offsite `rsync`/`rclone` push later is a single extra step in that script. |
| WordPress auto-update scope | Core + plugins + themes, with an automatic pre-update snapshot and rollback on failure (see "WordPress updates"). |

---

## 0. Verify root is actually secure, before creating anything

Before trusting a "fresh" box, check what the provider actually gave you:

1. **Confirm password auth is really off.**
   `sudo grep -Ei '^\s*(PasswordAuthentication|PermitRootLogin|PubkeyAuthentication)' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null`
   You want `PubkeyAuthentication yes` and no `PasswordAuthentication yes` left active anywhere (some providers add a drop-in in `sshd_config.d/` that overrides the main file — check both).
2. **Check who else can log in.** `cat /etc/passwd | grep -E '/bin/(bash|sh)$'` and `cat /root/.ssh/authorized_keys` — make sure every key listed is one you actually recognise. Provider-injected "support" or "rescue" keys are common and should be removed if you don't want them.
3. **Check what's already listening.** `sudo ss -tulpn` — a genuinely fresh box should show essentially nothing but sshd on 22.
4. **Check for pre-installed agents.** `dpkg -l | grep -iE 'agent|monitor'` — some providers bundle a monitoring/support agent by default; decide whether you want it before it becomes background noise later.
5. **Check `/root/.bash_history` and `last`** for anything the provider did during provisioning that you weren't told about.
6. **Check for pending updates already.** `sudo apt update && sudo apt list --upgradable` — a "fresh" image is often already a few weeks stale.

None of this replaces the hardening below — it's just confirming the starting point is what you think it is.

---

## 1. Create the admin account, lock down SSH

```bash
adduser pascalharris
usermod -aG sudo pascalharris
mkdir -p /home/pascalharris/.ssh
cp /root/.ssh/authorized_keys /home/pascalharris/.ssh/authorized_keys   # your existing key(s)
chown -R pascalharris:pascalharris /home/pascalharris/.ssh
chmod 700 /home/pascalharris/.ssh
chmod 600 /home/pascalharris/.ssh/authorized_keys
```

**Log in as `pascalharris` in a second terminal and confirm `sudo -i` works before touching SSH config** — don't lock yourself out.

Then edit `/etc/ssh/sshd_config` (and check `/etc/ssh/sshd_config.d/*.conf` for overrides):

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

`sudo systemctl restart ssh`, then open a **third**, fresh terminal and confirm you can still log in as `pascalharris` before closing your existing sessions.

Root login is now disabled entirely, per your call on "security is paramount" — there's no fallback root SSH path any more. If that's ever needed in an emergency, it'll have to be via your hosting provider's console/rescue mode, not SSH.

---

## 2. Firewall and brute-force protection

```bash
sudo apt install -y ufw fail2ban
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

fail2ban's default `sshd` jail is enabled out of the box on Ubuntu once installed; `sudo fail2ban-client status sshd` after a minute to confirm it's running.

---

## 3. Install Docker Engine + Compose (official repo, not the Ubuntu-bundled version)

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker pascalharris   # log out/in for this to take effect
```

This gives you `docker compose` (the current plugin, no hyphen) rather than
the old standalone `docker-compose` v1 binary the existing scripts use —
all the commands below use the new form.

---

## 4. Automatic OS security patching

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

This applies **security** updates daily on its own, independent of the
quarterly job below — see "Automation risks" for why that split matters.

---

## Why not Bitnami any more?

The old stack used `bitnami/mariadb`, `bitnami/nginx` and `bitnami/php-fpm`,
all on `:latest`. Since August/September 2025 Bitnami restructured its free
Docker Hub catalogue: the old public catalogue was deleted, and what
remains free is a small (~44 image) development-oriented tier, published
**only** under the `latest` tag with no version pinning. These three images
do still appear to be in that free tier, but "development-oriented,
latest-only" is the opposite of what an unattended production box that's
only touched quarterly needs — every `docker compose pull` could hand you
an untested new major version with no way to pin or roll back.

`docker-compose.yml` below uses the official `mariadb`, `nginx` and `php`
images instead, pinned to major.minor tags (e.g. `mariadb:11.4`,
`nginx:1.27-alpine`) — patch releases still flow in via `docker compose
pull`, but a major-version jump needs a deliberate tag bump by you.

## The application stack

Files (save each at the path noted in its own header comment, relative to
`$COMPOSE_HOME`):

- `docker-compose.yml`
- `php-fpm/Dockerfile` (from `php-fpm.Dockerfile` here)
- `nginx/nginx.conf` (from `nginx.conf` here)
- `nginx/conf.d/45rpmsoftware.conf` (from `nginx-vhost-45rpmsoftware.conf` here)

Build and start:

```bash
cd /home/pascalharris/lemp-compose
docker compose build
docker compose up -d
```

Compared to the old compose file: ports are simplified to `80:80`/`443:443`
(the old double-mapping and the 8080/8443 split were both working around
Bitnami's nginx image listening internally on 8080/8443 by default — the
official image listens on 80/443, so that workaround is no longer needed),
and there's no separate `maint-compose` stack any more — see "TLS
certificates" for why.

## Secrets — keeping the DB password out of every script and compose file

```bash
sudo mkdir -p /root/secrets
openssl rand -base64 32 | sudo tee /root/secrets/db_root_password.txt > /dev/null
printf '[client]\nuser=root\npassword=%s\n' "$(sudo cat /root/secrets/db_root_password.txt)" | sudo tee /root/secrets/db_backup.cnf > /dev/null
sudo chmod 600 /root/secrets/db_root_password.txt /root/secrets/db_backup.cnf
sudo chown root:root /root/secrets/db_root_password.txt /root/secrets/db_backup.cnf
```

- `db_root_password.txt` is consumed once, via `MARIADB_ROOT_PASSWORD_FILE`,
  the first time the `maria-db` container initialises an empty data
  directory. It's otherwise just the disaster-recovery source of truth.
- `db_backup.cnf` is what `mysqldump`/`mariadb` actually authenticate with
  day to day, via `--defaults-extra-file` — this keeps the password off
  every command line (so it never shows up in `ps aux`) and out of every
  script's text entirely.
- Neither file is ever referenced from `docker-compose.yml` as a plain
  value, ever committed anywhere, or ever baked into a heredoc the way the
  old `backupdb.sh` did.

To rotate the password later (including now, given the old one is
compromised): run `rotate-db-password.sh` as root. It changes the live
database password and updates both files in one step, in the right order,
without the password ever appearing as a command-line argument.

## Keeping htpasswd (and friends) unreachable

Two independent layers, so a mistake in one doesn't expose anything:

1. **Location, not just permissions**: any `.htpasswd` file lives in
   `./nginx/htpasswd` on the host — mounted into the nginx container at
   `/etc/nginx/htpasswd`, which sits **outside** `/var/www/html` entirely.
   Even a badly-written `try_files` rule can't serve a file that isn't
   under the docroot in the first place.
2. **Belt and braces**: `nginx/conf.d/45rpmsoftware.conf` also denies
   any request for a dotfile (`location ~ /\. { deny all; }`), which
   additionally blocks `.git`, `.env`, editor swap files, etc., should any
   of those ever end up under the docroot by accident.

## TLS certificates — certbot on the host, not a container running lego

The old `maint-compose` stack existed almost entirely to run `lego` inside
a throwaway container, and the `FIX` comments in the old `maintenance.sh`
document three separate ways that broke over time (lego's own v5 CLI
change, the container's base OS going EOL twice). Rather than keep patching
that pattern, this replaces it outright:

```bash
sudo apt install -y certbot
sudo mkdir -p /home/pascalharris/lemp-compose/acme-challenge

sudo certbot certonly --webroot \
  -w /home/pascalharris/lemp-compose/acme-challenge \
  -d 45rpmsoftware.com -d www.45rpmsoftware.com \
  --email support@45rpmsoftware.com --agree-tos --no-eff-email
```

`nginx/conf.d/45rpmsoftware.conf` reads certificates straight out of
`/etc/letsencrypt/live/45rpmsoftware.com/` (bind-mounted read-only into the
container in `docker-compose.yml`) — there's no more copying certs into a
`./certificates` directory, no `bak` folder, no per-container `.pem`
juggling for nginx.

Install the deploy hook so renewals reload nginx and update the mail
server's certificate copy automatically:

```bash
sudo cp certbot-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/45rpmsoftware.sh
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/45rpmsoftware.sh
```

The `certbot` package installs its own systemd timer (`certbot.timer`),
enabled by default, that checks twice daily and only actually renews (and
fires the hook above) when a certificate is within 30 days of expiry.
Confirm it's active: `systemctl status certbot.timer`.

**Open item**: the deploy hook has a `TODO` where the mail-compose stack's
Postfix/Dovecot service needs restarting after a renewal — I don't have
that stack's service name, so it's a manual step for now until you fill it
in.

## Alerting

`maintenance.sh` emails `support@45rpmsoftware.com` only when something
fails. On a fresh box, outbound port 25 is very often blocked by hosting
providers regardless of local config, so route mail through your existing
`mail.45rpmsoftware.com` via `msmtp` rather than relying on a local MTA:

```bash
sudo apt install -y msmtp mailutils
```

Configure `/etc/msmtprc` to relay authenticated mail via
`mail.45rpmsoftware.com:587`, and set `mailutils` to use `msmtp` as its
sendmail replacement (`/etc/aliases` / `/etc/mail.rc` — the exact lines
depend on which MTA alternative packages pull in, so verify with
`update-alternatives --display mail-transport-agent` after installing).
Store the sending account's password the same way as the DB password —
a root-only file, never in a script.

## The quarterly automated maintenance job

```bash
sudo cp maintenance.sh wp-update.sh /home/pascalharris/lemp-compose/
sudo chmod +x /home/pascalharris/lemp-compose/maintenance.sh /home/pascalharris/lemp-compose/wp-update.sh

sudo cp site-maintenance.service site-maintenance.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now site-maintenance.timer
```

`systemctl list-timers site-maintenance.timer` shows the next scheduled
run. A systemd timer was used rather than cron because it logs to
`journalctl -u site-maintenance.service` automatically, survives the box
being off at midnight (`Persistent=true` catches up on next boot), and
makes ad-hoc runs trivial (`sudo systemctl start site-maintenance.service`)
without editing a crontab.

Each quarterly run: dumps the database, backs up site files (pruning
anything past the last 4), pulls and restarts the containers, runs the
WordPress update (see below — a no-op until a site actually exists at that
path), and does a full `apt upgrade` for anything unattended-upgrades
doesn't cover. It emails you only if something failed.

### WordPress updates

Per your call to prioritise security: the quarterly job updates **core,
plugins and themes**, not just core. `wp-update.sh`:

1. Snapshots the site's files (and a quick single-site DB export) before
   touching anything.
2. Runs `wp core update`, `wp plugin update --all`, `wp theme update --all`.
3. Does a basic health check (`curl` the homepage).
4. If the site doesn't respond correctly afterwards, automatically restores
   the file snapshot. The database is deliberately **not** auto-restored —
   a plugin update failure is usually file-only, and blindly restoring the
   DB risks losing anything genuinely written since the snapshot; that part
   is left for you to check by hand against `wp-pre-update-backup.sql` or
   the quarterly `maria-db` dump.

It's currently inert (`maintenance.sh` checks for `wp-config.php` and skips
if it's not there yet) until the actual WordPress install happens.

## Automation risks — what you asked me to flag explicitly

- **Unattended plugin/theme updates can break a live site with nobody
  watching for three months at a time.** The snapshot-and-rollback above
  catches "site is completely down/erroring" but not subtler breakage
  (a broken checkout flow, a visual regression) that a `curl` health check
  can't detect. If that risk matters more than staying fully current,
  switch `wp-update.sh`'s plugin/theme lines to `--dry-run` and have it
  just email you a diff instead of applying them.
- **A quarterly cadence is too slow for two things, so they're deliberately
  NOT on this timer**: security patches (daily, via unattended-upgrades)
  and TLS renewal (twice-daily, via certbot's own timer). Bundling either
  into the quarterly job would mean a single missed/failed run leaving you
  exposed or with an expired certificate for up to three months.
- **`docker compose pull` on pinned major.minor tags still moves.** A
  `mariadb:11.4` patch release could in principle introduce a regression;
  there's no staging environment in this setup to catch that before it
  hits production. Worth knowing rather than assuming "pinned" means
  "frozen".
- **A failed quarterly run degrades silently otherwise.** The e-mail step
  is why `maintenance.sh` uses `set -uo pipefail` rather than `-e` — a
  single failed step doesn't abort the whole script, so the later ones
  (and the failure e-mail) still run rather than the job just dying midway
  with no notification.
- **Local-only backups are a single-host failure away from useless.** Per
  the assumption above this is deferred, but worth revisiting once you've
  decided on an offsite target.

## Deferred to "website setup later"

Everything above brings the server itself up to the point the old one was
at, with the fixes discussed. Still to do once you're ready for that:

- Actually installing WordPress at `public/45rpm/htdocs` (at which point
  the quarterly WordPress update job activates automatically).
- Confirming the mail-compose stack's service name for the certbot deploy
  hook's `TODO`.
- Deciding on an offsite backup destination, if wanted.
- Any of the previously-commented-out `sites[]` entries, if they're coming
  back.
