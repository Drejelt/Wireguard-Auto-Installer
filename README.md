# Wireguard-Auto-Installer

> Turns a fresh Ubuntu/Debian VPS into a private VPN server with network-wide ad blocking and a self-hosted recursive resolver. One `setup.sh` brings up WireGuard, Pi-hole, Unbound, and a hardened ufw firewall.

![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04%20%7C%20Debian%2012-blue)
![Shell](https://img.shields.io/badge/shell-bash-green)
![License](https://img.shields.io/badge/license-MIT-lightgrey)

The installation is **idempotent** — re-running skips already-installed components, so the script is safe to run repeatedly. The Pi-hole admin panel is bound to the WireGuard interface only, so it's never exposed to the public internet.

---

## Contents

- [How it works](#how-it-works)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [What the script does](#what-the-script-does)
- [Security notes](#security-notes)
- [Adding clients](#adding-clients)
- [Management and diagnostics](#management-and-diagnostics)
- [File layout](#file-layout)
- [Troubleshooting](#troubleshooting)
- [License](#license)

---

## How it works

```
   Client (phone / laptop)
      │  WireGuard tunnel (UDP 51820)
      ▼
┌─────────────────────────────────────────────┐
│                    VPS                        │
│                                               │
│   wg0 ──► Pi-hole (:53) ──► Unbound (:5335)   │
│            ad blocking       recursive DNS    │
│                                  │            │
│                              root servers     │
│                                               │
│   NAT (MASQUERADE) ──► internet via eth0      │
└─────────────────────────────────────────────┘
```

Clients connect over WireGuard. Their DNS points at Pi-hole (on the tunnel IP), which filters ads and trackers and forwards clean queries to Unbound — a local recursive resolver that talks directly to the root servers, so there's no third-party upstream DNS. All other traffic is NATed out to the internet (full tunnel).

---

## Features

- **WireGuard server** — installed via the well-known `angristan/wireguard-install` script, verified by SHA-256 checksum before running.
- **Pi-hole v6** — network-wide ad/tracker blocking with the admin panel bound to the VPN interface only.
- **Unbound** — local recursive, DNSSEC-validating resolver (no third-party upstream).
- **ufw firewall** — default-deny inbound and forward, with explicit rules for SSH, WireGuard, and tunnel traffic; NAT rules injected into `before.rules`.
- **SSH hardening** — moves SSH to a custom port with config validation, automatic rollback if the new port doesn't come up, and the old port kept open during transition so you can't lock yourself out.
- **Curated block-lists** — adds a set of reputable lists (AdAway, Firebog, RPiList) automatically.
- **Self-signed TLS** — generates a certificate for the Pi-hole HTTPS panel.
- **Peer backups** — backs up `wg0.conf` and peer sections on every run (handy for migrations).
- **Client config auto-DNS** — finds existing WireGuard client configs, sets their DNS to the VPN resolver, and prints a QR code (terminal only — never written to the log).
- **Kernel check** — reboots if a newer kernel is staged, so you finish on the running kernel.
- **Idempotency** — state is tracked in `/etc/vps-setup.state`; re-running skips finished steps.

---

## Requirements

| Component | Minimum |
|-----------|---------|
| OS | Ubuntu 22.04 / Debian 12 (or `ID_LIKE=debian`) |
| Privileges | root |
| Network | A public IPv4 address (auto-detected) |
| Access | SSH access to the VPS |

> ⚠️ The script changes the SSH port. It keeps the old port open during the transition and rolls back automatically if the new port fails — but always open a **new** SSH session on the new port and confirm it works **before** closing your current one.

---

## Installation

```bash
github.com/Drejelt/Wireguard-Auto-Installer.git
cd Wireguard-Auto-Installer
sudo bash setup.sh
```

The script auto-detects your external IP, default interface, and current SSH port, then shows a component-status banner before asking for confirmation. If a newer kernel is installed, it reboots once — just run the script again afterwards.

### Re-running

```bash
sudo bash setup.sh
```

Finished components (`[✓]`) are skipped; only the missing ones (`[ ]`) run.

---

## What the script does

1. **Hostname** — resets to `localhost`.
2. **System update** — `apt upgrade` plus base tools; reboots if a new kernel is staged.
3. **Disable unused services** — masks `exim4`, `dovecot`, `proftpd`, `postfix` if present.
4. **SSH port** — moves SSH to the new port with validation and auto-rollback.
5. **IP forwarding** — enables IPv4/IPv6 forwarding.
6. **Firewall prep** — resets ufw to default-deny and injects WireGuard NAT rules.
7. **WireGuard** — downloads (checksum-verified) and runs the installer.
8. **Peer backup** — saves `wg0.conf` and peer sections.
9. **Client DNS** — points existing client configs at the VPN resolver, prints QR codes.
10. **Unbound** — installs and configures the recursive resolver on `127.0.0.1:5335`.
11. **Pi-hole** — unattended install, upstream set to Unbound.
12. **Pi-hole v6 config** — TLS cert + binds the panel to the VPN IP on ports 8080/8443.
13. **Block-lists** — adds curated lists and rebuilds gravity.
14. **Firewall activation** — enables ufw.
15. **Verification** — checks forwarding, WireGuard, Pi-hole, Unbound, ports, and firewall.

---

## Security notes

- The **Pi-hole admin panel is reachable only over the VPN** (bound to the WireGuard IP), not the public internet.
- **Unbound** removes reliance on a third-party upstream resolver and validates DNSSEC.
- The WireGuard installer is **checksum-verified** before execution; if the checksum changes upstream, the script warns and asks before continuing.
- `before.rules` is backed up before NAT rules are added; SSH and sysctl configs are backed up before edits (`*.bak.<timestamp>`).
- WireGuard private keys in client configs are **never written to the log** — QR codes are sent to `/dev/tty` only.

> Note: the pinned `WG_INSTALL_SHA256` is tied to a specific upstream revision. If the upstream installer updates, update the hash in the script to match the new release.

---

## Adding clients

After setup, add WireGuard clients by re-running the upstream installer:

```bash
curl -O https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh
bash wireguard-install.sh
```

Set each client's DNS to the VPN resolver IP (shown in the final summary) so ad blocking and Unbound apply.

---

## Management and diagnostics

```bash
# WireGuard state
sudo wg show

# Pi-hole status / password
pihole status
pihole setpassword

# Test ad blocking and the recursive resolver
dig ads.google.com @<wg_server_ip> +short      # expect 0.0.0.0
dig google.com @127.0.0.1 -p 5335 +short        # Unbound

# Firewall
sudo ufw status verbose

# Setup component status / logs
cat /etc/vps-setup.state
tail -f /var/log/vps-setup.log
```

---

## File layout

| Path | Purpose |
|------|---------|
| `/etc/vps-setup.state` | Installation state (idempotency) |
| `/var/log/vps-setup.log` | Setup log |
| `/etc/wireguard/wg0.conf` | WireGuard server config |
| `/etc/wireguard/backups/` | Peer backups (per run) |
| `/etc/unbound/unbound.conf.d/pi-hole.conf` | Unbound config |
| `/etc/pihole/` | Pi-hole config, TLS cert, gravity DB |
| `/etc/ufw/before.rules` | Firewall + NAT rules (backed up before edit) |
| `/etc/ssh/sshd_config.d/99-port.conf` | SSH port drop-in (when supported) |

---

## Troubleshooting

**Locked out after the SSH port change.**
The old port stays open during transition. Reconnect on it (`ssh -p <old_port> ...`). The script auto-rolls back if the new port never came up.

**Pi-hole panel won't load.**
It's bound to the VPN IP only — connect through WireGuard first, then open `http://<wg_server_ip>:8080/admin`. Check `journalctl -u pihole-FTL -n 20`.

**Unbound not resolving.**
Check `journalctl -u unbound -n 20`. A missing `root.hints` download isn't fatal — Unbound falls back to built-in root servers.

**Ads not blocked.**
Confirm the client's DNS is set to the VPN resolver IP, then test `dig ads.google.com @<wg_server_ip>` (should return `0.0.0.0`).

**Checksum mismatch on the WireGuard installer.**
The upstream script changed. Review the new version, then update `WG_INSTALL_SHA256` in the script to the verified hash.

**Reset the setup from scratch.**
Delete `/etc/vps-setup.state` and re-run `setup.sh`.

---

## License

MIT — see the [LICENSE](LICENSE) file.

> ⚠️ Use on servers you control and within the laws of your country. This project is provided "as is", without warranty. It also runs a third-party installer (`angristan/wireguard-install`) — review it before use.
