#!/usr/bin/env bash
# ============================================================================
# build-muse-pi.sh — build the Muse Pi image
#
# Takes the official Raspberry Pi OS (64-bit, with desktop, Debian
# Bookworm) image and customizes it into "Muse Pi": a Pi that boots to a
# ready desktop which a Muse (an AI assistant with an SSH key) can see
# and drive remotely — screenshots, mouse, keyboard — over SSH/Tailscale.
#
# What the customization does:
#   * hostname + a local user (created on first boot, random throwaway
#     password — see userconf.txt note below)
#   * SSH on, key-only from the very start (no password logins, ever)
#   * desktop autologin on an X11 session, screen blanking off, and a
#     forced 1920x1080 HDMI mode so the desktop renders at full size
#     even with NO monitor attached (headless remote control)
#   * a two-phase first-boot script (src/firstrun.sh) that finishes the
#     setup and installs inert tools: xdotool, scrot, wmctrl, x11vnc,
#     fswebcam, wakeonlan, etherwake, rclone, ffmpeg, yt-dlp, and the
#     Tailscale client (installed only — it never joins anything by
#     itself)
#   * a friendly setup wizard (src/wizard/) that opens on the desktop at
#     first login and walks the owner through giving their Muse the
#     SSH key, setting their own password, joining Tailscale, and
#     optionally installing extras (src/extras/: Uptime Kuma, Pi-hole,
#     Syncthing, subnet router) — each extra is a separate readable
#     script, installed only when the owner clicks for it
#
# What it does NOT contain: no SSH keys, no passwords anyone knows (the
# userconf password is generated randomly during the build and thrown
# away), no accounts, no network joins. An owner can optionally drop a
# file named "authorized_keys" on the boot partition before first boot
# and it will be installed as the user's SSH key automatically.
#
# Image surgery is done WITHOUT mounting (containers/VMs often cannot):
# the FAT boot partition is edited with mtools — or, if mtools is
# missing, with python3 + pyfatfs via src/fatboot.py — and the ext4
# root filesystem with debugfs.
#
# Requirements: bash, curl, xz, openssl, sha256sum, debugfs (e2fsprogs),
# python3, and either mtools or pyfatfs (pip install pyfatfs).
#
# The sources under src/ contain @HOSTNAME@ / @USERNAME@ placeholders;
# this script substitutes the parameters below into staged copies.
# ============================================================================

set -euo pipefail

# --------------------------- parameters -------------------------------------
# Edit these, or set them in the environment before running.
BASE_IMG="${BASE_IMG:-2025-05-13-raspios-bookworm-arm64.img.xz}"
BASE_URL="${BASE_URL:-https://downloads.raspberrypi.com/raspios_arm64/images/raspios_arm64-2025-05-13/2025-05-13-raspios-bookworm-arm64.img.xz}"
BASE_SHA256="${BASE_SHA256:-1162c2a47c2ebda34c7ebeafc4afb71910a05b368d0721ae3736928e60ba5047}"
OUT_NAME="${OUT_NAME:-muse-pi-raspios-arm64}"
PI_HOSTNAME="${PI_HOSTNAME:-muse-pi}"
PI_USERNAME="${PI_USERNAME:-muse}"
# ----------------------------------------------------------------------------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$PI_USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "PI_USERNAME '$PI_USERNAME' is not a valid Linux username"
[[ "$PI_HOSTNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "PI_HOSTNAME '$PI_HOSTNAME' is not a valid hostname"

for tool in xz openssl sha256sum debugfs e2fsck python3 dd sed; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done

# Boot-partition editor: prefer mtools, fall back to pyfatfs.
if command -v mcopy >/dev/null 2>&1; then
  BOOT_TOOL="mtools"
elif python3 -c 'import pyfatfs' >/dev/null 2>&1; then
  BOOT_TOOL="pyfatfs"
else
  die "need mtools or pyfatfs (pip install pyfatfs) to edit the boot partition"
fi
echo ">> boot partition editor: $BOOT_TOOL"

# --------------------------- base image -------------------------------------
cd "$HERE"
if [ ! -f "$BASE_IMG" ]; then
  echo ">> downloading base image from $BASE_URL"
  curl -fSL -o "$BASE_IMG" "$BASE_URL"
fi
echo ">> verifying base image sha256"
echo "$BASE_SHA256  $BASE_IMG" | sha256sum -c - >/dev/null || die "base image checksum mismatch"
echo ">> base image OK"

WORK="$(mktemp -d -p "$HERE" .build-XXXXXXXX)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/stage"
mkdir -p "$STAGE/extras"

render() { # render <source> <dest> [mode] — substitute @HOSTNAME@/@USERNAME@
  sed -e "s/@HOSTNAME@/$PI_HOSTNAME/g" -e "s/@USERNAME@/$PI_USERNAME/g" "$1" > "$2"
  [ -n "${3:-}" ] && chmod "$3" "$2"
  return 0
}

# --------------------------- decompress + map -------------------------------
echo ">> decompressing base image"
xz -dkc "$BASE_IMG" > "$WORK/disk.img"

echo ">> reading partition table"
eval "$(python3 - "$WORK/disk.img" <<'PYEOF'
import struct, sys
with open(sys.argv[1], 'rb') as f:
    mbr = f.read(512)
if mbr[510:512] != b'\x55\xaa':
    sys.exit('not an MBR disk image')
parts = []
for i in range(4):
    e = mbr[0x1BE + i*16: 0x1BE + (i+1)*16]
    typ = e[4]
    start, count = struct.unpack_from('<II', e, 8)
    if typ:
        parts.append((start, count))
if len(parts) < 2:
    sys.exit('expected at least 2 partitions')
print(f"BOOT_START={parts[0][0]}")
print(f"BOOT_SECTORS={parts[0][1]}")
print(f"ROOT_START={parts[1][0]}")
print(f"ROOT_SECTORS={parts[1][1]}")
PYEOF
)"
echo ">> boot partition: start=$BOOT_START sectors=$BOOT_SECTORS; root: start=$ROOT_START sectors=$ROOT_SECTORS"

dd if="$WORK/disk.img" of="$WORK/boot.fat"  bs=512 skip="$BOOT_START" count="$BOOT_SECTORS" status=none
dd if="$WORK/disk.img" of="$WORK/rootfs.img" bs=512 skip="$ROOT_START" count="$ROOT_SECTORS" status=none

# --------------------------- boot partition ---------------------------------
BOOT_FAT="$WORK/boot.fat"
fat_cat() { # fat_cat <name> — write file contents to stdout
  if [ "$BOOT_TOOL" = mtools ]; then mtype -i "$BOOT_FAT" "::/$1"; else python3 "$SRC/fatboot.py" "$BOOT_FAT" cat "$1"; fi
}
fat_put() { # fat_put <local-file> <name>
  if [ "$BOOT_TOOL" = mtools ]; then
    mdel -i "$BOOT_FAT" "::/$2" >/dev/null 2>&1 || true
    mcopy -i "$BOOT_FAT" "$1" "::/$2"
  else
    python3 "$SRC/fatboot.py" "$BOOT_FAT" put "$1" "$2"
  fi
}

echo ">> customizing boot partition"

# cmdline.txt: keep the original line, append the first-boot hook.
fat_cat cmdline.txt > "$WORK/cmdline.orig"
CMDLINE_LINE="$(cat "$WORK/cmdline.orig")"
printf '%s %s\n' "$CMDLINE_LINE" \
  "systemd.run=/boot/firstrun.sh systemd.run_success_action=reboot systemd.unit=kernel-command-line.target" \
  > "$WORK/cmdline.txt"
fat_put "$WORK/cmdline.txt" cmdline.txt

# config.txt: force a 1920x1080 HDMI mode so the desktop exists at full
# size even with no monitor attached (headless remote control).
fat_cat config.txt > "$WORK/config.txt"
cat >> "$WORK/config.txt" <<'EOF'

# Muse Pi: headless desktop guarantee — render a 1920x1080 desktop even
# with no monitor attached, so remote control always has a full screen.
hdmi_force_hotplug=1
hdmi_group=1
hdmi_mode=16
EOF
fat_put "$WORK/config.txt" config.txt

# ssh: empty file that switches the SSH server on.
: > "$WORK/ssh"
fat_put "$WORK/ssh" ssh

# userconf.txt: create the user on first boot with a random password
# whose plaintext is generated here and discarded — nobody knows it,
# and SSH is key-only anyway. The setup wizard lets the owner set
# their own password.
PW="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24)"
HASH="$(printf '%s' "$PW" | openssl passwd -6 -stdin)"
printf '%s:%s\n' "$PI_USERNAME" "$HASH" > "$WORK/userconf.txt"
unset PW HASH
fat_put "$WORK/userconf.txt" userconf.txt

# firstrun.sh: the two-phase first-boot setup.
render "$SRC/firstrun.sh" "$STAGE/firstrun.sh" 755
fat_put "$STAGE/firstrun.sh" firstrun.sh

# Verify the boot partition edits took.
fat_cat cmdline.txt | grep -q 'systemd.run=/boot/firstrun.sh' || die "cmdline.txt customization failed"
fat_cat config.txt  | grep -q 'hdmi_force_hotplug=1'         || die "config.txt customization failed"
fat_cat userconf.txt | grep -q "^$PI_USERNAME:"              || die "userconf.txt customization failed"
fat_cat firstrun.sh | grep -q 'Muse Pi'                      || die "firstrun.sh missing from boot partition"
fat_cat ssh >/dev/null                                       || die "ssh flag file missing from boot partition"
echo ">> boot partition OK"

# --------------------------- root filesystem --------------------------------
echo ">> customizing root filesystem with debugfs"

render "$SRC/wizard/wizard.py"     "$STAGE/wizard.py" 755
render "$SRC/wizard/open-wizard.sh" "$STAGE/open-wizard.sh" 755
for f in "$SRC"/extras/*.sh; do
  render "$f" "$STAGE/extras/$(basename "$f")" 755
done
cp "$SRC/60-muse-harden.conf"    "$STAGE/60-muse-harden.conf"
cp "$SRC/muse-pi-wizard.service" "$STAGE/muse-pi-wizard.service"
cp "$SRC/skel/muse-pi-setup.desktop"  "$STAGE/muse-pi-setup.desktop"
cp "$SRC/skel/Muse-Pi-Setup.desktop"  "$STAGE/Muse-Pi-Setup.desktop"
printf '%s\n' "$PI_HOSTNAME" > "$STAGE/hostname"

# /etc/hosts: take the stock file and point 127.0.1.1 at our hostname.
debugfs -R "dump /etc/hosts $WORK/hosts.new" "$WORK/rootfs.img" >/dev/null 2>&1 \
  || die "could not read /etc/hosts from the base root filesystem"
if grep -q '^127\.0\.1\.1' "$WORK/hosts.new"; then
  sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$PI_HOSTNAME/" "$WORK/hosts.new"
else
  printf '127.0.1.1\t%s\n' "$PI_HOSTNAME" >> "$WORK/hosts.new"
fi
cp "$WORK/hosts.new" "$STAGE/hosts"

cat > "$WORK/debugfs.cmds" <<EOF
rm /etc/hostname
write $STAGE/hostname /etc/hostname
rm /etc/hosts
write $STAGE/hosts /etc/hosts
mkdir /etc/ssh/sshd_config.d
write $STAGE/60-muse-harden.conf /etc/ssh/sshd_config.d/60-muse-harden.conf
mkdir /usr/local/muse-pi
mkdir /usr/local/muse-pi/wizard
mkdir /usr/local/muse-pi/extras
mkdir /usr/local/muse-pi/state
write $STAGE/wizard.py /usr/local/muse-pi/wizard/wizard.py
write $STAGE/open-wizard.sh /usr/local/muse-pi/wizard/open-wizard.sh
write $STAGE/extras/uptime-kuma.sh /usr/local/muse-pi/extras/uptime-kuma.sh
write $STAGE/extras/pihole.sh /usr/local/muse-pi/extras/pihole.sh
write $STAGE/extras/syncthing.sh /usr/local/muse-pi/extras/syncthing.sh
write $STAGE/extras/subnet-router.sh /usr/local/muse-pi/extras/subnet-router.sh
write $STAGE/muse-pi-wizard.service /etc/systemd/system/muse-pi-wizard.service
mkdir /etc/skel/.config
mkdir /etc/skel/.config/autostart
mkdir /etc/skel/Desktop
write $STAGE/muse-pi-setup.desktop /etc/skel/.config/autostart/muse-pi-setup.desktop
write $STAGE/Muse-Pi-Setup.desktop /etc/skel/Desktop/Muse-Pi-Setup.desktop
sif /usr/local/muse-pi/wizard/wizard.py mode 0100755
sif /usr/local/muse-pi/wizard/open-wizard.sh mode 0100755
sif /usr/local/muse-pi/extras/uptime-kuma.sh mode 0100755
sif /usr/local/muse-pi/extras/pihole.sh mode 0100755
sif /usr/local/muse-pi/extras/syncthing.sh mode 0100755
sif /usr/local/muse-pi/extras/subnet-router.sh mode 0100755
EOF
debugfs -w -f "$WORK/debugfs.cmds" "$WORK/rootfs.img" > "$WORK/debugfs.log" 2>&1 || true

# Verify the important writes actually landed.
[ "$(debugfs -R 'cat /etc/hostname' "$WORK/rootfs.img" 2>/dev/null)" = "$PI_HOSTNAME" ] \
  || die "/etc/hostname was not written"
debugfs -R 'cat /etc/ssh/sshd_config.d/60-muse-harden.conf' "$WORK/rootfs.img" 2>/dev/null \
  | grep -q 'PasswordAuthentication no' || die "sshd hardening drop-in was not written"
debugfs -R 'ls -l /usr/local/muse-pi/wizard' "$WORK/rootfs.img" 2>/dev/null \
  | grep -q 'wizard.py' || die "wizard files were not written"
debugfs -R 'ls -l /etc/skel/.config/autostart' "$WORK/rootfs.img" 2>/dev/null \
  | grep -q 'muse-pi-setup.desktop' || die "wizard autostart entry was not written"
debugfs -R 'ls -l /usr/local/muse-pi/extras' "$WORK/rootfs.img" 2>/dev/null \
  | grep -q 'pihole.sh' || die "extras scripts were not written"

echo ">> checking root filesystem integrity"
e2fsck -fn "$WORK/rootfs.img" > "$WORK/e2fsck.log" 2>&1 || die "e2fsck reports problems (see build log)"

# --------------------------- assemble + compress ----------------------------
echo ">> writing partitions back into the disk image"
dd if="$WORK/boot.fat"  of="$WORK/disk.img" bs=512 seek="$BOOT_START" conv=notrunc status=none
dd if="$WORK/rootfs.img" of="$WORK/disk.img" bs=512 seek="$ROOT_START" conv=notrunc status=none

OUT="$HERE/$OUT_NAME.img.xz"
echo ">> compressing to $OUT"
xz -T0 -6 -c "$WORK/disk.img" > "$OUT"

SIZE="$(stat -c %s "$OUT")"
SHA="$(sha256sum "$OUT" | awk '{print $1}')"
echo "=========================================================="
echo "Built:  $OUT"
echo "Size:   $SIZE bytes"
echo "SHA256: $SHA"
echo "=========================================================="
