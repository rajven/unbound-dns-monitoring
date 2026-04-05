#!/bin/bash
# Installation script for unbound-dns-monitor

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/unbound-dns-monitor/unbound-dns-monitor.cfg"

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

log_info "Installing unbound-dns-monitor..."

# 1. Install packages
log_info "Installing required packages..."
apt update
apt install -y libfile-tail-perl libnet-patricia-perl libnet-dns-perl \
               ipset unbound wget rsync netfilter-persistent

# 2. Create directories
log_info "Creating directories..."
mkdir -p /var/log/unbound
mkdir -p /etc/unbound-dns-monitor
mkdir -p /usr/local/lib
mkdir -p /etc/apparmor.d/local

# 3. Copy configuration
log_info "Copying configuration..."
cp -f "$SCRIPT_DIR/etc/unbound-dns-monitor/unbound-dns-monitor.cfg" /etc/unbound-dns-monitor/
cp -f "$SCRIPT_DIR/lib/dns-monitor-lib.sh" /usr/local/lib/
chmod 644 /usr/local/lib/dns-monitor-lib.sh

# 4. Copy scripts
log_info "Copying scripts..."
cp -f "$SCRIPT_DIR/scripts/"*.sh /usr/local/bin/
cp -f "$SCRIPT_DIR/scripts/unbound-dns-monitor.pl" /usr/local/bin/
chmod +x /usr/local/bin/*.sh
chmod +x /usr/local/bin/unbound-dns-monitor.pl

# 5. Copy unbound configuration
log_info "Configuring unbound..."
rsync -av "$SCRIPT_DIR/unbound/" /etc/unbound/

# 6. Copy systemd services
log_info "Installing systemd services..."
cp -f "$SCRIPT_DIR/systemd/unbound-dns-monitor.service" /etc/systemd/system/
mkdir -p /etc/systemd/system/netfilter-persistent.service.d
cp -f "$SCRIPT_DIR/systemd/netfilter-persistent.service.d/override.conf" /etc/systemd/system/netfilter-persistent.service.d/ 2>/dev/null || true

# 7. Copy init script
cp -f "$SCRIPT_DIR/init.d/ipset" /etc/init.d/ 2>/dev/null || true
chmod +x /etc/init.d/ipset 2>/dev/null || true

# 8. Configure apparmor
if [[ -f "$SCRIPT_DIR/apparmor.d/local/usr.sbin.unbound" ]]; then
    log_info "Configuring apparmor..."
    cp -f "$SCRIPT_DIR/apparmor.d/local/usr.sbin.unbound" /etc/apparmor.d/local/
    apparmor_parser -r /etc/apparmor.d/usr.sbin.unbound 2>/dev/null || true
fi

# 9. Setup log files
log_info "Setting up log files..."
touch /var/log/unbound/unbound.log
chown -R unbound:unbound /var/log/unbound
chmod 770 /var/log/unbound

# 10. Generate unbound-control keys
log_info "Generating unbound-control keys..."
unbound-control-setup

# 11. Enable services
log_info "Enabling services..."
systemctl daemon-reload
systemctl enable unbound
systemctl enable unbound-dns-monitor.service

log_info "Installation completed successfully!"
log_info "Start services with: systemctl start unbound unbound-dns-monitor.service"
