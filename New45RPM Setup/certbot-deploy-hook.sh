#!/bin/bash
#
# Install to /etc/letsencrypt/renewal-hooks/deploy/45rpmsoftware.sh
# (chmod +x). Certbot runs every script in that directory after a
# certificate is actually renewed (not on no-op checks that find nothing
# due yet), passing the renewed lineage via $RENEWED_LINEAGE.
#
# This replaces the old maintenance.sh cert-copy/bak dance entirely --
# nginx reads live certs straight out of /etc/letsencrypt (bind-mounted
# read-only in docker-compose.yml), so there is nothing to copy for nginx,
# just a reload to pick the new files up.
#
set -euo pipefail

COMPOSE_HOME=/home/pascalharris/lemp-compose
MAILSERVER_CERT=/home/pascalharris/mail-compose/letsencrypt/etc/letsencrypt/live/mail.45rpmsoftware.com
OWNER_ACCOUNT=pascalharris

cd "$COMPOSE_HOME"
docker compose exec nginx nginx -s reload

# The mailserver container wants its own .pem copy rather than reading
# /etc/letsencrypt directly -- copy the freshly renewed material across.
if [ -n "${RENEWED_LINEAGE:-}" ]; then
  mkdir -p "$MAILSERVER_CERT"
  cp "$RENEWED_LINEAGE/fullchain.pem" "$MAILSERVER_CERT/fullchain.pem"
  cp "$RENEWED_LINEAGE/privkey.pem"   "$MAILSERVER_CERT/privkey.pem"
  chown -R "$OWNER_ACCOUNT":root "$MAILSERVER_CERT"
  chmod 0640 "$MAILSERVER_CERT"/*.pem
fi

# TODO: restart the mail-compose stack's relevant service (Postfix/Dovecot)
# here once that stack's exact service name is confirmed -- left as a
# manual step for now; see server-setup-guide.md.
