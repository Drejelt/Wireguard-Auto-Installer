#!/bin/bash
# ============================================================
#  VPS Setup Script: WireGuard + Pi-hole + Unbound + ufw
#  Ubuntu 22.04 / Debian 12
#  Idempotent: re-running skips already-installed components.
# ============================================================

set -euo pipefail

# Non-interactive apt — otherwise an unattended run can hit a hung
# prompt (needrestart, dpkg config conflicts)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# ── Config ───────────────────────────────────────────────────
WG_PORT="51820"
WG_SUBNET="10.66.66.0/24"
PIHOLE_HTTP_PORT="8080"
PIHOLE_HTTPS_PORT="8443"
STATE_FILE="/etc/vps-setup.state"
LOG_FILE="/var/log/vps-setup.log"
WG_INSTALL_URL="https://raw.githubusercontent.com/angristan/wireguard-install/master/wireguard-install.sh"
WG_INSTALL_SHA256="b0a8ae07cef0f08bc4291a4618e4b4a5ecfcbc1ab24df3e0e57bef5a8bb60a52"
PIHOLE_INSTALL_URL="https://install.pi-hole.net"
PIHOLE_MIN_VERSION="6"

# SSH: new port. The current port is auto-detected below so we don't lock ourselves out.
SSH_PORT_NEW="1984"

# ── Logging ──────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1
echo ""
echo "════ Start: $(date '+%Y-%m-%d %H:%M:%S') ════"

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${BLUE}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
skip()    { echo -e "${CYAN}[~]${NC} $1 — already installed, skipping"; }
header()  { echo -e "\n${BOLD}${BLUE}══ $1 ══${NC}"; }

# ── Error trap with the command name ─────────────────────────
trap 'error "Error on line $LINENO: $BASH_COMMAND"' ERR

# ── Root check ───────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Run this script as root"

# ── Distro check ─────────────────────────────────────────────
if [ -f /etc/os-release ]; then
    source /etc/os-release
    if [[ "$ID" != "ubuntu" && "$ID" != "debian" && "${ID_LIKE:-}" != *"debian"* ]]; then
        error "Only Ubuntu/Debian are supported. Detected: $ID"
    fi
else
    error "Could not determine the distribution (/etc/os-release not found)"
fi

# ── State ────────────────────────────────────────────────────
touch "$STATE_FILE"
is_done()   { grep -q "^$1=done$" "$STATE_FILE" 2>/dev/null; }
mark_done() {
    local tmp; tmp=$(mktemp)
    grep -v "^$1=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    echo "$1=done" >> "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# ── Auto-detect ──────────────────────────────────────────────
SERVER_IP=$(
    curl -4s --max-time 5 https://icanhazip.com 2>/dev/null ||
    curl -4s --max-time 5 https://api.ipify.org 2>/dev/null
) || error "Could not determine the external IP"
SERVER_IP=$(echo "$SERVER_IP" | tr -d '[:space:]')

DEFAULT_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)

# Current sshd port — a chain of fallbacks, none of which trip set -e.
# sshd -T requires an explicit config or privileges on some systems and exits != 0,
# which under set -e would kill the script before the banner.
_get_ssh_port() {
    local p
    # 1) sshd -T — effective config (most accurate, but may not work)
    p=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
    [ -n "$p" ] && { echo "$p"; return; }
    # 2) grep the configs — static, but always available
    p=$(grep -ihE '^\s*Port\s+[0-9]+' \
            /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
        | awk '{print $NF}' | head -1)
    [ -n "$p" ] && { echo "$p"; return; }
    # 3) ss — what's actually being listened on right now
    p=$(ss -tlnp 2>/dev/null \
        | awk 'NR>1 {split($4,a,":"); port=a[length(a)]; if(port+0>0 && port+0<65536) print port}' \
        | grep -E '^(22|2222|22[0-9]{2})$' | head -1)
    [ -n "$p" ] && { echo "$p"; return; }
    echo "22"
}
SSH_PORT_CURRENT=$(_get_ssh_port 2>/dev/null || echo "22")
SSH_PORT_CURRENT=$(echo "$SSH_PORT_CURRENT" | tr -d '[:space:]')
SSH_PORT_CURRENT=${SSH_PORT_CURRENT:-22}

WG_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^wg' | head -1 || echo "wg0")
WG_SERVER_IP=$(ip addr show "$WG_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || echo "10.66.66.1")

# ── Banner ───────────────────────────────────────────────────
clear
echo -e "${BOLD}${BLUE}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║    VPS Setup: WireGuard + Pi-hole        ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  OS:           ${GREEN}${PRETTY_NAME}${NC}"
echo -e "  External IP:  ${GREEN}${SERVER_IP}${NC}"
echo -e "  Interface:    ${GREEN}${DEFAULT_IFACE}${NC}"
echo -e "  WG IP:        ${GREEN}${WG_SERVER_IP}${NC}"
echo -e "  WG port:      ${GREEN}${WG_PORT}${NC}"
echo -e "  SSH port:     ${GREEN}${SSH_PORT_CURRENT} → ${SSH_PORT_NEW}${NC}"
echo -e "  Log:          ${GREEN}${LOG_FILE}${NC}"
echo ""
echo -e "  ${BOLD}Component status:${NC}"
for c in hostname system_update services_disabled ssh wireguard unbound pihole blocklists cert ufw; do
    is_done "$c" && echo -e "    ${GREEN}[✓]${NC} $c" || echo -e "    ${RED}[ ]${NC} $c"
done
echo ""
read -rp "  Continue? (y/n): " CONFIRM
[ "$CONFIRM" != "y" ] && exit 0

# ════════════════════════════════════════════════════════════
# 1. HOSTNAME
# ════════════════════════════════════════════════════════════
header "Hostname"
if is_done "hostname"; then skip "hostname"
else
    hostnamectl set-hostname localhost
    sed -i '/127\.0\.1\.1/d' /etc/hosts
    echo "127.0.1.1 localhost" >> /etc/hosts
    success "Hostname reset → localhost"
    mark_done "hostname"
fi

# ════════════════════════════════════════════════════════════
# 2. SYSTEM UPDATE + KERNEL CHECK
# ════════════════════════════════════════════════════════════
header "System update"
if is_done "system_update"; then skip "system update"
else
    apt update -qq && apt upgrade -y -qq
    apt install -y -qq curl wget git dnsutils sqlite3 qrencode openssl ufw
    success "System updated"
    mark_done "system_update"
fi

RUNNING_KERNEL=$(uname -r)
EXPECTED_KERNEL=$(ls /boot/vmlinuz-* 2>/dev/null | sort -V | tail -1 | sed 's|/boot/vmlinuz-||')
if [ "$RUNNING_KERNEL" != "$EXPECTED_KERNEL" ]; then
    warn "New kernel: ${EXPECTED_KERNEL} (current: ${RUNNING_KERNEL})"
    warn "Rebooting in 5 seconds — run the script again after reboot!"
    sleep 5; reboot
fi
success "Kernel up to date: ${RUNNING_KERNEL}"

# ════════════════════════════════════════════════════════════
# 3. DISABLE UNUSED SERVICES
# ════════════════════════════════════════════════════════════
header "Disabling unused services"
if is_done "services_disabled"; then skip "services"
else
    for svc in exim4 dovecot proftpd postfix; do
        if systemctl list-units --full -all 2>/dev/null | grep -q "$svc"; then
            systemctl disable --now "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null || true
            info "  Disabled: $svc"
        fi
    done
    success "Unused services disabled"
    mark_done "services_disabled"
fi

# ════════════════════════════════════════════════════════════
# 3b. SSH PORT
# ════════════════════════════════════════════════════════════
header "SSH port → ${SSH_PORT_NEW}"
if is_done "ssh"; then
    skip "SSH port"
elif [ "$SSH_PORT_CURRENT" = "$SSH_PORT_NEW" ]; then
    success "SSH already listening on ${SSH_PORT_NEW}"
    mark_done "ssh"
else
    SSHD_DROPIN="/etc/ssh/sshd_config.d/99-port.conf"
    SSH_SVC=$(systemctl list-unit-files 2>/dev/null | awk '/^sshd?\.service/ {print $1; exit}')
    SSH_SVC=${SSH_SVC:-ssh}

    # The drop-in only works if the main config includes it.
    if grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' /etc/ssh/sshd_config 2>/dev/null; then
        mkdir -p /etc/ssh/sshd_config.d
        echo "Port ${SSH_PORT_NEW}" > "$SSHD_DROPIN"
        ROLLBACK="rm -f $SSHD_DROPIN"
    else
        # Fallback: edit the main config (with a backup)
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
        sed -i '/^[[:space:]]*#\?[[:space:]]*Port[[:space:]]/d' /etc/ssh/sshd_config
        echo "Port ${SSH_PORT_NEW}" >> /etc/ssh/sshd_config
        ROLLBACK="sed -i '/^Port ${SSH_PORT_NEW}\$/d' /etc/ssh/sshd_config; echo 'Port ${SSH_PORT_CURRENT}' >> /etc/ssh/sshd_config"
    fi

    # Validate BEFORE restarting — a broken config keeps sshd from coming up.
    if ! sshd -t 2>/dev/null; then
        warn "sshd -t rejected the config — rolling back"
        eval "$ROLLBACK"
        error "SSH config invalid, changes rolled back"
    fi

    # ufw should already allow the new port (see the Firewall section below),
    # but this section runs earlier — so add the rule right away
    # if ufw is already active (a re-run).
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${SSH_PORT_NEW}/tcp" comment 'SSH new' >/dev/null 2>&1 || true
    fi

    systemctl restart "$SSH_SVC" 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
    sleep 1

    # Auto-rollback if the new port isn't actually being listened on.
    if ss -tlnp 2>/dev/null | grep -qE "[:.]${SSH_PORT_NEW}\b"; then
        success "sshd listening on ${SSH_PORT_NEW} (current session on ${SSH_PORT_CURRENT} not dropped)"
        warn "IMPORTANT: open a NEW session on port ${SSH_PORT_NEW} BEFORE closing this one!"
        warn "  ssh -p ${SSH_PORT_NEW} root@${SERVER_IP}"
        warn "  Rollback: ${ROLLBACK} ; systemctl restart ${SSH_SVC}"
        mark_done "ssh"
    else
        warn "sshd did NOT come up on ${SSH_PORT_NEW} — rolling back to ${SSH_PORT_CURRENT}"
        eval "$ROLLBACK"
        systemctl restart "$SSH_SVC" 2>/dev/null || systemctl restart ssh
        warn "SSH stayed on ${SSH_PORT_CURRENT}, section not marked as done"
    fi
fi

# ════════════════════════════════════════════════════════════
# 4. IP FORWARDING
# ════════════════════════════════════════════════════════════
header "IP Forwarding"
cp /etc/sysctl.conf /etc/sysctl.conf.bak.$(date +%s) 2>/dev/null || true
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.all.forwarding=1" /etc/sysctl.conf || echo "net.ipv6.conf.all.forwarding=1" >> /etc/sysctl.conf
sysctl -p -q
info "  Backup: /etc/sysctl.conf.bak.*"
success "IP forwarding enabled"

# ════════════════════════════════════════════════════════════
# 5. UFW — preparation (activated at the end)
# ════════════════════════════════════════════════════════════
header "Firewall preparation"
if is_done "ufw"; then skip "ufw (config)"
else
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw default deny forward
    ufw allow ${SSH_PORT_NEW}/tcp comment 'SSH'
    # Keep the current port open during the transition so we don't lock ourselves out.
    # After verifying the new port, close it: ufw delete allow ${SSH_PORT_CURRENT}/tcp
    [ "$SSH_PORT_CURRENT" != "$SSH_PORT_NEW" ] && \
        ufw allow ${SSH_PORT_CURRENT}/tcp comment 'SSH old (transition)'
    ufw allow ${WG_PORT}/udp comment 'WireGuard'
    ufw allow in  on wg0 comment 'WireGuard tunnel'
    ufw allow out on wg0 comment 'WireGuard tunnel'

    # NAT for WG full-tunnel. Forward rules → *filter table,
    # MASQUERADE → a SEPARATE *nat table (otherwise iptables-restore fails).
    cp /etc/ufw/before.rules /etc/ufw/before.rules.bak.$(date +%s) 2>/dev/null || true
    if ! grep -q "WG-NAT" /etc/ufw/before.rules 2>/dev/null; then
        # 1) forward ACCEPT before the *filter table COMMIT (first COMMIT in the file)
        sed -i "0,/^COMMIT\$/s//# WG-NAT (forward)\n-A ufw-before-forward -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n-A ufw-before-forward -i wg0 -o ${DEFAULT_IFACE} -j ACCEPT\nCOMMIT/" \
            /etc/ufw/before.rules
        # 2) MASQUERADE in its own *nat table at the end of the file
        cat >> /etc/ufw/before.rules << EOF

# WG-NAT (nat)
*nat
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -s ${WG_SUBNET} -o ${DEFAULT_IFACE} -j MASQUERADE
COMMIT
EOF
        info "  Backup: /etc/ufw/before.rules.bak.*"
    fi
    success "Firewall prepared"
fi

# ════════════════════════════════════════════════════════════
# 6. WIREGUARD
# ════════════════════════════════════════════════════════════
header "WireGuard"
if is_done "wireguard"; then
    skip "WireGuard"
    WG_IFACE=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep '^wg' | head -1 || echo "wg0")
    WG_SERVER_IP=$(ip addr show "$WG_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || echo "10.66.66.1")
else
    if command -v wg &>/dev/null && ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -q '^wg'; then
        warn "WireGuard already installed but not marked — marking it"
        WG_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wg' | head -1 || echo "wg0")
        WG_SERVER_IP=$(ip addr show "$WG_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || echo "10.66.66.1")
        mark_done "wireguard"
    else
        info "Downloading wireguard-install.sh..."
        curl -sO "$WG_INSTALL_URL"
        ACTUAL_SHA=$(sha256sum wireguard-install.sh | awk '{print $1}')
        if [ "$ACTUAL_SHA" != "$WG_INSTALL_SHA256" ]; then
            warn "Checksum mismatch!"
            warn "  Expected: $WG_INSTALL_SHA256"
            warn "  Got:      $ACTUAL_SHA"
            read -rp "  Continue anyway? (y/n): " FORCE
            [ "$FORCE" != "y" ] && rm -f wireguard-install.sh && error "Installation cancelled"
        else
            success "Checksum verified"
        fi
        chmod +x wireguard-install.sh
        bash wireguard-install.sh
        rm -f wireguard-install.sh
        WG_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep '^wg' | head -1 || echo "wg0")
        WG_SERVER_IP=$(ip addr show "$WG_IFACE" 2>/dev/null | grep 'inet ' | awk '{print $2}' | cut -d/ -f1 || echo "10.66.66.1")
        success "WireGuard installed (${WG_IFACE}: ${WG_SERVER_IP})"
        mark_done "wireguard"
    fi
fi

# ════════════════════════════════════════════════════════════
# 7. BACKUP/RESTORE PEERS (useful for migrations)
# ════════════════════════════════════════════════════════════
header "WireGuard peers backup"
WG_BACKUP_DIR="/etc/wireguard/backups"
mkdir -p "$WG_BACKUP_DIR"
BACKUP_FILE="${WG_BACKUP_DIR}/wg0-backup-$(date +%Y%m%d-%H%M%S).conf"
if [ -f /etc/wireguard/wg0.conf ]; then
    cp /etc/wireguard/wg0.conf "$BACKUP_FILE"
    # Save just the peer sections separately for easy migration
    grep -A4 "^\[Peer\]" /etc/wireguard/wg0.conf > "${WG_BACKUP_DIR}/peers-only-$(date +%Y%m%d).conf" 2>/dev/null || true
    PEER_COUNT=$(grep -c "^\[Peer\]" /etc/wireguard/wg0.conf 2>/dev/null) || PEER_COUNT=0
    success "Backup created: $BACKUP_FILE (peers: ${PEER_COUNT})"
fi

# ════════════════════════════════════════════════════════════
# 8. DNS IN CLIENT CONFIGS
# ════════════════════════════════════════════════════════════
header "DNS in client configs"

CLIENT_CONFIGS=$(find /root /home -maxdepth 4 -name "*.conf" 2>/dev/null | while read -r f; do
    if grep -q "\[Interface\]" "$f" 2>/dev/null && \
       grep -q "\[Peer\]"      "$f" 2>/dev/null && \
       grep -q "PrivateKey"    "$f" 2>/dev/null && \
       grep -q "AllowedIPs"   "$f" 2>/dev/null; then
        echo "$f"
    fi
done || true)

if [ -n "$CLIENT_CONFIGS" ]; then
    while IFS= read -r conf; do
        CURRENT_DNS=$(grep "^DNS" "$conf" | awk '{print $3}' || true)
        if [ "$CURRENT_DNS" = "$WG_SERVER_IP" ]; then
            skip "DNS in $(basename "$conf") already ${WG_SERVER_IP}"
        else
            sed -i "s/^DNS = .*/DNS = ${WG_SERVER_IP}/" "$conf"
            success "  $(basename "$conf"): DNS ${CURRENT_DNS:-not set} → ${WG_SERVER_IP}"
            if command -v qrencode &>/dev/null; then
                info "  QR code for $(basename "$conf" .conf) (terminal only, not the log):"
                # > /dev/tty — otherwise the private key would leak into $LOG_FILE via tee
                qrencode -t ansiutf8 < "$conf" > /dev/tty 2>/dev/null || \
                    warn "  QR code too large — use the file instead: $conf"
            fi
        fi
    done <<< "$CLIENT_CONFIGS"
else
    warn "No client configs found"
fi

# ════════════════════════════════════════════════════════════
# 9. UNBOUND
# ════════════════════════════════════════════════════════════
header "Unbound"
if is_done "unbound"; then skip "Unbound"
else
    systemctl is-active --quiet unbound 2>/dev/null || apt install -y -qq unbound
    curl --fail -s -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.root \
        || warn "Could not download root.hints — Unbound starts with the built-in root servers"

    cat > /etc/unbound/unbound.conf.d/pi-hole.conf <<EOF
server:
    verbosity: 0
    interface: 127.0.0.1
    port: 5335
    do-ip4: yes
    do-udp: yes
    do-tcp: yes
    do-ip6: no

    private-address: 192.168.0.0/16
    private-address: 10.0.0.0/8
    private-address: 172.16.0.0/12

    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    # use-caps-for-id disabled — legacy, causes problems with some domains
    hide-identity: yes
    hide-version: yes

    cache-min-ttl: 3600
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes

    num-threads: 1
    msg-cache-slabs: 2
    rrset-cache-slabs: 2
    infra-cache-slabs: 2
    key-cache-slabs: 2
    rrset-cache-size: 100m
    msg-cache-size: 50m

    root-hints: /var/lib/unbound/root.hints
EOF

    systemctl enable unbound
    systemctl restart unbound
    sleep 2

    if dig google.com @127.0.0.1 -p 5335 +short +time=3 &>/dev/null; then
        success "Unbound running and resolving on 127.0.0.1:5335"
    else
        warn "Unbound running but not resolving — check: journalctl -u unbound -n 20"
    fi
    mark_done "unbound"
fi

# ════════════════════════════════════════════════════════════
# 10. PI-HOLE
# ════════════════════════════════════════════════════════════
header "Pi-hole"
if is_done "pihole"; then skip "Pi-hole"
else
    if command -v pihole &>/dev/null; then
        warn "Pi-hole already installed — skipping"
        mark_done "pihole"
    else
        mkdir -p /etc/pihole
        cat > /etc/pihole/setupVars.conf <<EOF
PIHOLE_INTERFACE=${WG_IFACE}
DNSMASQ_LISTENING=local
PIHOLE_DNS_1=127.0.0.1#5335
PIHOLE_DNS_2=
QUERY_LOGGING=true
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=false
CACHE_SIZE=10000
DNS_FQDN_REQUIRED=false
DNS_BOGUS_PRIV=true
DNSSEC=false
TEMPERATUREUNIT=C
WEBUIBOXEDLAYOUT=boxed
API_PRIVACY_MODE=false
EOF
        curl -sSL "$PIHOLE_INSTALL_URL" | bash /dev/stdin --unattended

        PIHOLE_VER=$(pihole -v 2>/dev/null | grep -oP 'v\K[0-9]+' | head -1 || echo "0")
        if [ "${PIHOLE_VER:-0}" -lt "$PIHOLE_MIN_VERSION" ] 2>/dev/null; then
            warn "Pi-hole version $PIHOLE_VER is below the minimum $PIHOLE_MIN_VERSION"
        else
            success "Pi-hole v${PIHOLE_VER} installed"
        fi
        mark_done "pihole"
    fi
fi

# ════════════════════════════════════════════════════════════
# 11. PI-HOLE V6 CONFIGURATION
# ════════════════════════════════════════════════════════════
header "Pi-hole v6 configuration"
if is_done "cert"; then skip "Certificate and toml config"
else
    # Certificate
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /tmp/pihole.key \
        -out /tmp/pihole.crt \
        -subj "/CN=${WG_SERVER_IP}" 2>/dev/null
    cat /tmp/pihole.crt /tmp/pihole.key > /etc/pihole/tls.pem
    chmod 640 /etc/pihole/tls.pem
    chown pihole:pihole /etc/pihole/tls.pem
    rm -f /tmp/pihole.key /tmp/pihole.crt
    success "Certificate created: /etc/pihole/tls.pem"

    if [ -f /etc/pihole/pihole.toml ]; then
        cp /etc/pihole/pihole.toml /etc/pihole/pihole.toml.bak.$(date +%s)
        info "  Backup: /etc/pihole/pihole.toml.bak.*"
        systemctl stop pihole-FTL

        # Pi-hole v6: write the config with the native CLI — it edits the right
        # sections precisely. A toml regex would also clobber the DNS port 53 in [dns], etc.
        pihole-FTL --config dns.upstreams '["127.0.0.1#5335"]'
        pihole-FTL --config webserver.port "${WG_SERVER_IP}:${PIHOLE_HTTP_PORT},${WG_SERVER_IP}:${PIHOLE_HTTPS_PORT}s"
        pihole-FTL --config webserver.tls.cert '/etc/pihole/tls.pem'
        info "  Config written: upstream=127.0.0.1#5335, bind=${WG_SERVER_IP}:${PIHOLE_HTTP_PORT}/${PIHOLE_HTTPS_PORT}"

        systemctl start pihole-FTL
        sleep 5

        if ss -tlnp | grep -q "${PIHOLE_HTTP_PORT}"; then
            success "Web interface on ${WG_SERVER_IP}:${PIHOLE_HTTP_PORT} / ${WG_SERVER_IP}:${PIHOLE_HTTPS_PORT}"
        else
            warn "Ports didn't come up — check: journalctl -u pihole-FTL -n 20"
        fi
    fi
    mark_done "cert"
fi

# ════════════════════════════════════════════════════════════
# 12. BLOCK-LISTS
# ════════════════════════════════════════════════════════════
header "Block-lists"
if is_done "blocklists"; then skip "Block-lists"
else
    if [ -f /etc/pihole/gravity.db ]; then
        sqlite3 /etc/pihole/gravity.db "
INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES
('https://adaway.org/hosts.txt', 1, 'auto-added'),
('https://v.firebog.net/hosts/AdguardDNS.txt', 1, 'auto-added'),
('https://v.firebog.net/hosts/Admiral.txt', 1, 'auto-added'),
('https://v.firebog.net/hosts/Easylist.txt', 1, 'auto-added'),
('https://v.firebog.net/hosts/Easyprivacy.txt', 1, 'auto-added'),
('https://v.firebog.net/hosts/Prigent-Ads.txt', 1, 'auto-added'),
('https://v.firebog.net/hosts/RPiList-Malware.txt', 1, 'auto-added'),
('https://v.firebog.net/hosts/RPiList-Phishing.txt', 1, 'auto-added');
"
        pihole -g -q 2>/dev/null || true
        success "Block-lists added and updated"
        mark_done "blocklists"
    else
        warn "gravity.db not found — add block-lists manually via the web panel"
    fi
fi

# ════════════════════════════════════════════════════════════
# 13. UFW — activation
# ════════════════════════════════════════════════════════════
header "Firewall (ufw) — activation"
if is_done "ufw"; then
    skip "ufw"
    ufw status | grep -q "Status: active" || { warn "ufw not active — enabling"; ufw --force enable; }
else
    ufw --force enable
    success "Firewall activated"
    mark_done "ufw"
fi

# ════════════════════════════════════════════════════════════
# 14. VERIFICATION
# ════════════════════════════════════════════════════════════
header "Installation check"

echo ""
info "IP Forwarding:"
sysctl net.ipv4.ip_forward | grep -q "= 1" && success "IPv4 forwarding enabled" || warn "IPv4 forwarding disabled"

echo ""
info "WireGuard:"
wg show 2>/dev/null && success "WireGuard running" || warn "WireGuard: problem"

echo ""
info "Pi-hole:"
pihole status 2>/dev/null || warn "Pi-hole: problem"

echo ""
info "Ad-blocking test:"
if dig ads.google.com @127.0.0.1 +short +time=3 2>/dev/null | grep -q "0.0.0.0"; then
    success "Pi-hole is blocking ads"
else
    warn "Test from a client: dig ads.google.com @${WG_SERVER_IP}"
fi

echo ""
info "Unbound test:"
if dig google.com @127.0.0.1 -p 5335 +short +time=3 2>/dev/null | grep -qE '^[0-9]'; then
    success "Unbound is resolving"
else
    warn "Unbound: problem — journalctl -u unbound -n 20"
fi

echo ""
info "Pi-hole web interface:"
if ss -tlnp | grep -q "${PIHOLE_HTTP_PORT}"; then
    success "Listening on ${WG_SERVER_IP}:${PIHOLE_HTTP_PORT} / ${WG_SERVER_IP}:${PIHOLE_HTTPS_PORT}"
    info "  http://${WG_SERVER_IP}:${PIHOLE_HTTP_PORT}/admin  (over VPN)"
else
    warn "Ports ${PIHOLE_HTTP_PORT}/${PIHOLE_HTTPS_PORT} not up"
fi

echo ""
info "Firewall:"
ufw status verbose | head -15

# ════════════════════════════════════════════════════════════
# DONE
# ════════════════════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════╗"
echo "  ║    Setup completed successfully!         ║"
echo "  ╚══════════════════════════════════════════╝"
echo -e "${NC}"
echo -e "  Pi-hole DNS:  ${GREEN}${WG_SERVER_IP}:53${NC}"
echo -e "  Pi-hole UI:   ${GREEN}http://${WG_SERVER_IP}:${PIHOLE_HTTP_PORT}/admin${NC}"
echo -e "  Pi-hole UI:   ${GREEN}https://${WG_SERVER_IP}:${PIHOLE_HTTPS_PORT}/admin${NC}"
echo -e "  Unbound:      ${GREEN}127.0.0.1:5335${NC}"
echo -e "  SSH port:     ${GREEN}${SSH_PORT_NEW}${NC}  ${YELLOW}(ssh -p ${SSH_PORT_NEW} root@${SERVER_IP})${NC}"
echo -e "  Log:          ${GREEN}${LOG_FILE}${NC}"
echo -e "  Peer backups: ${GREEN}/etc/wireguard/backups/${NC}"
echo ""
echo -e "  Add a WireGuard client:"
echo -e "  ${YELLOW}curl -O ${WG_INSTALL_URL} && bash wireguard-install.sh${NC}"
echo ""
echo -e "  Status: ${CYAN}cat ${STATE_FILE}${NC}"
echo ""
warn "Change the Pi-hole password: pihole setpassword"
echo ""
warn "SSH is now on port ${SSH_PORT_NEW}. Verify a NEW session BEFORE closing the current one:"
echo -e "  ${YELLOW}ssh -p ${SSH_PORT_NEW} root@${SERVER_IP}${NC}"
warn "Once confirmed — close the old port: ufw delete allow ${SSH_PORT_CURRENT}/tcp"
echo ""
echo "════ Finished: $(date '+%Y-%m-%d %H:%M:%S') ════"
