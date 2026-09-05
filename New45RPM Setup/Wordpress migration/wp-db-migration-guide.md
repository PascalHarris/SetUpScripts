# WordPress Database Migration Guide

Migrates the WordPress database from the old server to Hecate. This covers
the database only — WordPress files (`wp-content/`, themes, plugins, and
especially `uploads/`) are a separate step and are noted at the end.

Two scripts handle the process:

| Script | Runs on | Purpose |
|---|---|---|
| `wp-db-export.sh` | Old server | Dumps the WordPress database to a `.sql` file |
| `wp-db-import.sh` | Hecate | Creates the database and user, imports the dump, updates `wp-config.php` |

The transfer between servers happens manually (via your Mac or direct
server-to-server `scp`) between the two scripts.

---

## Before you begin

- Both scripts must be run as root (`sudo`).
- You will need the old server's MariaDB root password to hand.
- `wp-db-import.sh` generates a new password for the WordPress database
  user — save it to your password manager when prompted. It is not stored
  anywhere on the server.
- The `maria-db` container on Hecate must be running before the import.
  Confirm with `docker compose ps` from `~/lemp-compose`.

---

## Part 1 — Export from the old server

Copy `wp-db-export.sh` to the old server and run it as root:

```bash
scp wp-db-export.sh user@old-server-ip:~/
ssh user@old-server-ip
sudo ./wp-db-export.sh
```

The script will:

1. Detect whether Docker Compose v1 or v2 is in use automatically.
2. List running services so you can confirm the MariaDB service name
   (typically `mariadb` on the old Bitnami stack).
3. Ask for the MariaDB root password. The password is passed to the
   container via an environment variable — it never appears on the command
   line or in `ps` output.
4. List available databases so you can confirm the WordPress database name.
   If in doubt, check the old `wp-config.php`:
   ```bash
   grep DB_NAME /path/to/wordpress/wp-config.php
   ```
5. Dump the database to a timestamped file, e.g.
   `wordpress_export_YYYYMMDD_HHMMSS.sql`, using `--single-transaction`
   for a consistent snapshot without locking tables.

---

## Part 2 — Transfer the dump to Hecate

From your Mac (download from old server, then upload to Hecate):

```bash
scp user@old-server-ip:~/wordpress_export_*.sql ~/Desktop/
scp ~/Desktop/wordpress_export_*.sql pascalharris@<hecate-ip>:~/lemp-compose/
```

Or directly between servers if both accept your SSH key (run from the old
server):

```bash
scp wordpress_export_*.sql pascalharris@<hecate-ip>:~/lemp-compose/
```

---

## Part 3 — Import on Hecate

Copy `wp-db-import.sh` to Hecate (or run it from `~/lemp-compose` if you
put it there) and run as root:

```bash
sudo ./wp-db-import.sh
```

The script will prompt for each value as it goes and confirm before making
any changes. Here is what it does at each stage:

### 3a. Locate the dump file

Enter the full path to the `.sql` file transferred in Part 2, e.g.:

```
/home/pascalharris/lemp-compose/wordpress_export_YYYYMMDD_HHMMSS.sql
```

### 3b. Choose a database name and username

Defaults are `wordpress_45rpm` and `wp_45rpm`. Accept the defaults or
enter your own.

### 3c. Generate the WordPress database password

The script generates a cryptographically random password and displays it
once. **Save it to your password manager immediately** — the script does
not store it anywhere on disk.

### 3d. Create the database and user

Creates the database with `utf8mb4` character set (required for full
Unicode support including emoji), creates the dedicated WordPress user, and
grants it access to that database only. Root credentials are used for this
step via `db_backup.cnf` so no password appears on the command line.

### 3e. Import the dump

Pipes the dump file into the new database. No output means success — any
error will be printed immediately and the script will stop.

### 3f. Update `wp-config.php`

If `wp-config.php` exists at
`~/lemp-compose/public/45rpm/htdocs/blog/wp-config.php`, the script offers to
update the four database lines in place, backing up the original first. The
critical value is `DB_HOST`:

```php
define( 'DB_HOST', 'maria-db' );
```

This must be the Docker service name (`maria-db`), not `localhost` —
PHP-FPM reaches MariaDB over the internal Docker network, not via the host
loopback.

If `wp-config.php` does not exist yet (you have not copied the WordPress
files across), the script prints the values you need to add manually once
you do.

### 3g. URL search-replace (optional)

WordPress stores the full site URL in the database. If the URL is changing
— for example from `http://` to `https://`, or from the old server's IP to
the real domain — the script can run WP-CLI's `search-replace` across all
tables now.

If you are not ready to cut over DNS yet, skip this step and use
`/etc/hosts` on your Mac to test instead (see "Testing before DNS cutover"
below). Run the search-replace just before or just after cutting over DNS.

---

## Part 4 — Testing before DNS cutover

You can verify the migrated site on Hecate without touching DNS by pointing
your Mac at Hecate's IP for the domain. Edit `/etc/hosts` on your Mac:

```bash
sudo nano /etc/hosts
```

Add a line:

```
<hecate-ip>   45rpmsoftware.com www.45rpmsoftware.com
```

Now browsing to `https://45rpmsoftware.com` on your Mac hits Hecate only.
Remove the line when you are ready to cut over DNS for real.

---

## Part 5 — WordPress files

The database migration above does not move WordPress files. You also need
to transfer `wp-content/` — particularly `uploads/` (your media library)
and any customised themes or plugins.

Use `rsync` rather than `scp` for the uploads folder — it can resume if
interrupted and skips files already transferred:

```bash
rsync -avz --progress \
  user@old-server-ip:/path/to/wordpress/wp-content/uploads/ \
  ~/lemp-compose/public/45rpm/htdocs/wp-content/uploads/
```

### Plugins folder

The plugins folder on the old server is named `wp-content/--plugins` (a
rename made during incident response). WordPress cannot see plugins in a
folder with that name. When you copy it to Hecate, rename it:

```bash
mv wp-content/--plugins wp-content/plugins
```

WordPress will show the plugins as inactive after import — you will need to
activate them again from the WordPress admin dashboard.

---

## Troubleshooting

**Import fails with `ERROR 1071` (key too long)**
The dump was made from a database with a different character set. Add
`--set-charset` to the import command, or open the `.sql` file and check
the `DEFAULT CHARSET` line at the top of each `CREATE TABLE` statement.

**`wp-config.php` changes do not take effect**
Confirm the `DB_HOST` is `maria-db` (the Docker service name) and not
`localhost` or `127.0.0.1`. Inside the Docker network, `localhost` refers
to the PHP-FPM container itself, not the database container.

**WP-CLI reports `Error: No WordPress files`**
The `wp --path=/var/www/html` path must match where WordPress is mounted
inside the PHP-FPM container. Confirm with:
```bash
docker compose exec phpfpm-45rpm ls /var/www/html/blog
```

**Site loads but images are missing**
The `uploads/` directory has not been transferred yet, or ownership is
wrong. Files under `wp-content/uploads/` should be owned by `www-data`
inside the container. Fix with:
```bash
docker compose exec phpfpm-45rpm chown -R www-data:www-data /var/www/html/blog/wp-content/uploads
```
