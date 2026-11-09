# Muse Pi v1.0 — first release

**Download:** `muse-pi-raspios-arm64.img.xz` (1,395,806,828 bytes)
**SHA256:** `d6a2f496ae4f072fdbd40b24f31699c30f46eb9c8c1dc53c82a896be5d115fa9`

A ready-made Raspberry Pi OS image that gives your Muse its own small
computer: a real desktop on your home network that it can see and drive
(screenshots, mouse, keyboard) — for the login walls, "new network"
checks, and datacenter-IP refusals that block a cloud AI.

## Quick start
1. Flash the image with Raspberry Pi Imager ("Use custom") — choose
   **NO customization** when asked; the image is already set up.
2. Card in the Pi, Ethernet + power in. Let it settle (it restarts a
   few times while installing its tools; 10-20 min on a Pi 4).
3. The setup wizard opens on the desktop: paste your Muse's SSH
   public key, set your own password, optionally connect Tailscale
   and tick any extras. About five minutes with a screen.
4. Tell your Muse: "the Pi is ready."

Full details in the repo README and MANIFEST. Don't want to trust a
prebuilt image? `build-muse-pi.sh` rebuilds it from the official
Raspberry Pi OS download (Bookworm, 2025-05-13) — every customization
is a readable script in `src/`.

Works on Pi 3 / 4 / 5 (Pi 4+ comfortable; Pi 3 slow but fine for
logins and check-ins). No keys, accounts, or credentials are baked
into the image; SSH is key-only from the first second.
