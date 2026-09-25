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
    local ipset_name="${1:-}"
    local ip_addr="${2:-}"
    local comment="${3:-}"

    local subnet24
    local default_gw
    local target_dev=""
    local target_ipset=""
    local vpn_gateway=""
    local ip_comment_args=""

    init_script
    init_logging
    check_net_cmds

    require_vars \
        IP_CMD \
        IPSET_CMD \
        AWK_CMD \
        ROUTE_YOUTUBE_IPSET \
        YOUTUBE_DIRECT || \
        error_exit "Required configuration variables missing"

    # Проверка ассоциативных массивов
    if [[ ${#ROUTE_VPN_IPSETS[@]} -eq 0 ]]; then
        error_exit "ROUTE_VPN_IPSETS is empty"
    fi

    # 1. Validate args
    if [[ -z "$ipset_name" || -z "$ip_addr" ]]; then
        log_error "Usage: $0 <ipset_name> <ip> [comment]"
        return 1
    fi

    # 2. Базовая валидация IP (простая)
    if [[ ! "$ip_addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Invalid IP address format: $ip_addr"
        return 1
    fi

    # 3. Create subnet /24
    subnet24="$($AWK_CMD -F '.' '{print $1"."$2"."$3".0/24"}' <<< "$ip_addr")"

    log_info "Processing: IPSET='$ipset_name' IP='$ip_addr' SUBNET='$subnet24' COMMENT='${comment:-none}'"

    # 4. Format comment safely for ipset
    if [[ -n "$comment" ]]; then
        ip_comment_args="comment \"$comment\""
    fi

    # 5. Detect default gateway
    default_gw="$($IP_CMD route show to 0/0 | awk '/via/ { print $3; exit }')"

    # 6. Handle YouTube special case
    if [[ "$ipset_name" == "youtube" ]]; then
        case "${YOUTUBE_DIRECT:-no}" in
            yes|1|on|true|TRUE|YES|ON)
                if $IP_CMD route get "$ip_addr" 2>/dev/null | grep -qE "^default via"; then
                    log_info "YouTube bypass active for $subnet24"
                    
                    if eval "$IPSET_CMD add '$ROUTE_YOUTUBE_IPSET' '$subnet24' -exist $ip_comment_args 2>/dev/null"; then
                        log_info "Added $subnet24 to YouTube bypass ipset"
                    else
                        log_error "Failed to add $subnet24 to $ROUTE_YOUTUBE_IPSET"
                    fi
                else
                    log_debug "No default route for $ip_addr, skipping YouTube bypass"
                fi
                ;;
            *)
                log_debug "YouTube bypass disabled or not recognized"
                ;;
        esac
        return 0
    fi

    # 7. Handle direct ipset
    if [[ "$ipset_name" == "direct" ]]; then
        if eval "$IPSET_CMD add 'direct' '$ip_addr' -exist $ip_comment_args 2>/dev/null"; then
            log_info "Added $ip_addr to direct ipset. Direct ipset - no other action needed"
        else
            log_error "Failed to add $ip_addr to direct ipset"
        fi
        return 0
    fi

    # 8. Determine target VPN interface and ipset
    # Сначала ищем в VPN_NAMES по имени набора
    if [[ -n "${VPN_NAMES[$ipset_name]:-}" ]]; then
        target_dev="${VPN_NAMES[$ipset_name]}"
        log_debug "Found target interface '$target_dev' for ipset '$ipset_name' in VPN_NAMES"
    else
        # Если не найдено, берём первый интерфейс из ROUTE_VPN_IPSETS
        target_dev="${!ROUTE_VPN_IPSETS[@]}"
        target_dev="${target_dev%% *}" # Берём первый элемент
        log_debug "Using default interface '$target_dev' from ROUTE_VPN_IPSETS"
    fi

    # Получаем ipset для этого интерфейса
    target_ipset="${ROUTE_VPN_IPSETS[$target_dev]:-}"
    if [[ -z "$target_ipset" ]]; then
        log_error "No ipset found for interface '$target_dev'"
        return 1
    fi

    # 9. Add to VPN ipset
    if eval "$IPSET_CMD add '$target_ipset' '$subnet24' -exist $ip_comment_args 2>/dev/null"; then
        log_info "Added $subnet24 to VPN ipset '$target_ipset' (interface: $target_dev)"
    else
        log_error "Failed to add $subnet24 to $target_ipset"
    fi

    # 10. Add system route if enabled
    if [[ "${CREATE_VPN_ROUTES:-no}" == "yes" ]]; then

        # Существует ли интерфейс
        if ! $IP_CMD link show "$target_dev" &>/dev/null; then
            log_error "Target interface '$target_dev' does not exist or is completely removed. Cannot add VPN routes."
            return 1
        fi

        # Получаем шлюз для этого интерфейса
        if [[ -z "${VPN_DNS_UPLINKS[$target_dev]:-}" ]]; then
            log_error "No VPN_DNS_UPLINK defined for interface '$target_dev'"
            return 1
        fi

        vpn_gateway="$($IP_CMD route get "${VPN_DNS_UPLINKS[$target_dev]}" 2>/dev/null | awk -v def="$default_gw" '/via/ && $3 != def { print $3; exit }')"
        
        if [[ -z "$vpn_gateway" ]]; then
            log_error "VPN gateway not found for interface '$target_dev'"
            return 1
        fi

        log_info "Adding VPN route for $subnet24 via $vpn_gateway (interface: $target_dev)"

        # Проверяем достижимость шлюза
        if ! $IP_CMD route get "$vpn_gateway" &>/dev/null; then
            log_error "VPN gateway $vpn_gateway is not reachable"
            return 1
        fi

        # Проверяем, существует ли уже маршрут
        if $IP_CMD route get fibmatch "$ip_addr" 2>/dev/null | grep -qE "via $vpn_gateway"; then
            log_debug "Route already exists for $subnet24 via $vpn_gateway"
        else
            if $IP_CMD route add "$subnet24" via "$vpn_gateway" 2>/dev/null; then
                log_info "Successfully added route $subnet24 via $vpn_gateway"
            else
                log_error "Failed to add route $subnet24 via $vpn_gateway"
                return 1
            fi
        fi
    fi

    return 0
}

main "$@"

exit $?
