#!/bin/bash
#
# Create (or update) an SFTP-only user chrooted to a given directory.
#
# The chroot root itself (/home/<user>) must stay root:root and
# non-writable by anyone but root -- OpenSSH refuses ChrootDirectory
# otherwise. The directory the user actually reads/writes is a
# bind-mounted subdirectory of that chroot, named "files" here, so
# "updating the login directory" later is just re-pointing that bind
# mount -- nothing about the account, its key, or sshd config changes.
#
# Usage:
#   sudo ./manage-sftp-user.sh <username> <target-directory-on-host>
#
# Run again with the same username and a different target directory to
# repoint an existing user's landing directory elsewhere.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "Usage: $0 <username> <target-directory-on-host>" >&2
  exit 1
fi

USERNAME="$1"
TARGET_DIR="$2"
CHROOT_HOME="/home/$USERNAME"
LANDING_DIR="$CHROOT_HOME/files"

if [[ $(id -u) -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

getent group sftponly > /dev/null || groupadd sftponly
getent group webfiles > /dev/null || groupadd webfiles

if ! id "$USERNAME" &>/dev/null; then
  useradd -m -d "$CHROOT_HOME" -s /usr/sbin/nologin -G sftponly,webfiles "$USERNAME"
  mkdir -p "$CHROOT_HOME/.ssh"
  chmod 700 "$CHROOT_HOME/.ssh"
  touch "$CHROOT_HOME/.ssh/authorized_keys"
  chmod 600 "$CHROOT_HOME/.ssh/authorized_keys"
  chown -R "$USERNAME:$USERNAME" "$CHROOT_HOME/.ssh"
  echo "Created $USERNAME. Add their public key to $CHROOT_HOME/.ssh/authorized_keys"
fi

# ChrootDirectory requirement -- can't be relaxed for convenience, even
# though it means $USERNAME does not own their own home directory.
chown root:root "$CHROOT_HOME"
chmod 755 "$CHROOT_HOME"

mkdir -p "$LANDING_DIR" "$TARGET_DIR"

# Unmount and remove any previous binding before repointing it.
if mountpoint -q "$LANDING_DIR"; then
  umount "$LANDING_DIR"
fi
sed -i "\|[[:space:]]$LANDING_DIR[[:space:]]|d" /etc/fstab
echo "$TARGET_DIR $LANDING_DIR none bind 0 0" >> /etc/fstab
mount --bind "$TARGET_DIR" "$LANDING_DIR"

# Shared-group write access, so both this account and the phpfpm
# container (via group_add: in docker-compose.yml) can write here.
chgrp -R webfiles "$TARGET_DIR"
chmod -R 2775 "$TARGET_DIR"

gid=$(getent group webfiles | cut -d: -f3)
echo "$USERNAME now lands in $LANDING_DIR, bind-mounted from $TARGET_DIR"
echo "webfiles GID is $gid -- set WEBFILES_GID=$gid in .env next to docker-compose.yml"
echo "(only needed once, or again if this is the first time webfiles was created)."
