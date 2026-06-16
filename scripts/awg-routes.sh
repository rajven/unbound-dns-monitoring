#!/bin/bash

set -o nounset
#set -o pipefail

LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

[[ -r "$LIBRARY" ]] || {
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
}

source "$LIBRARY"

main() {

    local mode="${1:-up}"
    local ACTION
    local ip
    local ip_list
    local user_rules="/etc/unbound-dns-monitor/awg.routes"

    init_script
    init_logging

    check_net_cmds

    require_vars \
        VPN_GATEWAY \
        VPN_DEV \
        ROUTE_VPN_IPSET ||
        error_exit "Required configuration variables missing"

    CREATE_VPN_ROUTES="${CREATE_VPN_ROUTES:-no}"
    VPN_DNS_UPLINK="${VPN_DNS_UPLINK:-}"

    ensure_ipsets \
        "$ROUTE_VPN_IPSET" hash:net

    case "$mode" in
        up)
            ACTION=add

            $IP_CMD route add \
                "$VPN_GATEWAY/32" \
                dev "$VPN_DEV" \
                2>/dev/null || true

            log_info "VPN state UP"
            ;;

        down)
            ACTION=del
            log_info "VPN state DOWN"
            ;;

        *)
            error_exit "Usage: $0 [up|down]" 100
            ;;
    esac

    #
    # DNS route
    #

    if [[ -n "$VPN_DNS_UPLINK" ]]; then

        if ! $IP_CMD route get fibmatch "$VPN_DNS_UPLINK" \
            2>/dev/null |
            grep -q "via $VPN_GATEWAY dev"; then

            $IP_CMD route add \
                "$VPN_DNS_UPLINK" \
                via "$VPN_GATEWAY" \
                2>/dev/null || true

            log_debug \
                "DNS route: add $VPN_DNS_UPLINK"

        else
            log_debug \
                "DNS route already exists"
        fi
    fi

    #
    # IPSET routes
    #

    if [[ "$CREATE_VPN_ROUTES" == "yes" ]]; then

        if check_ipset "$ROUTE_VPN_IPSET"; then

            ip_list=$(
                $IPSET_CMD save "$ROUTE_VPN_IPSET" |
                awk "/^add $ROUTE_VPN_IPSET / {print \$3}"
            )

            while IFS= read -r ip; do

                [[ -n "$ip" ]] || continue

                $IP_CMD route \
                    "$ACTION" \
                    "$ip" \
                    via "$VPN_GATEWAY" \
                    2>/dev/null || true

                log_debug \
                    "Route $ACTION: $ip"

            done <<< "$ip_list"

        fi
    fi

    #
    # User rules
    #

    if [[ -r "$user_rules" ]]; then
        source "$user_rules"
    fi

    #
    # Cleanup
    #

    if [[ "$mode" == down ]]; then

        $IP_CMD route del \
            "$VPN_GATEWAY/32" \
            dev "$VPN_DEV" \
            2>/dev/null || true

        log_info "Removed route to VPN gateway"
    fi

    log_info "VPN mode $mode completed"
}

main "$@"

exit 0
