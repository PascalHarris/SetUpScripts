# MariaDB Connection Setup

Connections to MariaDB are made exclusively via SSH tunnel. Port 3306 is bound
to `127.0.0.1` on the Docker host only, so it is unreachable from the public
internet. The tunnel path is:

```
your Mac → SSH → (127.0.0.1:3306) → Docker network → maria-db container
```

---

## Rotating the password

Run on webserver as root whenever the password needs changing:

```bash
cd ~/lemp-compose
sudo ./rotate-db-password.sh
```

The script generates a cryptographically random password, applies it to the
live database, updates `/root/secrets/db_root_password.txt` and
`/root/secrets/db_backup.cnf`, and prints the new password to the terminal.
Save it to your password manager at that point, then update Sequel Ace and
DataGrip as needed.

The password is also readable on the server at any time:

```bash
sudo cat /root/secrets/db_root_password.txt
```

---

## Server-side setup (one-off)

### 1. Bind MariaDB to localhost only

In `~/lemp-compose/docker-compose.yml`, add a `ports` block to the `maria-db`
service:

```yaml
  maria-db:
    image: mariadb:11.4
    ports:
      - "127.0.0.1:3306:3306"   # loopback only — never 0.0.0.0
```

The `127.0.0.1:` prefix is critical. Without it Docker binds to all interfaces
and MariaDB becomes publicly reachable.

### 2. Restart the container

```bash
docker compose up -d --no-deps maria-db
```

Verify the binding — the output should show `127.0.0.1:3306`, not `0.0.0.0:3306`:

```bash
docker compose ps maria-db
```

---

## Testing the tunnel manually

Before configuring a GUI client it is worth confirming the tunnel works:

```bash
# On your Mac — leave this running in one Terminal window
ssh -L 3307:127.0.0.1:3306 <username>@<server-ip> -N
```

Then in a second Terminal:

```bash
mysql -h 127.0.0.1 -P 3307 -u root -p
```

A MariaDB prompt confirms the plumbing is working. Port 3307 is used locally
rather than 3306 to avoid conflicts with any local MySQL installation.

---

## Sequel Ace

Create a new connection and choose **SSH** from the tab row at the top (not
TCP/IP).

**MySQL section** (the destination inside the tunnel):

| Field      | Value                       |
|------------|-----------------------------|
| MySQL Host | `127.0.0.1`                 |
| Username   | `root`                      |
| Password   | *(from password manager)*   |
| Database   | *(leave blank to browse all)* |
| Port       | `3306`                      |

**SSH section** (the connection to the webserver):

| Field        | Value                                      |
|--------------|--------------------------------------------|
| SSH Host     | *(server IP or hostname)*                  |
| SSH User     | `<username>`                             |
| SSH Password | *(leave blank — key auth)*                 |
| SSH Key      | `~/.ssh/id_ed25519` *(or your key path)*   |
| SSH Port     | `22`                                       |

Click **Test Connection** before saving. Sequel Ace manages the tunnel
itself — no separate Terminal session is needed.

---

## DataGrip

Create a new data source: **File → New → Data Source → MariaDB** (use the
MariaDB driver rather than MySQL to avoid dialect differences).

**General tab:**

| Field    | Value                     |
|----------|---------------------------|
| Host     | `127.0.0.1`               |
| Port     | `3306`                    |
| User     | `root`                    |
| Password | *(from password manager)* |
| Database | *(optional)*              |

**SSH/SSL tab** — tick **Use SSH tunnel**, then:

| Field            | Value                                     |
|------------------|-------------------------------------------|
| Proxy host       | *(server IP or hostname)*                 |
| Proxy port       | `22`                                      |
| Proxy user       | `<username>`                            |
| Auth type        | **Key pair (OpenSSH or PuTTY)**           |
| Private key file | `~/.ssh/id_ed25519` *(or your key path)*  |
| Passphrase       | *(only if your key has one)*              |

Click **Test Connection** on the SSH/SSL tab first to confirm the tunnel opens,
then switch back to the General tab and test again to confirm the database
responds. DataGrip manages the tunnel automatically on each subsequent
connection.

---

## Note on WordPress database credentials

`rotate-db-password.sh` only rotates the `root` account. WordPress connects
with a separate, lower-privilege database user defined in `wp-config.php`. If
that user's password ever needs changing it is a two-step job: `ALTER USER` in
MariaDB, then update `wp-config.php` on the server. The two operations are
independent.
