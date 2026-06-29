#!/bin/bash
# =============================================================================
# server_hardening.sh
# Description: Applies baseline security hardening to a fresh RHEL/CentOS
#              or Debian/Ubuntu Linux server. Covers SSH, firewall, kernel
#              parameters, user accounts, and package hygiene.
#              Run as root on a newly provisioned server.
# Author:      Joshua Harvey
#
# WARNING: Review each section before running on an existing server.
#          Some changes (e.g. SSH port, root login) may lock you out
#          if not applied carefully.
# =============================================================================

set -euo pipefail

# --- Detect OS ---
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$ID
else
    echo "[ERROR] Cannot detect OS. Exiting."
    exit 1
fi

LOG_FILE="/var/log/server_hardening.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
SSH_PORT=22   # Change this if you want a non-standard SSH port

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo "[$TIMESTAMP] $1" | tee -a "$LOG_FILE"; }
ok()  { echo -e "${GREEN}[OK]${NC} $1"; log "OK - $1"; }
warn(){ echo -e "${YELLOW}[SKIP]${NC} $1"; log "SKIP - $1"; }
fail(){ echo -e "${RED}[FAIL]${NC} $1"; log "FAIL - $1"; }

# Must run as root
if [ "$EUID" -ne 0 ]; then
    echo "[ERROR] This script must be run as root." >&2
    exit 1
fi

echo "============================================"
echo " Server Hardening Script"
echo " OS: ${OS} | Host: $(hostname)"
echo " ${TIMESTAMP}"
echo "============================================"
log "--- Hardening started on $(hostname) ---"

# --- 1. System Updates ---
echo -e "\n[1/8] Applying system updates..."
if [[ "$OS" == "rhel" || "$OS" == "centos" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    yum update -y -q && ok "System packages updated" || fail "Package update failed"
    yum install -y -q firewalld fail2ban aide chrony || warn "Some packages may already be installed"
elif [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    apt-get update -qq && apt-get upgrade -y -qq && ok "System packages updated" || fail "Package update failed"
    apt-get install -y -qq ufw fail2ban aide chrony || warn "Some packages may already be installed"
fi

# --- 2. SSH Hardening ---
echo -e "\n[2/8] Hardening SSH configuration..."
SSH_CONFIG="/etc/ssh/sshd_config"
cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%Y%m%d)"

declare -A SSH_SETTINGS=(
    ["PermitRootLogin"]="no"
    ["PasswordAuthentication"]="no"
    ["X11Forwarding"]="no"
    ["MaxAuthTries"]="3"
    ["LoginGraceTime"]="30"
    ["AllowTcpForwarding"]="no"
    ["ClientAliveInterval"]="300"
    ["ClientAliveCountMax"]="2"
    ["Protocol"]="2"
    ["Port"]="$SSH_PORT"
)

for KEY in "${!SSH_SETTINGS[@]}"; do
    VALUE="${SSH_SETTINGS[$KEY]}"
    if grep -q "^#*\s*${KEY}" "$SSH_CONFIG"; then
        sed -i "s|^#*\s*${KEY}.*|${KEY} ${VALUE}|" "$SSH_CONFIG"
    else
        echo "${KEY} ${VALUE}" >> "$SSH_CONFIG"
    fi
done

systemctl restart sshd && ok "SSH hardened and restarted" || fail "SSH restart failed"

# --- 3. Firewall ---
echo -e "\n[3/8] Configuring firewall..."
if [[ "$OS" == "rhel" || "$OS" == "centos" || "$OS" == "rocky" || "$OS" == "almalinux" ]]; then
    systemctl enable --now firewalld
    firewall-cmd --set-default-zone=drop --permanent
    firewall-cmd --add-port="${SSH_PORT}/tcp" --permanent
    firewall-cmd --reload && ok "firewalld configured"
elif [[ "$OS" == "ubuntu" || "$OS" == "debian" ]]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "${SSH_PORT}/tcp"
    ufw --force enable && ok "ufw configured"
fi

# --- 4. Fail2Ban ---
echo -e "\n[4/8] Configuring Fail2Ban..."
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port    = ssh
logpath = %(sshd_log)s
backend = %(sshd_backend)s
EOF
systemctl enable --now fail2ban && ok "Fail2Ban enabled and configured" || warn "Fail2Ban setup skipped"

# --- 5. Kernel Parameter Hardening (sysctl) ---
echo -e "\n[5/8] Applying kernel hardening parameters..."
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# Disable IP forwarding (enable only if this is a router)
net.ipv4.ip_forward = 0

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Enable TCP SYN cookie protection
net.ipv4.tcp_syncookies = 1

# Log suspicious packets
net.ipv4.conf.all.log_martians = 1

# Disable accepting ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# Restrict dmesg to root
kernel.dmesg_restrict = 1

# Restrict kernel pointer exposure
kernel.kptr_restrict = 2
EOF
sysctl --system -q && ok "Kernel parameters applied"

# --- 6. Disable Unused Services ---
echo -e "\n[6/8] Disabling unused services..."
UNUSED_SERVICES=("bluetooth" "cups" "avahi-daemon" "rpcbind" "nfs" "telnet")
for SVC in "${UNUSED_SERVICES[@]}"; do
    if systemctl is-enabled "$SVC" &>/dev/null; then
        systemctl disable --now "$SVC" 2>/dev/null && ok "Disabled: ${SVC}"
    else
        warn "Not found/already disabled: ${SVC}"
    fi
done

# --- 7. Password Policy ---
echo -e "\n[7/8] Setting password policies..."
if [ -f /etc/login.defs ]; then
    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   7/'  /etc/login.defs
    sed -i 's/^PASS_MIN_LEN.*/PASS_MIN_LEN    12/'  /etc/login.defs
    ok "Password policy updated in /etc/login.defs"
fi

# --- 8. File Permission Hardening ---
echo -e "\n[8/8] Hardening file permissions..."
chmod 700 /root
chmod 600 /etc/crontab
chmod 700 /etc/cron.{d,daily,weekly,monthly,hourly} 2>/dev/null || true
chmod 644 /etc/passwd
chmod 000 /etc/shadow
ok "Critical file permissions set"

echo ""
echo "============================================"
echo -e " ${GREEN}Hardening complete.${NC}"
echo " Review log: ${LOG_FILE}"
echo " Reboot recommended to apply all changes."
echo "============================================"
log "--- Hardening complete on $(hostname) ---"
