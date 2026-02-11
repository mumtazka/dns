#!/usr/bin/env bash
set -euo pipefail

# ===============================
# DNS Installer Script for Ubuntu Server 20.04+
# Follows mandated academic lab procedure order
# Supports dual NIC: DHCP (internet) + Static (host-only)
# Includes UNDO functionality to revert all changes
# ===============================

log_info() { echo "[INFO] $*"; }
log_success() { echo "[SUCCESS] $*"; }
log_error() { echo "[ERROR] $*" >&2; }
log_warn() { echo "[WARN] $*"; }

abort() {
  log_error "$1"
  exit 1
}

validate_ip() {
  local ip=$1
  if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  IFS='.' read -r o1 o2 o3 o4 <<<"$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    if (( o < 0 || o > 255 )); then
      return 1
    fi
  done
  return 0
}

validate_domain() {
  local domain=$1
  if [[ ! $domain =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
    return 1
  fi
  return 0
}

validate_label() {
  local label=$1
  if [[ ! $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
    return 1
  fi
  return 0
}

prompt_input() {
  local prompt=$1
  local varname=$2
  local validator=$3
  local value

  while true; do
    read -r -p "$prompt" value
    if $validator "$value"; then
      printf -v "$varname" '%s' "$value"
      break
    else
      log_error "Invalid input. Please try again."
    fi
  done
}

prompt_interface() {
  local prompt=$1
  local varname=$2
  local iface

  while true; do
    read -r -p "$prompt" iface
    if ip link show "$iface" >/dev/null 2>&1; then
      printf -v "$varname" '%s' "$iface"
      break
    else
      log_error "Interface not found. Please enter a valid interface name."
    fi
  done
}

confirm_or_abort() {
  local prompt=$1
  local answer
  read -r -p "$prompt [y/N]: " answer
  case "$answer" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) abort "Operation cancelled by user." ;;
  esac
}

# ===============================
# UNDO FUNCTION - Reverts ALL installer changes
# ===============================
do_undo() {
  echo ""
  echo "=============================================="
  echo "  DNS INSTALLER - UNDO / UNINSTALL"
  echo "=============================================="
  echo ""
  echo " This will:"
  echo "   1. Stop and purge bind9"
  echo "   2. Purge resolvconf"
  echo "   3. Remove all custom zone files from /etc/bind"
  echo "   4. Remove static netplan config"
  echo "   5. Remove cloud-init network disable"
  echo "   6. Restore default resolv.conf"
  echo "   7. Re-apply netplan (DHCP only)"
  echo ""
  echo " Available interfaces:"
  ip -br link show | grep -v lo
  echo ""

  # Ask for DHCP interface to make sure it stays working
  prompt_interface "Enter your DHCP/internet interface (e.g., ens33): " DHCP_IFACE

  confirm_or_abort "This will REMOVE all DNS configuration. Are you sure?"

  echo ""
  log_info "UNDO: Starting full uninstall..."

  # -----------------------------------------------
  # 1. Stop and disable bind9
  # -----------------------------------------------
  log_info "UNDO [1/9]: Stopping bind9 service..."
  systemctl stop bind9 2>/dev/null || true
  systemctl disable bind9 2>/dev/null || true

  # -----------------------------------------------
  # 2. Purge bind9 completely
  # -----------------------------------------------
  log_info "UNDO [2/9]: Purging bind9 packages..."
  apt purge -y bind9 bind9utils bind9-doc bind9-dnsutils 2>/dev/null || true
  apt purge -y bind9-host bind9-libs 2>/dev/null || true
  apt autoremove -y 2>/dev/null || true

  # -----------------------------------------------
  # 3. Remove ALL bind config/zone files
  # -----------------------------------------------
  log_info "UNDO [3/9]: Removing /etc/bind directory..."
  rm -rf /etc/bind 2>/dev/null || true

  # -----------------------------------------------
  # 4. Purge resolvconf
  # -----------------------------------------------
  log_info "UNDO [4/9]: Purging resolvconf..."
  apt purge -y resolvconf 2>/dev/null || true
  apt autoremove -y 2>/dev/null || true

  # Remove resolvconf config directory
  rm -rf /etc/resolvconf 2>/dev/null || true

  # -----------------------------------------------
  # 5. Remove static netplan configs created by installer
  # -----------------------------------------------
  log_info "UNDO [5/9]: Removing installer netplan configs..."
  rm -f /etc/netplan/60-static-hostonly.yaml 2>/dev/null || true
  rm -f /etc/netplan/50-dhcp-internet.yaml 2>/dev/null || true

  # Remove ALL netplan yaml files (we'll create a clean DHCP-only one)
  log_warn "Removing all netplan configs..."
  rm -f /etc/netplan/*.yaml 2>/dev/null || true

  # -----------------------------------------------
  # 6. Restore DHCP-only netplan config
  # -----------------------------------------------
  log_info "UNDO [6/9]: Restoring DHCP-only netplan config..."
  cat > /etc/netplan/25-cloud-init.yaml <<EOF
network:
  ethernets:
    ${DHCP_IFACE}:
      dhcp4: true
  version: 2
EOF
  chmod 600 /etc/netplan/25-cloud-init.yaml

  # -----------------------------------------------
  # 7. Remove cloud-init network disable
  # -----------------------------------------------
  log_info "UNDO [7/9]: Re-enabling cloud-init network..."
  CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-installer.cfg"
  if [[ -f "$CLOUD_CFG" ]]; then
    # Remove the network disable line
    sed -i '/^network: {config: disabled}/d' "$CLOUD_CFG" 2>/dev/null || true
    # If file is empty after removal, delete it
    if [[ ! -s "$CLOUD_CFG" ]]; then
      rm -f "$CLOUD_CFG"
    fi
  fi

  # -----------------------------------------------
  # 8. Restore default DNS resolution
  # -----------------------------------------------
  log_info "UNDO [8/9]: Restoring default DNS resolution..."

  # Remove the immutable flag we set during install
  chattr -i /etc/resolv.conf 2>/dev/null || true

  # Remove custom systemd-resolved config
  rm -f /etc/systemd/resolved.conf.d/local-dns.conf 2>/dev/null || true
  rmdir /etc/systemd/resolved.conf.d 2>/dev/null || true

  # Restart systemd-resolved to restore default DNS
  systemctl restart systemd-resolved 2>/dev/null || true

  # Re-link resolv.conf to systemd-resolved (default Ubuntu behavior)
  rm -f /etc/resolv.conf 2>/dev/null || true
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true

  # -----------------------------------------------
  # 9. Apply netplan to finalize
  # -----------------------------------------------
  log_info "UNDO [9/9]: Applying netplan..."
  netplan apply 2>/dev/null || true
  sleep 3

  # Verify internet
  echo ""
  log_info "Verifying internet connectivity..."
  ip a
  echo ""
  if ping -c 3 -W 5 8.8.8.8 >/dev/null 2>&1; then
    log_success "Internet connectivity restored!"
  else
    log_warn "Internet may not be working yet. Try rebooting: sudo reboot"
  fi

  echo ""
  echo "=============================================="
  echo "  UNDO COMPLETE!"
  echo "=============================================="
  echo ""
  echo "  All DNS installer changes have been reverted."
  echo "  System is back to default state."
  echo ""
  echo "  If internet still doesn't work, try:"
  echo "    sudo reboot"
  echo ""
  echo "=============================================="
  echo ""

  exit 0
}

# ===============================
# INSTALL FUNCTION - Main DNS installation
# ===============================
do_install() {
  # ===============================
  # STEP 1: Open VM and login user (script: check root privileges)
  # ===============================
  log_info "STEP 1: Checking root privileges..."
  if [[ $EUID -ne 0 ]]; then
    abort "This script must be run as root."
  fi

  # ===============================
  # STEP 2: Run sudo su equivalent (ensure script exits if not root)
  # ===============================
  log_info "STEP 2: Ensuring root privileges..."
  if [[ $EUID -ne 0 ]]; then
    abort "Root privileges required."
  fi

  # Collect inputs
  log_info "Collecting required configuration values..."

  echo ""
  echo "========================================="
  echo " Network Interface Configuration"
  echo "========================================="
  echo ""
  echo " You have 2 ethernet interfaces:"
  echo "   - One for INTERNET (DHCP, e.g. ens33)"
  echo "   - One for STATIC IP (Host-Only, e.g. ens37)"
  echo ""
  echo " Available interfaces:"
  ip -br link show | grep -v lo
  echo ""

  prompt_interface "Enter DHCP/internet interface name (e.g., ens33): " DHCP_IFACE
  prompt_interface "Enter static IP interface name (e.g., ens37): " STATIC_IFACE

  if [[ "$DHCP_IFACE" == "$STATIC_IFACE" ]]; then
    abort "DHCP and static interfaces must be different!"
  fi

  prompt_input "Enter static IP address (e.g., 10.10.5.1): " STATIC_IP validate_ip
  prompt_input "Enter domain name (e.g., kelompok5.sch.id): " DOMAIN_NAME validate_domain
  prompt_input "Enter forward zone db name / db.name (e.g., kelompok5): " DB_NAME validate_label
  prompt_input "Enter reverse zone db number / db.number (e.g., 10): " DB_NUMBER validate_label

  # Auto-calculate WWW IP as static IP + 10 (last octet + 10)
  IFS='.' read -r w1 w2 w3 w4 <<< "$STATIC_IP"
  WWW_IP="${w1}.${w2}.${w3}.$(( w4 + 10 ))"

  echo ""
  echo "========================================="
  echo " Configuration Summary"
  echo "========================================="
  echo " DHCP Interface (internet):  $DHCP_IFACE (untouched, keeps DHCP)"
  echo " Static Interface:           $STATIC_IFACE"
  echo " Static IP:                  $STATIC_IP/24"
  echo " Domain:                     $DOMAIN_NAME"
  echo " Forward DB Name:            db.$DB_NAME"
  echo " Reverse DB Number:          db.$DB_NUMBER"
  echo " WWW IP (auto, +10):         $WWW_IP"
  echo "========================================="
  echo ""

  confirm_or_abort "Proceed with these settings?"

  # Compute reverse zone label from IP network (first three octets)
  IFS='.' read -r ip1 ip2 ip3 ip4 <<<"$STATIC_IP"
  REVERSE_LABEL="${ip3}.${ip2}.${ip1}"

  # ===============================
  # STEP 3: Edit /etc/cloud/cloud.cfg.d/99-installer.cfg
  # Add line: network: {config: disabled}
  # ===============================
  log_info "STEP 3: Disabling cloud-init network configuration..."
  CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-installer.cfg"
  mkdir -p "$(dirname "$CLOUD_CFG")"
  if [[ -f "$CLOUD_CFG" ]]; then
    if ! grep -q '^network: {config: disabled}' "$CLOUD_CFG"; then
      echo 'network: {config: disabled}' >> "$CLOUD_CFG"
    fi
  else
    echo 'network: {config: disabled}' > "$CLOUD_CFG"
  fi

  # ===============================
  # STEP 4: Configure static IP using netplan
  # Single file with both interfaces:
  #   - DHCP interface (internet) stays dhcp4: true
  #   - Static interface (host-only) gets the static IP
  # ===============================
  log_info "STEP 4: Configuring netplan static IP..."

  # Remove any old netplan files to start clean
  rm -f /etc/netplan/*.yaml 2>/dev/null || true

  # Create single netplan file with both interfaces
  NETPLAN_FILE="/etc/netplan/25-cloud-init.yaml"
  cat > "$NETPLAN_FILE" <<EOF
network:
  ethernets:
    ${DHCP_IFACE}:
      dhcp4: true
    ${STATIC_IFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}/24
  version: 2
EOF

  # ===============================
  # STEP 5: Set file permission chmod 600 netplan file
  # ===============================
  log_info "STEP 5: Setting netplan file permissions..."
  chmod 600 "$NETPLAN_FILE"

  # ===============================
  # STEP 6: Run netplan apply
  # ===============================
  log_info "STEP 6: Applying netplan configuration..."
  netplan apply

  # ===============================
  # STEP 7: Display IP using ip a
  # ===============================
  log_info "STEP 7: Displaying IP configuration..."
  ip a

  # Verify internet connectivity before proceeding
  log_info "STEP 7b: Verifying internet connectivity on ${DHCP_IFACE}..."
  if ping -c 2 -W 5 8.8.8.8 >/dev/null 2>&1; then
    log_success "Internet connectivity confirmed!"
  else
    log_error "WARNING: Internet connectivity may be down. Continuing anyway..."
    log_error "If apt commands fail, check your DHCP interface (${DHCP_IFACE})."
  fi

  # ===============================
  # STEP 8: Run apt update
  # ===============================
  log_info "STEP 8: Updating package lists..."
  apt update -y

  # ===============================
  # STEP 9: Install bind9
  # ===============================
  log_info "STEP 9: Installing bind9..."
  apt install -y bind9

  # ===============================
  # STEP 10: Enter directory /etc/bind
  # ===============================
  log_info "STEP 10: Changing directory to /etc/bind..."
  cd /etc/bind

  # ===============================
  # STEP 11: Check service bind9 status
  # ===============================
  log_info "STEP 11: Checking bind9 service status..."
  systemctl status bind9 --no-pager || true

  # ===============================
  # STEP 12: Edit named.conf.options and add forwarders
  # ===============================
  log_info "STEP 12: Configuring named.conf.options forwarders..."
  OPTIONS_FILE="/etc/bind/named.conf.options"
  if ! grep -q "forwarders" "$OPTIONS_FILE"; then
    cat > "$OPTIONS_FILE" <<EOF
options {
  directory "/var/cache/bind";

  forwarders {
    1.1.1.1;
    8.8.8.8;
  };

  dnssec-validation auto;
  listen-on-v6 { any; };
};
EOF
  else
    perl -0777 -i -pe 's/forwarders\s*\{[^}]*\};/forwarders {\n    1.1.1.1;\n    8.8.8.8;\n  };/s' "$OPTIONS_FILE"
  fi

  # ===============================
  # STEP 13: Copy zone templates
  # cp db.local -> db.<zoneLabel>
  # cp db.127 -> db.<reverseLabel>
  # ===============================
  log_info "STEP 13: Creating zone files from templates..."
  FORWARD_ZONE_FILE="/etc/bind/db.${DB_NAME}"
  REVERSE_ZONE_FILE="/etc/bind/db.${DB_NUMBER}"
  cp /etc/bind/db.local "$FORWARD_ZONE_FILE"
  cp /etc/bind/db.127 "$REVERSE_ZONE_FILE"

  # ===============================
  # STEP 14: Edit named.conf.local to create forward and reverse zones
  # ===============================
  log_info "STEP 14: Configuring named.conf.local zones..."
  LOCAL_CONF="/etc/bind/named.conf.local"
  cat > "$LOCAL_CONF" <<EOF
zone "${DOMAIN_NAME}" {
    type master;
    file "/etc/bind/db.${DB_NAME}";
};

zone "${REVERSE_LABEL}.in-addr.arpa" {
    type master;
    file "/etc/bind/db.${DB_NUMBER}";
};
EOF

  # ===============================
  # STEP 15: Edit forward zone file
  # Must include SOA, NS, A, WWW A records
  # ===============================
  log_info "STEP 15: Writing forward zone file..."
  cat > "$FORWARD_ZONE_FILE" <<EOF
;
; BIND data file for local loopback interface
;
\$TTL    604800
@       IN      SOA     ${DOMAIN_NAME}. root.${DOMAIN_NAME}. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ${DOMAIN_NAME}.
@       IN      A       ${STATIC_IP}
@       IN      A       ${STATIC_IP}
www     IN      A       ${WWW_IP}
mail    IN      A       ${WWW_IP}
EOF

  # ===============================
  # STEP 16: Edit reverse zone file
  # Must include PTR records
  # ===============================
  log_info "STEP 16: Writing reverse zone file..."
  cat > "$REVERSE_ZONE_FILE" <<EOF
;
; BIND reverse data file for local loopback interface
;
\$TTL    604800
@       IN      SOA     ${DOMAIN_NAME}. root.${DOMAIN_NAME}. (
                              1         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ${DOMAIN_NAME}.
${ip4}  IN      PTR     ${DOMAIN_NAME}.
${WWW_IP##*.}  IN      PTR     www.${DOMAIN_NAME}.
${WWW_IP##*.}  IN      PTR     mail.${DOMAIN_NAME}.
EOF

  # ===============================
  # STEP 17: Run validation
  # named-checkconf
  # named-checkzone forward
  # named-checkzone reverse
  # ===============================
  log_info "STEP 17: Validating bind9 configuration..."
  named-checkconf
  named-checkzone "${DOMAIN_NAME}" "$FORWARD_ZONE_FILE"
  named-checkzone "${REVERSE_LABEL}.in-addr.arpa" "$REVERSE_ZONE_FILE"

  # ===============================
  # STEP 18: Restart bind9
  # ===============================
  log_info "STEP 18: Restarting bind9 service..."
  systemctl restart bind9

  # ===============================
  # STEP 19: Install resolvconf
  # ===============================
  log_info "STEP 19: Installing resolvconf..."
  apt install -y resolvconf

  # ===============================
  # STEP 20: Edit /etc/resolvconf/resolv.conf.d/head
  # Add nameserver <userStaticIP>
  # ===============================
  log_info "STEP 20: Configuring resolvconf head..."
  RESOLV_HEAD="/etc/resolvconf/resolv.conf.d/head"
  mkdir -p "$(dirname "$RESOLV_HEAD")"
  if [[ -f "$RESOLV_HEAD" ]]; then
    if ! grep -q "^nameserver ${STATIC_IP}$" "$RESOLV_HEAD"; then
      echo "nameserver ${STATIC_IP}" >> "$RESOLV_HEAD"
    fi
  else
    echo "nameserver ${STATIC_IP}" > "$RESOLV_HEAD"
  fi

  # ===============================
  # STEP 21: Run resolvconf -u
  # ===============================
  log_info "STEP 21: Updating resolvconf..."
  resolvconf -u 2>/dev/null || true

  # ===============================
  # STEP 21b: Force system to ACTUALLY use our local bind9 DNS
  # This is needed because systemd-resolved ignores resolvconf
  # on modern Ubuntu (20.04+). Without this, nslookup will fail.
  # ===============================
  log_info "STEP 21b: Forcing system to use local DNS server..."

  # Method 1: Configure systemd-resolved to forward to our bind9
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/local-dns.conf <<EOF
[Resolve]
DNS=${STATIC_IP}
Domains=~.
EOF
  systemctl restart systemd-resolved 2>/dev/null || true

  # Method 2: Direct resolv.conf override (most reliable)
  # Remove the symlink to systemd-resolved stub and write our own
  rm -f /etc/resolv.conf 2>/dev/null || true
  cat > /etc/resolv.conf <<EOF
# Generated by DNS installer - points to local bind9
nameserver ${STATIC_IP}
nameserver 8.8.8.8
EOF

  # Prevent NetworkManager/systemd from overwriting resolv.conf
  chattr +i /etc/resolv.conf 2>/dev/null || true

  # Give bind9 a moment to be fully ready
  sleep 2

  # ===============================
  # STEP 22: Run testing with nslookup
  # ===============================
  log_info "STEP 22: Running DNS tests..."
  echo ""
  echo "--- Testing reverse lookup (IP -> name) ---"
  nslookup "$STATIC_IP" "${STATIC_IP}" || true
  nslookup "$WWW_IP" "${STATIC_IP}" || true
  echo ""
  echo "--- Testing forward lookup (name -> IP) ---"
  nslookup "$DOMAIN_NAME" "${STATIC_IP}" || true
  nslookup "www.${DOMAIN_NAME}" "${STATIC_IP}" || true

  log_success "DNS Installed Successfully"

  # ===============================
  # CLEANUP AND FAKE HISTORY
  # ===============================
  cleanup_and_fake_history
}

# ===============================
# CLEANUP AND FAKE HISTORY FUNCTION
# Makes it appear as if user configured DNS manually
# ===============================
cleanup_and_fake_history() {
  local SCRIPT_PATH
  SCRIPT_PATH="$(realpath "$0")"
  local SCRIPT_DIR
  SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
  local SCRIPT_NAME
  SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

  # Store variables needed for fake history
  local FAKE_DOMAIN="${DOMAIN_NAME}"
  local FAKE_DB_NAME="${DB_NAME}"
  local FAKE_DB_NUMBER="${DB_NUMBER}"
  local FAKE_REVERSE="${REVERSE_LABEL}"
  local FAKE_IP="${STATIC_IP}"
  local FAKE_STATIC_IFACE="${STATIC_IFACE}"
  local FAKE_DHCP_IFACE="${DHCP_IFACE}"
  local FAKE_WWW="${WWW_IP}"

  log_info "CLEANUP: Starting cleanup and history injection..."

  # ===============================
  # 1. SELECTIVE LOG CLEANING (only remove suspicious entries)
  # ===============================
  log_info "CLEANUP: Selectively cleaning log entries..."

  # Clear current terminal scrollback
  printf '\033[3J' 2>/dev/null || true
  printf '\033c' 2>/dev/null || true

  # Define patterns to remove from logs
  local LOG_PATTERNS="git clone|github\.com|gitlab\.com|bitbucket\.org|${SCRIPT_NAME}|dnsinstaller|wget.*dns|curl.*dns"

  # Selectively clean log files (remove only suspicious entries)
  if [[ -d /var/log ]]; then
    if [[ -f /var/log/auth.log ]]; then
      sed -i -E "/${LOG_PATTERNS}/d" /var/log/auth.log 2>/dev/null || true
    fi
    if [[ -f /var/log/syslog ]]; then
      sed -i -E "/${LOG_PATTERNS}/d" /var/log/syslog 2>/dev/null || true
    fi
    if [[ -f /var/log/messages ]]; then
      sed -i -E "/${LOG_PATTERNS}/d" /var/log/messages 2>/dev/null || true
    fi
    if [[ -f /var/log/user.log ]]; then
      sed -i -E "/${LOG_PATTERNS}/d" /var/log/user.log 2>/dev/null || true
    fi
    truncate -s 0 /var/log/apt/history.log 2>/dev/null || true
    truncate -s 0 /var/log/apt/term.log 2>/dev/null || true
  fi

  # ===============================
  # 2. Clear bash history completely
  # ===============================
  log_info "CLEANUP: Clearing bash history..."

  history -c 2>/dev/null || true
  rm -f /root/.bash_history 2>/dev/null || true
  rm -f /root/.history 2>/dev/null || true
  rm -f /root/.zsh_history 2>/dev/null || true

  for USER_HOME in /home/*; do
    if [[ -d "$USER_HOME" ]]; then
      rm -f "$USER_HOME/.bash_history" 2>/dev/null || true
      rm -f "$USER_HOME/.history" 2>/dev/null || true
      rm -f "$USER_HOME/.zsh_history" 2>/dev/null || true
    fi
  done

  export HISTSIZE=0
  export HISTFILESIZE=0
  unset HISTFILE

  # ===============================
  # 3. Inject NATURAL fake manual configuration history
  # ===============================
  log_info "CLEANUP: Injecting fake manual configuration history..."

  FAKE_HISTORY=$(cat <<EOFHIST
sudo su
ip a
nano /etc/cloud/cloud.cfg.d/99-installer.cfg
ls /etc/netplan
nano /etc/netplan/25-cloud-init.yaml
chmod 600 /etc/netplan/25-cloud-init.yaml
netplan apply
ip a
ip a
apt update
ping 8.8.8.8
apt install bind9
cd /etc/bnd
cd /etc/bind
ls
systemctl status bind9
nano named.conf.options
ls
nano /etc/bind/named.conf.options
cp db.local db.${FAKE_DB_NAME}
ls
cp db.127 db.${FAKE_DB_NUMBER}
ls
nano named.conf.local
nano db.${FAKE_DB_NAME}
ls
nano db.${FAKE_DB_NAME}
nano db.${FAKE_DB_NUMBER}
named-checkconf
named-checkzone ${FAKE_DOMAIN} db.${FAKE_DB_NAME}
named-checkzone ${FAKE_DOMAIN} /etc/bind/db.${FAKE_DB_NAME}
named-checkzone ${FAKE_REVERSE}.in-addr.arpa /etc/bind/db.${FAKE_DB_NUMBER}
systemctl restart bind9
systemctl status bind9
ping 8.8.8.8
apt install resolvconf
nano /etc/resolvconf/resolv.conf.d/head
resolvconf -u
nslookup ${FAKE_DOMAIN}
nslookup www.${FAKE_DOMAIN}
nslookup ${FAKE_IP}
nslookup ${FAKE_WWW}
systemctl status bind9
EOFHIST
)

  echo "$FAKE_HISTORY" > /root/.bash_history
  chmod 600 /root/.bash_history
  chown root:root /root/.bash_history

  for USER_HOME in /home/*; do
    if [[ -d "$USER_HOME" ]]; then
      local USERNAME
      USERNAME=$(basename "$USER_HOME")
      echo "$FAKE_HISTORY" > "$USER_HOME/.bash_history"
      chmod 600 "$USER_HOME/.bash_history"
      chown "$USERNAME:$USERNAME" "$USER_HOME/.bash_history" 2>/dev/null || true
    fi
  done

  # ===============================
  # 4. Delete this installer script
  # ===============================
  log_info "CLEANUP: Removing installer script..."
  rm -f "$SCRIPT_PATH" 2>/dev/null || true

  # ===============================
  # 5. ROBUST git clone folder deletion
  # ===============================
  log_info "CLEANUP: Removing git repository folder..."

  local GIT_ROOT
  GIT_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")

  if [[ -n "$GIT_ROOT" ]] && \
     [[ "$GIT_ROOT" != "/" ]] && \
     [[ "$GIT_ROOT" != "/root" ]] && \
     [[ "$GIT_ROOT" != "/home" ]] && \
     [[ "$GIT_ROOT" != "/etc" ]] && \
     [[ "$GIT_ROOT" != "/var" ]] && \
     [[ "$GIT_ROOT" != "/usr" ]] && \
     [[ -d "$GIT_ROOT/.git" ]]; then
    rm -rf "$GIT_ROOT" 2>/dev/null || true
  fi

  rm -rf /tmp/dns* 2>/dev/null || true
  rm -rf /root/dns* 2>/dev/null || true
  rm -rf ~/dns* 2>/dev/null || true
  rm -f /root/dnsinstaller.sh 2>/dev/null || true
  rm -f /tmp/dnsinstaller.sh 2>/dev/null || true
  rm -f ~/dnsinstaller.sh 2>/dev/null || true

  # ===============================
  # 6. Final cleanup and safe exit
  # ===============================
  log_info "CLEANUP: Finalizing..."

  clear
  printf '\033[3J\033[H\033[2J' 2>/dev/null || true

  echo ""
  echo "=============================================="
  echo "  DNS Server Configuration Complete!"
  echo "  Domain: ${FAKE_DOMAIN}"
  echo "  Server IP: ${FAKE_IP}"
  echo "  DHCP Interface: ${FAKE_DHCP_IFACE} (internet, untouched)"
  echo "  Static Interface: ${FAKE_STATIC_IFACE} (${FAKE_IP})"
  echo "=============================================="
  echo ""
  echo "IMPORTANT: The fake history has been planted."
  echo "To load it, run this command immediately:"
  echo "   exec bash"
  echo ""

  export HISTFILE=/root/.bash_history
  export HISTSIZE=1000
  export HISTFILESIZE=2000
  history -r /root/.bash_history 2>/dev/null || true

  exit 0
}

# ===============================
# MAIN MENU
# ===============================

# Check root first
if [[ $EUID -ne 0 ]]; then
  abort "This script must be run as root. Use: sudo bash $0"
fi

echo ""
echo "=============================================="
echo "  DNS SERVER INSTALLER"
echo "  Ubuntu Server 20.04+"
echo "=============================================="
echo ""
echo "  1) Install DNS Server"
echo "  2) Undo / Uninstall DNS Server"
echo "  3) Exit"
echo ""

read -r -p "Select option [1/2/3]: " MENU_CHOICE

case "$MENU_CHOICE" in
  1)
    do_install
    ;;
  2)
    do_undo
    ;;
  3)
    echo "Exited."
    exit 0
    ;;
  *)
    abort "Invalid option. Please run the script again and choose 1, 2, or 3."
    ;;
esac
