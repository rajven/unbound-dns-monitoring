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
    # Обработка аргументов OpenVPN
    # $1=dev, $2=mtu, $3=link_mtu, $4=ifconfig_local, $5=netmask, $6=script_type (опционально)
    # Пример: tun1 1500 0 192.168.201.6 255.255.255.0 up

    # Выходим, если не передан хотя бы первый аргумент (интерфейс)
    [[ -z "${1:-}" ]] && {
        echo "ERROR: No arguments provided" >&2
        exit 1
    }

    local ACTION
    local ip
    local ip_list

    init_script
    init_logging

    check_net_cmds

    require_vars \
        ROUTE_VPN_IPSET ||
        error_exit "Required configuration variables missing"

    VPN_DEV="${1}"
    IFC_ADDR="${4:-}"

    # Используем переменную окружения OpenVPN или 6-й позиционный аргумент
    local mode="${script_type:-${6:-up}}"

    # Проверка, что IP-адрес передан корректно
    if [[ -z "${IFC_ADDR}" || ! "${IFC_ADDR}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ERROR: Некорректный IP-адрес интерфейса (IFC_ADDR=${IFC_ADDR})" >&2
        exit 1
    fi

    # Динамический путь к файлу дополнительных правил на основе имени интерфейса
    local user_rules="/etc/unbound-dns-monitor/${VPN_DEV}.routes"

    # Извлекаем IP шлюза (заменяем последний октет на .1)
    VPN_GATEWAY="${IFC_ADDR%.*}.1"

    CREATE_VPN_ROUTES="${CREATE_VPN_ROUTES:-no}"
    VPN_DNS_UPLINK="${VPN_DNS_UPLINK:-}"

    ensure_ipsets \
        "$ROUTE_VPN_IPSET" hash:net

    case "$mode" in
        up)
            ACTION=add
            # Базовый маршрут до самого шлюза через туннель
            $IP_CMD route add \
                "$VPN_GATEWAY/32" \
                dev "$VPN_DEV" \
                2>/dev/null || true
            log_info "VPN state UP (dev=$VPN_DEV, gateway=$VPN_GATEWAY)"
            ;;
        down)
            ACTION=del
            log_info "VPN state DOWN (dev=$VPN_DEV, gateway=$VPN_GATEWAY)"
            ;;
        *)
            error_exit "Usage: $0 [up|down]" 100
            ;;
    esac

    #
    # DNS route (базовый, если задан в конфиге библиотеки)
    #
    if [[ -n "$VPN_DNS_UPLINK" ]]; then
        if ! $IP_CMD route get fibmatch "$VPN_DNS_UPLINK" 2>/dev/null | grep -q "via $VPN_GATEWAY dev"; then
            $IP_CMD route add "$VPN_DNS_UPLINK" via "$VPN_GATEWAY" 2>/dev/null || true
            log_debug "DNS route: add $VPN_DNS_UPLINK via $VPN_GATEWAY"
        else
            log_debug "DNS route already exists"
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
                $IP_CMD route "$ACTION" "$ip" via "$VPN_GATEWAY" 2>/dev/null || true
                log_debug "Route $ACTION: $ip via $VPN_GATEWAY"
            done <<< "$ip_list"
        fi
    fi

    #
    # Policy Routing Rules
    #
    if [[ -r "$user_rules" ]]; then
        source "$user_rules"
    fi

    #
    # Final Cleanup (базовый маршрут до шлюза)
    #
    if [[ "$mode" == "down" ]]; then
        $IP_CMD route del \
            "$VPN_GATEWAY/32" \
            dev "$VPN_DEV" \
            2>/dev/null || true
        log_info "Removed route to VPN gateway $VPN_GATEWAY"
    fi

    log_info "VPN mode $mode completed for $VPN_DEV"
}

main "$@"

exit 0
