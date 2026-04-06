#!/bin/bash

# Load common library
SCRIPT_NAME="awg-routes"
LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

if [[ ! -f "$LIBRARY" ]]; then
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
fi

source "$LIBRARY"

# Initialize logging
init_logging "$SCRIPT_NAME"

# Load config
source "$CONFIG_FILE"

# по умолчанию 'up', если аргумент не передан
MODE="${1:-up}"

if [[ "$MODE" == "up" ]]; then
    ACTION='add'
    # Добавляем маршрут до шлюза
    $IP_CMD route add $VPN_GATEWAY/32 dev $VPN_DEV 2>/dev/null || true
    log_info "VPN mode UP: adding routes"
elif [[ "$MODE" == "down" ]]; then
    ACTION='del'
    log_info "VPN mode DOWN: removing routes"
else
    log_error "Invalid mode: $MODE. Usage: $0 [up|down]"
    exit 100
fi

############ For office ###################

# dns from awg
if $IP_CMD route get fibmatch "$VPN_DNS_UPLINK" 2>/dev/null | grep -q "via $VPN_GATEWAY dev"; then
        log_debug "DNS route already exists (via $VPN_GATEWAY): $VPN_DNS_UPLINK"
    else
        $IP_CMD route add "$VPN_DNS_UPLINK" via "$VPN_GATEWAY" 2>/dev/null || true
        log_debug "DNS route: add $VPN_DNS_UPLINK via $VPN_GATEWAY"
    fi

# create ipset if not exists
create_ipset_if_not_exists "$ROUTE_VPN_IPSET" "hash:net"

# add routes by ipset route_vpn
if $IPSET list "$ROUTE_VPN_IPSET" -n &>/dev/null; then
    IP_LIST=$($IPSET save "$ROUTE_VPN_IPSET" 2>/dev/null | grep -E "^add $ROUTE_VPN_IPSET " | awk '{ print $3 }')
    if [[ -n "$IP_LIST" ]]; then
        while IFS= read -r ip; do
            [[ -z "$ip" ]] && continue
            $IP_CMD route $ACTION "$ip" via "$VPN_GATEWAY" 2>/dev/null || true
            log_debug "Route $ACTION: $ip via $VPN_GATEWAY"
        done <<< "$IP_LIST"
    else
        log_debug "No routes found in ipset $ROUTE_VPN_IPSET"
    fi
else
    log_warn "IPSet $ROUTE_VPN_IPSET does not exist"
fi

############ The END direct routes ###################

# policy for OpenVpn
#ip route $ACTION default via $VPN_GATEWAY table awg 2>/dev/null || true
#ip rule $ACTION from 10.254.254.1 lookup main pref 100  2>/dev/null || true
#ip rule $ACTION from 10.254.254.0/24 to 10.254.254.0/24 lookup main pref 101  2>/dev/null || true
# direct nets
#ip rule $ACTION from 10.254.254.0/24 fwmark 100 table main pref 102 2>/dev/null || true
# default to vpn
#ip rule $ACTION from 10.254.254.0/24 table awg pref 5000 2>/dev/null || true

# Удаляем маршрут до шлюза только при down
if [[ "$MODE" == "down" ]]; then
    $IP_CMD route del $VPN_GATEWAY/32 dev $VPN_DEV 2>/dev/null || true
    log_info "Removed route to VPN gateway"
fi

log_info "VPN mode $MODE completed"
exit 0
