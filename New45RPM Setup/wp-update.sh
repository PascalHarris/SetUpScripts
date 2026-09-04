#!/bin/bash
#
# Unattended WordPress update, called by maintenance.sh. Snapshots the
# site's files immediately before touching anything, updates core, plugins
# and themes, then does a basic health check -- rolling the files back
# automatically if the site is broken afterwards.
#
# NOTE: this covers the files, not the database. The site's database is
# already covered by maintenance.sh's own quarterly maria-db dump (step 1);
# this script additionally exports just this one WordPress database to
# wp-pre-update-backup.sql as a quick single-site restore point, but does
# NOT auto-restore the database on failure -- see the health-check branch
# below for why.
#
# Usage: wp-update.sh <site-docroot-on-host> <phpfpm-container-name> <site-url>

set -uo pipefail

DOCROOT="$1"      # e.g. /home/pascalharris/lemp-compose/public/45rpm/htdocs
CONTAINER="$2"    # e.g. phpfpm-45rpm
SITE_URL="$3"     # e.g. https://45rpmsoftware.com

wp() {
  docker compose exec -T -u www-data "$CONTAINER" wp --path=/var/www/html "$@"
}

echo "-> Snapshotting $DOCROOT before update"
# Kept under the compose directory rather than /tmp so a failed run's
# snapshot survives for review and is covered by maintenance.sh's own
# retention pruning, rather than being at the mercy of /tmp's own cleanup
# timer, which doesn't know how long you might need to look at it.
SNAPSHOT_DIR="$(dirname "$0")/wp-snapshots"
mkdir -p "$SNAPSHOT_DIR"
snapshot="$SNAPSHOT_DIR/wp-snapshot-$(date +%Y%m%d_%H%M%S).tar.gz"
tar czf "$snapshot" -C "$DOCROOT" .
wp db export "wp-pre-update-backup.sql" || echo "   (DB export skipped -- see maintenance.sh's own DB dump instead)"

echo "-> Updating WordPress core, plugins and themes"
wp core update
wp plugin update --all
wp theme update --all

echo "-> Health check: $SITE_URL"
if curl -fsS -o /dev/null "$SITE_URL"; then
  echo "   Site responded normally after update."
  rm -f "$snapshot"
  exit 0
else
  echo "**ERROR** Site did not respond correctly after update -- rolling back files"
  rm -rf "${DOCROOT:?}"/*
  tar xzf "$snapshot" -C "$DOCROOT"
  echo "   Files rolled back from $snapshot."
  echo "   Database was NOT auto-restored -- a bad plugin/theme update can be"
  echo "   file-only, and restoring the DB unattended risks losing anything"
  echo "   written between the snapshot and the failure. Check"
  echo "   wp-pre-update-backup.sql and the quarterly maria-db dump by hand."
  exit 1
fi
