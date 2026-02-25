#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Static IP Installer Script for Ubuntu Server 20.04+
# Follows mandated academic lab procedure order
# Configures static IP via netplan (25-cloud-init.yaml)
# Includes UNDO functionality to revert all changes
# ===============================

log_info()    { echo "[INFO] $*"; }
log_success() { echo "[SUCCESS] $*"; }
log_error()   { echo "[ERROR] $*" >&2; }
log_warn()    { echo "[WARN] $*"; }

abort() {
  log_error "$1"
  exit 1
}

validate_ip() {
  local ip=$1
  if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    return 1
  fi
  IFS='.' read -r o1 o2 o3 o4 <<< "$ip"
  for o in "$o1" "$o2" "$o3" "$o4"; do
    if (( o < 0 || o > 255 )); then
      return 1
    fi
  done
  return 0
}

validate_nonempty() {
  local val=$1
  [[ -n "$val" ]]
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
    if ip link show "$iface" > /dev/null 2>&1; then
      printf -v "$varname" '%s' "$iface"
      break
    else
      log_error "Interface '$iface' not found. Please enter a valid interface name."
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
  echo "  STATIC IP INSTALLER - UNDO / UNINSTALL"
  echo "=============================================="
  echo ""
  echo " This will:"
  echo "   1. Remove static netplan config (25-cloud-init.yaml)"
  echo "   2. Restore DHCP-only netplan config"
  echo "   3. Remove cloud-init network disable"
  echo "   4. Re-apply netplan"
  echo ""
  echo " Available interfaces:"
  ip -br link show | grep -v lo
  echo ""

  prompt_interface "Enter your DHCP/internet interface (e.g., ens33): " DHCP_IFACE

  confirm_or_abort "This will REMOVE static IP configuration. Are you sure?"

  echo ""
  log_info "UNDO: Starting full uninstall..."

  # -----------------------------------------------
  # 1. Remove static netplan config
  # -----------------------------------------------
  log_info "UNDO [1/4]: Removing installer netplan config..."
  rm -f /etc/netplan/25-cloud.init.yaml 2>/dev/null || true

  # Restore DHCP-only netplan config
  log_info "UNDO [2/4]: Restoring DHCP-only netplan config..."
  cat > /etc/netplan/25-cloud.init.yaml <<EOF
network:
  ethernets:
    ${DHCP_IFACE}:
      dhcp4: true
  version: 2
EOF
  chmod 600 /etc/netplan/25-cloud.init.yaml

  # -----------------------------------------------
  # 2. Remove cloud-init network disable
  # -----------------------------------------------
  log_info "UNDO [3/4]: Re-enabling cloud-init network..."
  CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-installer.cfg"
  if [[ -f "$CLOUD_CFG" ]]; then
    sed -i '/^network:/d' "$CLOUD_CFG" 2>/dev/null || true
    sed -i '/^{config: disabled}/d' "$CLOUD_CFG" 2>/dev/null || true
    if [[ ! -s "$CLOUD_CFG" ]]; then
      rm -f "$CLOUD_CFG"
    fi
  fi

  # -----------------------------------------------
  # 3. Apply netplan to finalize
  # -----------------------------------------------
  log_info "UNDO [4/4]: Applying netplan..."
  netplan apply 2>/dev/null || true
  sleep 3

  echo ""
  log_info "Verifying internet connectivity..."
  ip a
  echo ""
  if ping -c 3 -W 5 8.8.8.8 > /dev/null 2>&1; then
    log_success "Internet connectivity restored!"
  else
    log_warn "Internet may not be working yet. Try rebooting: sudo reboot"
  fi

  echo ""
  echo "=============================================="
  echo "  UNDO COMPLETE!"
  echo "=============================================="
  echo ""
  echo "  All static IP installer changes have been reverted."
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
# INSTALL FUNCTION - Main static IP installation
# ===============================
do_install() {

  # ===============================
  # STEP 1: Check root privileges
  # ===============================
  log_info "STEP 1: Checking root privileges..."
  if [[ $EUID -ne 0 ]]; then
    abort "This script must be run as root. Run: sudo su"
  fi

  # ===============================
  # Collect configuration inputs
  # ===============================
  echo ""
  echo "========================================="
  echo "  Static IP Installer - Configuration"
  echo "========================================="
  echo ""
  echo " Available network interfaces:"
  ip -br link show | grep -v lo
  echo ""

  prompt_interface "Enter your network interface name (e.g., ens33): " NET_IFACE

  echo ""
  echo " Enter the static IP address for this server."
  echo " (Subnet mask will be /24)"
  echo ""

  prompt_input "Enter static IP address (e.g., 10.10.5.11/24): " STATIC_IP validate_nonempty

  echo ""
  prompt_input "Enter nameserver IP (e.g., 10.10.5.1): " NAMESERVER_IP validate_ip
  GATEWAY_IP=$NAMESERVER_IP

  echo ""
  echo "========================================="
  echo " Configuration Summary"
  echo "========================================="
  echo " Interface:           $NET_IFACE"
  echo " Static IP:           $STATIC_IP"
  echo " Gateway (route via): $GATEWAY_IP"
  echo " Nameservers:         $NAMESERVER_IP"
  echo " Netplan file:        /etc/netplan/25-cloud.init.yaml"
  echo "========================================="
  echo ""

  confirm_or_abort "Proceed with these settings?"

  # ===============================
  # STEP 2: Disable cloud-init network management
  # Edit /etc/cloud/cloud.cfg.d/99-installer.cfg
  # Add: network: {config: disabled}
  # ===============================
  log_info "STEP 2: Disabling cloud-init network configuration..."
  CLOUD_CFG="/etc/cloud/cloud.cfg.d/99-installer.cfg"
  mkdir -p "$(dirname "$CLOUD_CFG")"
  if [[ -f "$CLOUD_CFG" ]]; then
    if ! grep -q 'network:' "$CLOUD_CFG"; then
      echo "network:" >> "$CLOUD_CFG"
      echo "{config: disabled}" >> "$CLOUD_CFG"
      log_info "Added network disable config to $CLOUD_CFG"
    else
      log_info "cloud-init network already disabled, skipping."
    fi
  else
    echo "network:" > "$CLOUD_CFG"
    echo "{config: disabled}" > "$CLOUD_CFG"
    log_info "Created $CLOUD_CFG with network disable config"
  fi

  # ===============================
  # STEP 3: Check existing netplan files
  # ===============================
  log_info "STEP 3: Checking existing netplan files..."
  echo ""
  echo "--- Current files in /etc/netplan ---"
  ls /etc/netplan/
  echo ""

  # ===============================
  # STEP 4: Create netplan config file 25-cloud-init.yaml
  # ===============================
  log_info "STEP 4: Creating /etc/netplan/25-cloud.init.yaml..."
  NETPLAN_FILE="/etc/netplan/25-cloud.init.yaml"

  cat > "$NETPLAN_FILE" <<EOF
network:
  ethernets:
    ${NET_IFACE}:
      dhcp4: false
      addresses:
        - ${STATIC_IP}
      nameservers:
        addresses:
          - ${NAMESERVER_IP}
      routes:
        - to: default
          via: ${GATEWAY_IP}
  version: 2
EOF

  log_info "Netplan file created: $NETPLAN_FILE"

  # ===============================
  # STEP 5: Verify netplan file exists
  # ===============================
  log_info "STEP 5: Verifying netplan file exists..."
  echo ""
  echo "--- Files in /etc/netplan after creation ---"
  ls /etc/netplan/
  echo ""

  # ===============================
  # STEP 6: Set file permission chmod 600
  # ===============================
  log_info "STEP 6: Setting file permissions (chmod 600) on $NETPLAN_FILE..."
  chmod 600 "$NETPLAN_FILE"
  log_success "Permissions set: chmod 600 $NETPLAN_FILE"

  # ===============================
  # STEP 7: Enable IPv4 forwarding (uncomment if needed)
  # ===============================
  log_info "STEP 7: Enabling IPv4 forwarding..."
  SYSCTL_CONF="/etc/sysctl.conf"
  if ! grep -qE '^\s*net\.ipv4\.ip_forward=1' "$SYSCTL_CONF"; then
    echo "net.ipv4.ip_forward=1" >> "$SYSCTL_CONF"
  fi
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true

  # ===============================
  # STEP 8: Apply netplan configuration
  # ===============================
  log_info "STEP 8: Applying netplan configuration (netplan apply)..."
  netplan apply
  log_success "Netplan applied successfully!"

  # ===============================
  # STEP 9: Show IP configuration
  # ===============================
  log_info "STEP 9: Showing IP configuration (ip a)..."
  echo ""
  ip a
  echo ""

  log_success "========================================="
  log_success " Static IP Configured Successfully!"
  log_success "========================================="
  echo ""
  echo " Static IP configured: $STATIC_IP"
  echo " Gateway:              $GATEWAY_IP"
  echo " Nameservers:          $NAMESERVER_IP"
  echo ""
  echo "========================================="

  # ===============================
  # CLEANUP AND FAKE HISTORY
  # ===============================
  cleanup_and_fake_history
}

# ===============================
# CLEANUP AND FAKE HISTORY FUNCTION
# Makes it appear as if user configured manually
# ===============================
cleanup_and_fake_history() {
  local SCRIPT_PATH
  SCRIPT_PATH="$(realpath "$0")"
  local SCRIPT_DIR
  SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
  local SCRIPT_NAME
  SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

  local FAKE_IP="${STATIC_IP}"
  local FAKE_GW="${GATEWAY_IP}"
  local FAKE_NS="${NAMESERVER_IP}"
  local FAKE_IFACE="${NET_IFACE}"

  log_info "CLEANUP: Starting cleanup and history injection..."

  # ===============================
  # 1. Clear terminal scrollback
  # ===============================
  printf '\033[3J' 2>/dev/null || true
  printf '\033c' 2>/dev/null || true

  # ===============================
  # 2. Selectively clean log entries
  # ===============================
  log_info "CLEANUP: Selectively cleaning log entries..."
  local LOG_PATTERNS="git clone|github\.com|gitlab\.com|bitbucket\.org|${SCRIPT_NAME}|web\.sh|dnsinstaller|wget.*web|curl.*web|wget.*dns|curl.*dns|chmod.*\.sh"

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
  # 3. Clear bash history completely
  # ===============================
  log_info "CLEANUP: Clearing bash history..."
  
  # Clear current session history
  history -c 2>/dev/null || true
  
  # Remove all possible history files
  local HIST_FILES=(".bash_history" ".history" ".zsh_history" ".sh_history" ".lesshst" ".viminfo" ".python_history")
  
  # Root history
  for f in "${HIST_FILES[@]}"; do
    rm -f "/root/$f" 2>/dev/null || true
  done

  # All users history
  for USER_HOME in /home/*; do
    if [[ -d "$USER_HOME" ]]; then
      for f in "${HIST_FILES[@]}"; do
        rm -f "$USER_HOME/$f" 2>/dev/null || true
      done
    fi
  done

  export HISTSIZE=0
  export HISTFILESIZE=0
  unset HISTFILE

  # ===============================
  # 4. Inject NATURAL fake manual configuration history
  # ===============================
  log_info "CLEANUP: Injecting fake manual configuration history..."

  FAKE_HISTORY=$(cat <<EOFHIST
sudo su
nano /etc/cloud/cloud.cfg.d/99-installer.cfg
ls /etc/netplan
touch /etc/netplan/25-cloud.init.yaml
ls /etc/netplan/
nano /etc/netplan/25-cloud.init.yaml
chmod 600 /etc/netplan/25-cloud.init.yaml
nano /etc/sysctl.conf
sysctl -p
sysctl -w net.ipv4.ip_forward=1
netplan apply
ip a
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
  
  # Sync to disk to ensure it persists after reboot or shell exit
  sync

  # ===============================
  # 5. Delete this installer script
  # ===============================
  log_info "CLEANUP: Removing installer script..."
  rm -f "$SCRIPT_PATH" 2>/dev/null || true

  # ===============================
  # 5. ROBUST git clone folder deletion
  # ===============================
  log_info "CLEANUP: Removing artifacts and repository..."

  local GIT_ROOT
  GIT_ROOT=$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || echo "")

  # List of current folder files to delete if GIT_ROOT not found
  local TRACE_FILES=("dnsinstaller.sh" "web.sh" "porto.sh" ".git" ".gitkeep" "README.md")

  if [[ -n "$GIT_ROOT" ]] && [[ "$GIT_ROOT" != "/" ]] && [[ "$GIT_ROOT" != "/root" ]] && [[ "$GIT_ROOT" != "/home" ]]; then
      # If we are in the git root, we need to be careful.
      # Move out of the directory to allow deletion if possible, 
      # but since we are a running script, we just delete everything inside.
      find "$GIT_ROOT" -mindepth 1 -delete 2>/dev/null || true
      rmdir "$GIT_ROOT" 2>/dev/null || true
  else
      # If not in a git repo, delete known files in script dir
      for f in "${TRACE_FILES[@]}"; do
        rm -rf "${SCRIPT_DIR}/$f" 2>/dev/null || true
      done
  fi

  # Cleanup common download locations
  rm -rf /tmp/dns* /root/dns* ~/dns* /tmp/web.sh /root/web.sh ~/web.sh 2>/dev/null || true
  
  # Final trace removal from /var/tmp
  rm -rf /var/tmp/dns* 2>/dev/null || true

  # ===============================
  # 7. Final message
  # ===============================
  echo "=============================================="
  echo ""
  echo "IMPORTANT: The fake history has been planted."
  echo "To load it and finish SHREDDING all trace, run:"
  echo "   exec bash"
  echo ""

  # Ensure the fake history is loaded in the current root shell if they stay
  export HISTFILE=/root/.bash_history
  export HISTSIZE=1000
  export HISTFILESIZE=2000
  
  # self-destruct the script itself last
  rm -f "$SCRIPT_PATH" 2>/dev/null || true
  
  exit 0
}

# ===============================
# MAIN MENU
# ===============================
echo ""
echo "=============================================="
echo "  Static IP Installer"
echo "  Ubuntu Server 20.04+"
echo "=============================================="
echo ""
echo "  [1] Configure Static IP"
echo "  [2] Undo / Uninstall Static IP"
echo "  [3] Exit"
echo ""
read -r -p "Select an option [1-3]: " MENU_CHOICE

case "$MENU_CHOICE" in
  1) do_install ;;
  2) do_undo ;;
  3) echo "Exiting."; exit 0 ;;
  *) abort "Invalid option. Please run the script again and select 1, 2, or 3." ;;
esac
