#!/bin/bash

# LSB logging
if [ -r "/lib/lsb/init-functions" ]; then
    . /lib/lsb/init-functions
else
    log_success_msg() { echo "[ OK ] $*"; }
    log_failure_msg() { echo "[FAIL] $*" >&2; }
    log_warning_msg() { echo "[WARN] $*" >&2; }
fi

# Проверка root
if [ "$EUID" -ne 0 ]; then
    log_failure_msg "This script must be run as root"
    exit 1
fi

IPSET="/usr/sbin/ipset"
if [ ! -x "$IPSET" ]; then
    log_failure_msg "ipset not found or not executable"
    exit 1
fi

ipset_name="RU_IPS"
conf_dir="/etc/ipset.d"
mkdir -p "$conf_dir"
temp_set="${ipset_name}_new"

# Удаляем старый временный набор, если есть
"$IPSET" list "$temp_set" &>/dev/null && "$IPSET" destroy "$temp_set"

# ----------------------------------------------------------------------
# 1. Загрузка из ipdeny.com (CIDR)
# ----------------------------------------------------------------------
log_success_msg "Loading from ipdeny.com (CIDR)..."
ipdeny_url="https://www.ipdeny.com/ipblocks/data/countries/ru.zone"
ipdeny_file="/tmp/ru.zone"
tmp_conf_ipdeny="$conf_dir/ipdeny_restore"

wget -q "$ipdeny_url" -O "$ipdeny_file"
if [ $? -ne 0 ] || [ ! -s "$ipdeny_file" ]; then
    log_warning_msg "Failed to download ipdeny list, skipping"
    ipdeny_ok=1
else
    {
        echo "create $temp_set hash:net family inet hashsize 1024 maxelem 2655360"
        awk -v set="$temp_set" '{print "add " set " " $0}' "$ipdeny_file"
    } > "$tmp_conf_ipdeny"

    if "$IPSET" restore -exist -f "$tmp_conf_ipdeny"; then
        log_success_msg "ipdeny.com imported"
        ipdeny_ok=0
    else
        log_warning_msg "Failed to restore ipdeny data"
        ipdeny_ok=1
    fi
    rm -f "$tmp_conf_ipdeny" "$ipdeny_file"
fi

# Если набор не был создан (ipdeny не загрузился), создаём его вручную
if ! "$IPSET" list "$temp_set" &>/dev/null; then
    "$IPSET" create "$temp_set" hash:net family inet hashsize 1024 maxelem 2655360
fi

# ----------------------------------------------------------------------
# 2. Загрузка из GeoLite2 (диапазоны IP-IP) — добавляем недостающие
# ----------------------------------------------------------------------
log_success_msg "Loading from GeoLite2 (IP ranges)..."
geolite_url="https://cdn.jsdelivr.net/npm/@ip-location-db/geolite2-country/geolite2-country-ipv4.csv"
geolite_csv="/var/spool/geolite2-country-ipv4.csv"
tmp_conf_geolite="$conf_dir/geolite_restore"

wget -q "$geolite_url" -O "$geolite_csv"
if [ $? -ne 0 ] || [ ! -s "$geolite_csv" ]; then
    log_warning_msg "Failed to download GeoLite2, skipping"
else
    # Формируем только add команды (без create)
    grep "RU$" "$geolite_csv" | awk -F ',' -v set="$temp_set" '{print "add " set " " $1 "-" $2}' > "$tmp_conf_geolite"

    if [ -s "$tmp_conf_geolite" ]; then
        if "$IPSET" restore -exist -f "$tmp_conf_geolite"; then
            log_success_msg "GeoLite2 ranges added (missing ones only)"
        else
            log_warning_msg "Failed to add GeoLite2 ranges"
        fi
    else
        log_warning_msg "No Russian ranges found in GeoLite2"
    fi
    rm -f "$tmp_conf_geolite" "$geolite_csv"
fi

# ----------------------------------------------------------------------
# 3. Атомарная замена и сохранение
# ----------------------------------------------------------------------
if "$IPSET" swap "$temp_set" "$ipset_name"; then
    log_success_msg "Atomic swap completed: $ipset_name updated"
    "$IPSET" destroy "$temp_set" 2>/dev/null
else
    log_failure_msg "Atomic swap failed, keeping old set"
    "$IPSET" destroy "$temp_set" 2>/dev/null
    exit 1
fi

# Сохраняем конфигурацию
"$IPSET" save "$ipset_name" > "$conf_dir/$ipset_name.conf"
log_success_msg "Saved to $conf_dir/$ipset_name.conf"

exit 0
