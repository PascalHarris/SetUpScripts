#!/usr/bin/env bash
# =============================================================================
# bootstrap-pi-rip.sh
#
# One-shot installer that takes a fresh Raspberry Pi OS install to a working
# AppleTalk PostScript RIP for an Epson WF-3540.
#
# It performs the heavy, unattended build steps that setup-pi-rip.sh
# deliberately omits:
#   Phase 1  apt dependencies + CUPS + escpr + Ghostscript
#   Phase 2  build & load the 'appletalk' kernel module (DDP)
#   Phase 3  build & install Netatalk 2.x (atalkd + papd) from source
#   Phase 4  hand off to the interactive setup-pi-rip.sh (printer/zone/names)
#
# Run order (IMPORTANT):
#   1. Flash Raspberry Pi OS, boot, connect the Pi by ETHERNET.
#   2. sudo apt update && sudo apt full-upgrade -y && sudo reboot
#        ^ do this FIRST so you build the kernel module against the kernel you
#          will actually be running. This script refuses to proceed if the
#          running kernel is older than the newest installed one.
#   3. cd into this folder (it must contain setup-pi-rip.sh and the .ppd).
#   4. sudo ./bootstrap-pi-rip.sh
#
# Honesty notes (read these):
#   - The kernel-module build (Phase 2) is the fragile step. rpi-source must be
#     able to fetch source matching your running kernel, and the build gcc must
#     be compatible. If Phase 2 fails, this script STOPS rather than leaving you
#     half-configured; see the README fallback (full kernel rebuild) in that
#     case. This phase could NOT be tested by the author against a real Pi.
#   - On an original Pi 1 (ARMv6, single core) Phases 2-3 may take well over an
#     hour combined. Building on a faster Pi or cross-compiling is reasonable.
#   - Re-running is safe: each phase is skipped if already satisfied.
#
# Options:
#   --hold-kernel   apt-mark hold the kernel/bootloader so a future
#                   'apt upgrade' cannot replace the kernel and orphan the
#                   appletalk module. Recommended for a set-and-forget box.
#   --skip-config   build everything but do NOT run the interactive
#                   setup-pi-rip.sh at the end.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly NETATALK_REPO="https://github.com/rdmark/Netatalk-2.x.git"
readonly NETATALK_BRANCH="branch-netatalk-2-x"
readonly BUILD_ROOT="/usr/local/src"
readonly RPI_SOURCE_URL="https://raw.githubusercontent.com/RPi-Distro/rpi-source/master/rpi-source"

HOLD_KERNEL=0
SKIP_CONFIG=0
for arg in "$@"; do
    case "$arg" in
        --hold-kernel) HOLD_KERNEL=1 ;;
        --skip-config) SKIP_CONFIG=1 ;;
        *) printf 'Unknown option: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

die()   { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
phase() { printf '\n========== %s ==========\n' "$*"; }
note()  { printf '  -> %s\n' "$*"; }
warn()  { printf 'WARNING: %s\n' "$*" >&2; }

# ----------------------------------------------------------------------------
# Phase 0: pre-flight
# ----------------------------------------------------------------------------
phase "Phase 0: pre-flight checks"
[[ "$(id -u)" -eq 0 ]] || die "Run as root: sudo $0"

# Sanity: this is meant for Raspberry Pi OS / Debian-family.
command -v apt-get >/dev/null 2>&1 || die "apt-get not found; this script targets Raspberry Pi OS / Debian."

# Refuse to build a module against a kernel you are about to replace on reboot.
RUNNING_KREL="$(uname -r)"
note "Running kernel: $RUNNING_KREL"
if command -v dpkg >/dev/null 2>&1; then
    # Best-effort: warn if a newer kernel image is installed but not running.
    if compgen -G "/boot/vmlinuz-*" >/dev/null; then
        NEWEST_INSTALLED="$(for f in /boot/vmlinuz-*; do printf '%s\n' "${f#/boot/vmlinuz-}"; done | sort -V | tail -n1)"
        if [[ -n "$NEWEST_INSTALLED" && "$NEWEST_INSTALLED" != "$RUNNING_KREL" ]]; then
            warn "Newest installed kernel ($NEWEST_INSTALLED) != running ($RUNNING_KREL)."
            warn "Reboot first, or the appletalk module may not load after a reboot."
            confirm_reply=""
            read -r -p "Continue anyway? [y/N]: " confirm_reply || true
            [[ "${confirm_reply,,}" == y* ]] || die "Aborting. Reboot, then re-run."
        fi
    fi
fi

# Required companion files must be present for Phase 4.
[[ -f "$SCRIPT_DIR/setup-pi-rip.sh" ]] || warn "setup-pi-rip.sh not found beside this script; Phase 4 will be skipped."

# ----------------------------------------------------------------------------
# Phase 1: packages
# ----------------------------------------------------------------------------
phase "Phase 1: installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
# Printing stack + build toolchain + Netatalk 2.x build dependencies.
apt-get install -y \
    cups cups-client cups-filters ghostscript printer-driver-escpr avahi-daemon \
    build-essential git autoconf automake libtool pkg-config bc bison flex \
    libssl-dev libgcrypt-dev libdb-dev libwrap0-dev libpam0g-dev libcups2-dev \
    raspberrypi-kernel-headers wget
note "Packages installed."

systemctl enable --now cups >/dev/null 2>&1 || warn "Could not enable cups via systemctl; check manually."

# ----------------------------------------------------------------------------
# Phase 2: AppleTalk kernel module
# ----------------------------------------------------------------------------
phase "Phase 2: AppleTalk kernel module"
if modprobe appletalk 2>/dev/null && lsmod | grep -q '^appletalk'; then
    note "appletalk module already available. Skipping build."
else
    note "appletalk module not available; building it."

    # Fetch rpi-source if absent.
    if ! command -v rpi-source >/dev/null 2>&1; then
        wget -qO /usr/local/bin/rpi-source "$RPI_SOURCE_URL"
        chmod +x /usr/local/bin/rpi-source
    fi

    # rpi-source prepares a kernel tree matching the running kernel. It is happier
    # run as the invoking (non-root) user, but works as root with --skip-gcc on
    # some images. We try the normal path and fall back.
    note "Preparing kernel source with rpi-source (this can be slow)..."
    if ! rpi-source --default-config 2>/dev/null; then
        rpi-source --skip-gcc || die "rpi-source failed. Use the full-kernel-rebuild fallback in the README."
    fi

    # Locate the prepared tree.
    KTREE=""
    for cand in "$HOME"/linux* /root/linux* "${SUDO_USER:+/home/$SUDO_USER/linux*}"; do
        for d in $cand; do [[ -d "$d" && -f "$d/Makefile" ]] && KTREE="$d"; done
    done
    [[ -n "$KTREE" ]] || die "Could not locate the kernel source tree rpi-source created."
    note "Kernel tree: $KTREE"

    cd "$KTREE"
    # Enable AppleTalk DDP as a module, then build just that module.
    scripts/config --module CONFIG_ATALK || die "Failed to set CONFIG_ATALK=m."
    make olddefconfig
    make modules_prepare
    make "M=net/appletalk" modules || die "appletalk module build failed (see output above)."
    make "M=net/appletalk" modules_install
    depmod -a

    modprobe appletalk || die "Built the module but modprobe failed (vermagic/gcc mismatch likely). See README."
    lsmod | grep -q '^appletalk' || die "appletalk still not loaded after modprobe."
    note "appletalk module built and loaded."
fi

# Load at boot.
echo appletalk > /etc/modules-load.d/appletalk.conf
note "appletalk will load at boot."

if [[ "$HOLD_KERNEL" -eq 1 ]]; then
    if apt-mark hold raspberrypi-kernel raspberrypi-bootloader 2>/dev/null; then
        note "Held kernel/bootloader packages."
    else
        warn "Could not hold kernel packages (names may differ on your image)."
    fi
fi

# ----------------------------------------------------------------------------
# Phase 3: Netatalk 2.x (atalkd + papd)
# ----------------------------------------------------------------------------
phase "Phase 3: Netatalk 2.x"
if command -v atalkd >/dev/null 2>&1 && command -v papd >/dev/null 2>&1 \
   && afpd -V 2>/dev/null | grep -qi 'AppleTalk'; then
    note "Netatalk 2.x with AppleTalk already installed. Skipping build."
else
    mkdir -p "$BUILD_ROOT"
    cd "$BUILD_ROOT"
    if [[ ! -d "$BUILD_ROOT/Netatalk-2.x" ]]; then
        git clone "$NETATALK_REPO"
    fi
    cd "$BUILD_ROOT/Netatalk-2.x"
    git fetch --all --tags || true
    git checkout "$NETATALK_BRANCH" 2>/dev/null || warn "Branch $NETATALK_BRANCH not found; using default branch."

    if [[ -x ./bootstrap ]]; then
        ./bootstrap
    else
        autoreconf -fi
    fi

    # AppleTalk/papd are enabled by default in this fork; we only pick init style
    # and config locations. --disable-zeroconf keeps the build lean for a
    # print-only box (no AFP/Avahi needed for RIP duty).
    ./configure \
        --enable-systemd \
        --sysconfdir=/etc \
        --with-uams-path=/usr/lib/netatalk \
        --disable-zeroconf \
        || die "Netatalk configure failed. Check missing -dev packages in the output."

    make -j"$(nproc)" || die "Netatalk build failed."
    make install
    ldconfig || true

    afpd -V 2>/dev/null | grep -qi 'AppleTalk' \
        || die "Netatalk built but AppleTalk transport is not reported by 'afpd -V'."
    note "Netatalk 2.x installed with AppleTalk support."
fi

# ----------------------------------------------------------------------------
# Phase 4: interactive configuration
# ----------------------------------------------------------------------------
phase "Phase 4: printer / zone / name configuration"
if [[ "$SKIP_CONFIG" -eq 1 ]]; then
    note "--skip-config given. Run ./setup-pi-rip.sh yourself when ready."
    exit 0
fi
if [[ -x "$SCRIPT_DIR/setup-pi-rip.sh" ]]; then
    exec "$SCRIPT_DIR/setup-pi-rip.sh"
elif [[ -f "$SCRIPT_DIR/setup-pi-rip.sh" ]]; then
    exec bash "$SCRIPT_DIR/setup-pi-rip.sh"
else
    warn "setup-pi-rip.sh not found. Builds are complete; run the configurator separately."
    exit 0
fi
