#!/bin/bash

set -o nounset
set -o pipefail

LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

[[ -r "$LIBRARY" ]] || {
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
}

source "$LIBRARY"

main() {

    # $1=dev, $2=gateway $3=mode (up|down)
    # Пример: wg0 192.168.1.1 up

    # Выходим, если не переданы аргументы
    if [[ -z "${1:-}" || -z "${2:-}" ]]; then
        echo "ERROR: Usage: $0 <dev> <gateway> [up|down]" >&2
        exit 1
    fi

    VPN_DEV="${1}"
    VPN_GATEWAY="${2}"
    local mode="${3:-up}"

    ACTION=

    local ip
    local ip_list
    local user_rules="/etc/unbound-dns-monitor/${VPN_DEV}.routes"
    local target_ipset

    init_script
    init_logging

    check_net_cmds

    CREATE_VPN_ROUTES="${CREATE_VPN_ROUTES:-no}"
    VPN_DNS_UPLINK="${VPN_DNS_UPLINKS[$VPN_DEV]:-}"
    ROUTE_TABLE="${ROUTE_TABLES[$VPN_DEV]:-}"

    # Получаем ipset для этого интерфейса
    target_ipset="${ROUTE_VPN_IPSETS[$VPN_DEV]:-}"
    if [[ -z "$target_ipset" ]]; then
        log_error "No ipset found for interface '$VPN_DEV' in ROUTE_VPN_IPSETS"
    else
        ensure_ipsets "$target_ipset" hash:net
    fi

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

        if [[ "$mode" == "up" ]]; then
            # Добавляем маршрут
            if ! ($IP_CMD route get fibmatch "$VPN_DNS_UPLINK" 2>/dev/null || true) | \
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
        else
            # Удаляем маршрут при down
            $IP_CMD route del \
                "$VPN_DNS_UPLINK" \
                via "$VPN_GATEWAY" \
                2>/dev/null || true

            log_debug \
                "DNS route: del $VPN_DNS_UPLINK"
        fi
    fi

    #
    # IPSET routes
    #

    if [[ "$CREATE_VPN_ROUTES" == "yes" && -n "$target_ipset" ]]; then

        if check_ipset "$target_ipset"; then

            ip_list=$(
                $IPSET_CMD save "$target_ipset" |
                awk "/^add $target_ipset / {print \$3}"
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
