#!/bin/bash
# Muse Pi — first-boot setup.
#
# Phase 1 runs once via systemd.run from cmdline.txt: fast, local-only setup
# (optional boot-partition SSH key, SSH hardening, hostname, X11 desktop,
# setup wizard). It then hands the long network work to a oneshot systemd
# service (muse-setup.service, TimeoutStartSec=infinity) and exits, letting
# the cmdline's systemd.run_success_action=reboot reboot into phase 2.
#
# Phase 2 runs as muse-setup.service: it installs the screen-control tools,
# fetch tools and the Tailscale client (installed only — never joined; the
# owner joins from the setup wizard). Every step is guarded: a failure is
# logged and skipped, never fatal. Logs to /var/log/muse-firstrun.log.
#
# @HOSTNAME@ and @USERNAME@ are substituted by build-muse-pi.sh.

LOG=/var/log/muse-firstrun.log
exec >>"$LOG" 2>&1
set -x

PI_HOSTNAME="@HOSTNAME@"
PI_USERNAME="@USERNAME@"
STATE_DIR=/usr/local/muse-pi/state

find_self() {
  for c in /boot/firmware/firstrun.sh /boot/firstrun.sh "$0"; do
    [ -f "$c" ] && { echo "$c"; return; }
  done
  echo "$0"
}

find_boot_file() {
  # $1 = bare filename on the boot partition; echoes the first path that exists
  for c in "/boot/firmware/$1" "/boot/$1"; do
    [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

resolve_user() {
  TARGET_USER="$(getent passwd 1000 | cut -d: -f1)"
  [ -z "$TARGET_USER" ] && TARGET_USER="$PI_USERNAME"
  TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
  [ -z "$TARGET_HOME" ] && TARGET_HOME="/home/$TARGET_USER"
  export USER="$TARGET_USER"
}

clean_cmdline() {
  for CMDLINE in /boot/firmware/cmdline.txt /boot/cmdline.txt; do
    if [ -f "$CMDLINE" ]; then
      sed -i 's| systemd\.run=/boot/firstrun\.sh||g; s| systemd\.run_success_action=reboot||g; s| systemd\.unit=kernel-command-line\.target||g' "$CMDLINE" || true
      echo "cleaned $CMDLINE: $(cat "$CMDLINE")"
    fi
  done
  rm -f /boot/firstrun.sh /boot/firmware/firstrun.sh || true
}

# ---------------------------------------------------------------- phase 1
phase1() {
  echo "=== muse-firstrun PHASE 1 start: $(date -Is) ==="
  resolve_user
  # Wait briefly for the first-boot userconf step to create the user if needed.
  for i in $(seq 1 30); do
    getent passwd "$TARGET_USER" >/dev/null 2>&1 && break
    sleep 2
  done
  resolve_user
  echo "Target user: $TARGET_USER (home: $TARGET_HOME)"

  # Groups for the desktop user (admin + hardware access, like a normal
  # Raspberry Pi OS setup).
  if getent passwd "$TARGET_USER" >/dev/null 2>&1; then
    for g in sudo adm video gpio i2c spi; do
      if getent group "$g" >/dev/null 2>&1; then
        usermod -aG "$g" "$TARGET_USER" || true
      fi
    done
  else
    echo "WARNING: user $TARGET_USER does not exist; groups skipped"
  fi

  # Advanced key path: if the owner dropped a file named "authorized_keys"
  # on the boot partition before first boot, install it as the user's SSH
  # authorized keys and remember that the wizard's key step is done.
  mkdir -p "$STATE_DIR" || true
  BOOT_KEYS="$(find_boot_file authorized_keys || true)"
  if [ -n "$BOOT_KEYS" ] && getent passwd "$TARGET_USER" >/dev/null 2>&1 && [ -d "$TARGET_HOME" ]; then
    install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_HOME/.ssh" || true
    install -m 600 -o "$TARGET_USER" -g "$TARGET_USER" "$BOOT_KEYS" "$TARGET_HOME/.ssh/authorized_keys" || true
    touch "$STATE_DIR/key-from-boot" || true
    echo "installed boot-partition authorized_keys from $BOOT_KEYS"
  fi

  # SSH hardening drop-in (key-only), same as the copy baked into the image.
  mkdir -p /etc/ssh/sshd_config.d || true
  cat > /etc/ssh/sshd_config.d/60-muse-harden.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF

  # Hostname (via raspi-config AND directly).
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_hostname "$PI_HOSTNAME" || true
  fi
  echo "$PI_HOSTNAME" > /etc/hostname
  if grep -q "$PI_HOSTNAME" /etc/hosts; then
    :
  elif grep -q "^127\.0\.1\.1" /etc/hosts; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t$PI_HOSTNAME/" /etc/hosts
  else
    printf "127.0.1.1\t%s\n" "$PI_HOSTNAME" >> /etc/hosts
  fi
  hostname "$PI_HOSTNAME" || true

  # Desktop: autologin + X11 (not Wayland) + no screen blanking.
  # raspi-config source: do_wayland 1 = Wayland disabled -> X11 (LXDE-pi-x);
  # do_blanking 1 = screen blanking disabled.
  if command -v raspi-config >/dev/null 2>&1; then
    raspi-config nonint do_boot_behaviour B4 || true
    raspi-config nonint do_wayland 1 || true
    raspi-config nonint do_blanking 1 || true
  fi
  # Belt-and-braces equivalents of the raspi-config writes:
  if [ -f /etc/lightdm/lightdm.conf ]; then
    sed -i -e "s/^#\?user-session.*/user-session=LXDE-pi-x/" /etc/lightdm/lightdm.conf || true
    sed -i -e "s/^#\?autologin-session.*/autologin-session=LXDE-pi-x/" /etc/lightdm/lightdm.conf || true
    sed -i -e "s/^#\?autologin-user=.*/autologin-user=$TARGET_USER/" /etc/lightdm/lightdm.conf || true
  fi
  mkdir -p /etc/X11/xorg.conf.d || true
  cat > /etc/X11/xorg.conf.d/10-noblank.conf <<'EOF'
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
EOF

  # Setup wizard: make sure the shipped scripts are executable, mark setup
  # as pending (this flag is what makes the wizard open itself on the
  # desktop), and enable the wizard service.
  chmod 755 /usr/local/muse-pi/wizard/wizard.py \
            /usr/local/muse-pi/wizard/open-wizard.sh \
            /usr/local/muse-pi/extras/*.sh 2>/dev/null || true
  touch "$STATE_DIR/setup-pending" || true
  systemctl enable muse-pi-wizard.service || true
  # The desktop shortcut in the new user's home needs the execute bit to be
  # treated as a trusted launcher.
  if [ -d "$TARGET_HOME/Desktop" ]; then
    chmod 755 "$TARGET_HOME/Desktop/"*.desktop 2>/dev/null || true
    chown "$TARGET_USER:$TARGET_USER" "$TARGET_HOME/Desktop/"*.desktop 2>/dev/null || true
  fi

  # Install phase 2 as a proper oneshot service, then hand off via reboot.
  SELF="$(find_self)"
  install -m 755 "$SELF" /usr/local/sbin/muse-firstrun.sh || true
  cat > /etc/systemd/system/muse-setup.service <<'EOF'
[Unit]
Description=Muse Pi first-boot setup (phase 2)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=infinity
ExecStart=/usr/local/sbin/muse-firstrun.sh phase2

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload || true
  HANDOFF=0
  if [ -f /usr/local/sbin/muse-firstrun.sh ] && systemctl enable muse-setup.service; then
    HANDOFF=1
  fi
  clean_cmdline
  sync
  if [ "$HANDOFF" -eq 1 ]; then
    echo "=== PHASE 1 complete: $(date -Is) — rebooting into phase 2 service ==="
    exit 0
  fi
  echo "WARNING: service handoff failed — running phase 2 inline as fallback"
  phase2
}

# ---------------------------------------------------------------- phase 2
phase2_finish() {
  echo "=== muse-firstrun PHASE 2 finishing: $(date -Is) ==="
  systemctl disable muse-setup.service || true
  rm -f /etc/systemd/system/muse-setup.service /usr/local/sbin/muse-firstrun.sh || true
  systemctl daemon-reload || true
  sync
  echo "=== muse-firstrun complete — rebooting ==="
  reboot
}

phase2() {
  echo "=== muse-firstrun PHASE 2 start: $(date -Is) ==="
  resolve_user
  echo "Target user: $TARGET_USER (home: $TARGET_HOME)"
  export DEBIAN_FRONTEND=noninteractive

  # Packages, in guarded batches so one bad package sinks nothing else.
  # All of these are inert tools: nothing here runs as a service.
  if apt-get update; then
    apt-get install -y xdotool scrot wmctrl x11vnc fswebcam || echo "WARNING: batch A (screen tools) failed"
    apt-get install -y wakeonlan etherwake || echo "WARNING: batch B (wake-on-lan) failed"
    apt-get install -y rclone || echo "WARNING: batch C (file transfer) failed"
    apt-get install -y ffmpeg yt-dlp || echo "WARNING: batch D (media fetch) failed"
  else
    echo "WARNING: apt-get update failed (no network?) — package installs skipped"
  fi

  # Tailscale client (installed only — the owner joins it to their own
  # tailnet from the setup wizard; nothing is joined automatically).
  if command -v tailscale >/dev/null 2>&1; then
    echo "tailscale already present: $(tailscale version 2>/dev/null | head -n1)"
  elif curl -fsSL https://tailscale.com/install.sh | sh; then
    echo "tailscale installed (not started by us, not joined)"
  else
    echo "WARNING: tailscale install failed (continuing)"
  fi

  phase2_finish
}

# ---------------------------------------------------------------- dispatch
if [ "${1:-}" = "phase2" ]; then
  phase2
else
  phase1
fi
