#!/usr/bin/env bash
set -euo pipefail

# ===============================
# DNS Installer Script for Ubuntu Server 20.04+
# Follows mandated academic lab procedure order
# ===============================

log_info() { echo "[INFO] $*"; }
log_success() { echo "[SUCCESS] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

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
prompt_input "Enter static IP address (e.g., 10.10.5.1): " STATIC_IP validate_ip
prompt_interface "Enter network interface name (e.g., ens33): " NET_IFACE
prompt_input "Enter gateway IP address: " GATEWAY_IP validate_ip
prompt_input "Enter domain name (e.g., kelompok5.sch.id): " DOMAIN_NAME validate_domain
prompt_input "Enter database/zone name label (e.g., kelompok5): " ZONE_LABEL validate_label
prompt_input "Enter secondary host IP for www record (e.g., 10.10.5.11): " WWW_IP validate_ip

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
# Detect or create /etc/netplan/cloud-init.yaml
# ===============================
log_info "STEP 4: Configuring netplan static IP..."
NETPLAN_FILE="/etc/netplan/cloud-init.yaml"
cat > "$NETPLAN_FILE" <<EOF
network:
  version: 2
  ethernets:
    ${NET_IFACE}:
      dhcp4: no
      addresses:
        - ${STATIC_IP}/24
      gateway4: ${GATEWAY_IP}
      nameservers:
        addresses:
          - 8.8.8.8
          - 1.1.1.1
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
    8.8.8.8;
    1.1.1.1;
  };

  dnssec-validation auto;
  listen-on-v6 { any; };
};
EOF
else
  perl -0777 -i -pe 's/forwarders\s*\{[^}]*\};/forwarders {\n    8.8.8.8;\n    1.1.1.1;\n  };/s' "$OPTIONS_FILE"
fi

# ===============================
# STEP 13: Copy zone templates
# cp db.local -> db.<zoneLabel>
# cp db.127 -> db.<reverseLabel>
# ===============================
log_info "STEP 13: Creating zone files from templates..."
FORWARD_ZONE_FILE="/etc/bind/db.${ZONE_LABEL}"
REVERSE_ZONE_FILE="/etc/bind/db.${REVERSE_LABEL}"
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
  file "/etc/bind/db.${ZONE_LABEL}";
};

zone "${REVERSE_LABEL}.in-addr.arpa" {
  type master;
  file "/etc/bind/db.${REVERSE_LABEL}";
};
EOF

# ===============================
# STEP 15: Edit forward zone file
# Must include SOA, NS, A, WWW A records
# ===============================
log_info "STEP 15: Writing forward zone file..."
cat > "$FORWARD_ZONE_FILE" <<EOF
$TTL    604800
@       IN      SOA     ns.${DOMAIN_NAME}. admin.${DOMAIN_NAME}. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns.${DOMAIN_NAME}.
ns      IN      A       ${STATIC_IP}
@       IN      A       ${STATIC_IP}
www     IN      A       ${WWW_IP}
EOF

# ===============================
# STEP 16: Edit reverse zone file
# Must include PTR records
# ===============================
log_info "STEP 16: Writing reverse zone file..."
cat > "$REVERSE_ZONE_FILE" <<EOF
$TTL    604800
@       IN      SOA     ns.${DOMAIN_NAME}. admin.${DOMAIN_NAME}. (
                              2         ; Serial
                         604800         ; Refresh
                          86400         ; Retry
                        2419200         ; Expire
                         604800 )       ; Negative Cache TTL
;
@       IN      NS      ns.${DOMAIN_NAME}.
${ip4}  IN      PTR     ${DOMAIN_NAME}.
${WWW_IP##*.}  IN      PTR     www.${DOMAIN_NAME}.
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
resolvconf -u

# ===============================
# STEP 22: Run testing with nslookup
# ===============================
log_info "STEP 22: Running DNS tests..."
nslookup "$STATIC_IP" || true
nslookup "$WWW_IP" || true
nslookup "$DOMAIN_NAME" || true
nslookup "www.${DOMAIN_NAME}" || true

log_success "DNS Installed Successfully"
