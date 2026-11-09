# Muse Pi — A Raspberry Pi Desktop Your Muse Can Drive


## WHAT THIS IS

Muse Pi is a ready-made Raspberry Pi OS image that gives your Muse
(the AI assistant) its own small computer: a real desktop on your home
network that your Muse can see and operate — screenshots, mouse,
keyboard — so it can get through the things that block a cloud AI:
login pages with "are you human" checks, "new network detected"
warnings, and sites that refuse datacenter IP addresses.

It boots to a desktop, opens a short setup wizard, and about five
minutes later your Muse has a secure way in (SSH key only) and you
have a quiet little box that can also watch your network, sync files,
or wake your other computers.

Works on Raspberry Pi 3, 4 and 5. A Pi 4 or 5 is comfortable; a Pi 3
works but is slow — fine for logins and check-ins.

## WHAT YOU NEED

- A Raspberry Pi 3/4/5 with its proper power supply
- A microSD card, 16 GB or larger
- A wired Ethernet connection for the first boot (recommended)
- A monitor + keyboard for about five minutes (for the setup wizard)
- Your Muse, to give you its SSH public key

## SETUP — ABOUT 5 MINUTES

1. Flash muse-pi-raspios-arm64.img.xz onto the microSD card with
   Raspberry Pi Imager (or Balena Etcher). IMPORTANT: if the Imager
   offers its own customisation settings (hostname, user, Wi-Fi,
   SSH), SKIP them — this image is already customised, and applying
   Imager settings on top can break the setup.

2. Put the card in the Pi, plug in Ethernet and power. The Pi will
   restart itself a few times while it sets up (it is installing its
   tools). Give it 10-20 minutes on a Pi 4, longer on a Pi 3, until
   it settles on a desktop.

3. The setup wizard opens on the desktop. It walks you through:
   - "Give your Muse the keys": paste your Muse's SSH public key
     (ask it — it starts with "ssh-ed25519"; a public key is safe to
     share) and set your own password for the "muse" account.
   - "Connect Tailscale" (recommended): one click, then approve the
     sign-in link on your own Tailscale account. This is how your
     Muse reaches the Pi from anywhere, with no router ports opened.
   - Optional extras, only if you click for them: an Uptime Kuma
     status board, Pi-hole ad-blocking, Syncthing file sync, and a
     Tailscale subnet-router setup.
   Then click "Finish".

4. Tell your Muse: "the Pi is ready." The wizard's last page shows
   the Pi's address; your Muse connects as muse@<that address> with
   the key you gave it. From then on it can drive the Pi's desktop
   exactly like a person sitting at it.

After setup the Pi needs no monitor or keyboard at all — it renders a
full 1920x1080 desktop even with nothing plugged in, and everything
starts by itself after a power cut. You can also look at (or take
over) its desktop yourself with any VNC viewer over your Tailscale
network — ask your Muse to start the VNC server when you want it.

## ADVANCED: KEY WITHOUT THE WIZARD

If you would rather not paste a key into the wizard: before the first
boot, copy a text file named exactly "authorized_keys" (containing
your Muse's SSH public key, one line) onto the SD card's boot
partition — the small FAT partition that appears when you plug the
flashed card into a computer. On first boot it is installed as the
muse user's SSH key automatically, and the wizard shows its key step
as already done.

## SECURITY, PLAINLY

- This image contains NO SSH keys, NO known passwords, and NO
  accounts. The "muse" user is created on first boot with a random
  password that the image builder generated and threw away; the
  wizard is where you set your own.
- SSH accepts keys only — password logins are disabled from the very
  first second, before any setup script runs.
- Nothing joins anything automatically: Tailscale is installed but
  not connected until you click, and this Pi never phones home to the
  image's maker (there is no maker service — it is just Raspberry Pi
  OS with local customisations).
- The wizard listens only on the Pi itself (127.0.0.1), and switches
  itself off when you click Finish.
- Don't want to trust a prebuilt image? You don't have to:
  build-muse-pi.sh rebuilds this image from the official Raspberry
  Pi OS download, and every customisation is a readable script in
  the src/ folder.

## INSIDE THE IMAGE

- Raspberry Pi OS 64-bit (Debian Bookworm) with desktop
- Hostname "muse-pi", user "muse" (sudo + hardware groups)
- X11 desktop with autologin, screen blanking off, forced 1080p
- Tools (installed at first boot): xdotool, scrot, wmctrl, x11vnc,
  fswebcam, wakeonlan, etherwake, rclone, ffmpeg, yt-dlp, Tailscale
- Setup wizard + per-extra installer scripts in /usr/local/muse-pi/
  — read them on the Pi any time.

See MANIFEST.txt for the full inventory, ports and build details.
