#!/bin/bash
# Update script for unbound-dns-monitor

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/unbound-dns-monitor/unbound-dns-monitor.cfg"

insert_if_missing() {
    local after="$1"
    local line="$2"
    if grep -qxF "$line" "$CONFIG_FILE"; then
        return 0
    fi
    local tmp=$(mktemp)
    awk -v after="$after" -v newline="$line" '
    {
        print
        if ($0 == after) {
            print newline
            found=1
        }
    }
    END {
        if (!found) print newline
    }
    ' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
}

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Check root
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root"
fi

log_info "Updating unbound-dns-monitor..."

# 1. Install packages
log_info "Updating required packages..."
apt update
apt install -y libfile-tail-perl libnet-patricia-perl libnet-dns-perl libnet-idn-encode-perl \
               ipset unbound wget rsync netfilter-persistent 

# 2. Create directories
log_info "Creating directories..."
mkdir -p /var/log/unbound
mkdir -p /etc/unbound-dns-monitor
mkdir -p /usr/local/lib
mkdir -p /etc/apparmor.d/local

# 3. Copy configuration
# patch
insert_if_missing \
    'DIG_CMD="/usr/bin/dig"' \
    'WGET_CMD="/usr/bin/wget"'

insert_if_missing \
    'ROUTE_YOUTUBE_IPSET="route_youtube"' \
    'CREATE_VPN_ROUTES="yes"'

log_info "Copying configuration..."
for f in unbound-dns-monitor.cfg wg0.routes tun0.routes; do
  cp -f "$SCRIPT_DIR/etc/unbound-dns-monitor/$f" "/etc/unbound-dns-monitor/$f.new"
  diff -u "/etc/unbound-dns-monitor/$f" "/etc/unbound-dns-monitor/$f.new" || true
done

# 4. Copy scripts
log_info "Copying scripts..."
cp -f "$SCRIPT_DIR/lib/dns-monitor-lib.sh" /usr/local/lib/
cp -f "$SCRIPT_DIR/scripts/"*.sh /usr/local/bin/
cp -f "$SCRIPT_DIR/scripts/unbound-dns-monitor.pl" /usr/local/bin/
cp -f "$SCRIPT_DIR/scripts/yudns.pl" /usr/local/bin/
chmod +x /usr/local/bin/*.sh
chmod +x /usr/local/bin/unbound-dns-monitor.pl
chmod +x /usr/local/bin/yudns.pl

# 6. Copy systemd services
log_info "Updating systemd services..."
cp -f "$SCRIPT_DIR/etc/systemd/unbound-dns-monitor.service" /etc/systemd/system/
mkdir -p /etc/systemd/system/netfilter-persistent.service.d
cp -f "$SCRIPT_DIR/etc/systemd/netfilter-persistent.service.d/override.conf" /etc/systemd/system/netfilter-persistent.service.d/ 2>/dev/null || true

# 7. remove old ipset-utils
[ -e /etc/init.d/ipset ] && rm -f /etc/init.d/ipset
[ -e "/usr/local/bin/wg-routes.sh" ] && rm -f "/usr/local/bin/wg-routes.sh"

# 8. Configure apparmor
if [[ -f "$SCRIPT_DIR/etc/apparmor.d/local/usr.sbin.unbound" ]]; then
    log_info "Configuring apparmor..."
    cp -f "$SCRIPT_DIR/etc/apparmor.d/local/usr.sbin.unbound" /etc/apparmor.d/local/
    apparmor_parser -r /etc/apparmor.d/usr.sbin.unbound 2>/dev/null || true
fi

# 9. Setup log files
log_info "Setting up log files..."
touch /var/log/unbound/unbound.log
chown -R unbound:unbound /var/log/unbound
chmod 770 /var/log/unbound

systemctl daemon-reload

# 10. Setup cron
for file in "$SCRIPT_DIR"/etc/cron.d/*; do
    filename=$(basename "$file")
    if [ ! -f "/etc/cron.d/$filename" ]; then
        cp -f "$file" "/etc/cron.d/"
        chmod 644 "/etc/cron.d/$filename"
    fi
done

log_info "Completed successfully!"
log_info "Restart services with: systemctl restart unbound unbound-dns-monitor.service"
