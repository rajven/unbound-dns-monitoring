#!/bin/bash
# Update script for unbound-dns-monitor

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/unbound-dns-monitor/unbound-dns-monitor.cfg"

# Вставляет переменные после маркера, если их еще нет в конфиге
insert_vars_after() {
    local after="$1"
    shift
    local vars=("$@")
    local tmp=$(mktemp)
    local -a vars_to_add
    
    for var in "${vars[@]}"; do
        local key="${var%%=*}"
        if ! grep -qE "^${key}=" "$CONFIG_FILE"; then
            vars_to_add+=("$var")
        fi
    done
    
    if [[ ${#vars_to_add[@]} -eq 0 ]]; then
        rm -f "$tmp"
        return 0
    fi
    
    while IFS= read -r line; do
        echo "$line" >> "$tmp"
        if [[ "$line" == "$after" ]]; then
            for var in "${vars_to_add[@]}"; do
                echo "$var" >> "$tmp"
            done
            after=""
        fi
    done < "$CONFIG_FILE"
    
    if [[ -n "$after" ]]; then
        for var in "${vars_to_add[@]}"; do
            echo "$var" >> "$tmp"
        done
    fi
    
    mv "$tmp" "$CONFIG_FILE"
}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

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
mkdir -p /var/www/html/ipsets

# 3. Patch configuration file with new parameters
log_info "Patching configuration file..."

# Добавляем новые команды, если их нет
insert_vars_after \
    '# -------------------- File Paths --------------------' \
    'DIG_CMD="/usr/bin/dig"' \
    'WGET_CMD="/usr/bin/wget"'

# Добавляем новые флаги экспорта ПОСЛЕ главного флага ENABLE_WEB_EXPORT
# (функция insert_vars_after сама проверит, есть ли они уже, и не добавит дубликаты)
insert_vars_after \
    'ENABLE_WEB_EXPORT=' \
    'ENABLE_WEB_TXT_EXPORT="no"' \
    'ENABLE_WEB_MIKROTIK_EXPORT="no"' \
    'ENABLE_WEB_RU_IPSET_EXPORT="no"'

# 4. Copy configuration templates
log_info "Copying configuration templates..."
for f in unbound-dns-monitor.cfg wg0.routes tun0.routes; do
  if [[ -f "$SCRIPT_DIR/etc/unbound-dns-monitor/$f" ]]; then
      cp -f "$SCRIPT_DIR/etc/unbound-dns-monitor/$f" "/etc/unbound-dns-monitor/$f.new"
      diff -u "/etc/unbound-dns-monitor/$f" "/etc/unbound-dns-monitor/$f.new" || true
  fi
done

# 5. Copy scripts
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

# 7. Remove obsolete files
log_info "Cleaning up obsolete files..."
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
log_info "Setting up cron jobs..."
for file in "$SCRIPT_DIR"/etc/cron.d/*; do
    if [[ -f "$file" ]]; then
        filename=$(basename "$file")
        if [ ! -f "/etc/cron.d/$filename" ]; then
            cp -f "$file" "/etc/cron.d/"
            chmod 644 "/etc/cron.d/$filename"
        fi
    fi
done

log_info "Completed successfully!"
log_info "Restart services with: systemctl restart unbound unbound-dns-monitor.service"
