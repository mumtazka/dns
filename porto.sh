#!/usr/bin/env bash
set -euo pipefail

# Porto installer: deploys ./dist to Apache2 docroot (/var/www/html)
# Includes hidden files (e.g. .env) and keeps Apache running.

log_info()  { echo "[INFO] $*"; }
log_warn()  { echo "[WARN] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

abort() {
  log_error "$1"
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: sudo ./porto.sh [--dist PATH] [--target PATH] [--no-delete] [--restart] [--dry-run]

Deploys a built website (default ./dist) to Apache2 docroot (default /var/www/html).
Includes hidden files like .env. By default it syncs and deletes removed files.

Options:
  --dist PATH     Source directory to deploy (default: ./dist)
  --target PATH   Destination directory (default: /var/www/html)
  --no-delete     Do not delete files in target that are not in dist
  --restart       Restart apache2 after deploy (default: reload if running)
  --dry-run       Show what would change, without modifying files
  -h, --help      Show this help
USAGE
}

DIST_DIR="./dist"
TARGET_DIR="/var/www/html"
DELETE_FLAG="--delete"
RESTART_MODE="reload"
DRY_RUN="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dist)
      DIST_DIR="$2"; shift 2 ;;
    --target)
      TARGET_DIR="$2"; shift 2 ;;
    --no-delete)
      DELETE_FLAG=""; shift ;;
    --restart)
      RESTART_MODE="restart"; shift ;;
    --dry-run)
      DRY_RUN="true"; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      abort "Unknown option: $1" ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  abort "This script must be run as root. Run: sudo ./porto.sh"
fi

if [[ ! -d "$DIST_DIR" ]]; then
  abort "Dist directory not found: $DIST_DIR"
fi

if [[ ! -d "$TARGET_DIR" ]]; then
  abort "Target directory not found: $TARGET_DIR"
fi

if ! command -v rsync >/dev/null 2>&1; then
  abort "rsync not found. Install it: sudo apt install -y rsync"
fi

log_info "Deploying from '$DIST_DIR' to '$TARGET_DIR'"

RSYNC_OPTS=(-a --chmod=Du=rwx,Dgo=rx,Fu=rw,Fgo=r)
if [[ -n "$DELETE_FLAG" ]]; then
  RSYNC_OPTS+=("$DELETE_FLAG")
fi
if [[ "$DRY_RUN" == "true" ]]; then
  RSYNC_OPTS+=(--dry-run --itemize-changes)
fi

# Trailing slash ensures contents are copied, including hidden files
rsync "${RSYNC_OPTS[@]}" "$DIST_DIR/" "$TARGET_DIR/"

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "Dry run complete. No files were changed."
  exit 0
fi

# Set ownership for Apache
chown -R www-data:www-data "$TARGET_DIR"

# Reload or restart Apache if available
if systemctl list-unit-files | grep -q '^apache2\.service'; then
  if systemctl is-active --quiet apache2; then
    if [[ "$RESTART_MODE" == "restart" ]]; then
      log_info "Restarting apache2..."
      systemctl restart apache2
    else
      log_info "Reloading apache2..."
      systemctl reload apache2
    fi
  else
    log_warn "apache2 is installed but not running. Start it with: sudo systemctl start apache2"
  fi
else
  log_warn "apache2 service not found. Ensure Apache2 is installed."
fi

log_info "Deploy complete."
