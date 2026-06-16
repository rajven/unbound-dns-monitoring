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

    local ipset_name="$1"
    local ip_addr="$2"
    local comment="${3:-}"

    local subnet24
    local system_default
    local cur_gate
    local ip_comment=""

    init_script
    init_logging

    check_net_cmds

    require_vars \
        IP_CMD \
        IPSET_CMD \
        AWK_CMD \
        VPN_GATEWAY \
        ROUTE_VPN_IPSET \
        ROUTE_YOUTUBE_IPSET \
        YOUTUBE_DIRECT ||
        error_exit "Required configuration variables missing"

    #
    # Validate args
    #

    [[ -n "$ipset_name" && -n "$ip_addr" ]] ||
        error_exit "Usage: $0 <ipset_name> <ip> [comment]"

    #
    # Validate IP
    #

    [[ "$ip_addr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] ||
        error_exit "Invalid IP address format: $ip_addr"

    #
    # Create subnet
    #

    subnet24="$($AWK_CMD -F '.' '{print $1"."$2"."$3".0/24"}' <<< "$ip_addr")"

    log_info "Processing: IPSET=$ipset_name IP=$ip_addr COMMENT=$comment SUBNET=$subnet24"

    #
    # Optional comment
    #

    [[ -n "$comment" ]] && ip_comment=" comment $comment"


    #
    # Handle YouTube special case
    #

    if [[ "$ipset_name" == "youtube" ]]; then

        case "${YOUTUBE_DIRECT:-no}" in
            yes|1|on|true|TRUE|YES|ON)

                cur_gate=$($IP_CMD route get "$ip_addr" 2>/dev/null |
                           grep -E "^default via" || true)

                if [[ -n "$cur_gate" ]]; then

                    log_info "YouTube bypass active for $subnet24"

                    create_ipset_if_not_exists \
                        "$ROUTE_YOUTUBE_IPSET" hash:net

                    $IPSET_CMD add \
                        "$ROUTE_YOUTUBE_IPSET" \
                        "$subnet24" \
                        -exist \
                        $ip_comment \
                        2>/dev/null &&

                    log_info "Added $subnet24 to YouTube bypass ipset"

                else
                    log_debug "No default route for $subnet24"
                fi
                ;;

            no|0|off|false|FALSE|OFF|NO)
                log_info "YouTube bypass disabled"
                ;;

            *)
                log_debug "YouTube bypass not enabled"
                ;;
        esac

        return 0
    fi

    #
    # Handle direct ipset
    #

    if [[ "$ipset_name" == "direct" ]]; then

        # add to vpn ipset
        create_ipset_if_not_exists \
            "$ipset_name" hash:net

        $IPSET_CMD add \
            "$ipset_name" \
            "$ip_addr" \
            -exist \
            $ip_comment \
            2>/dev/null &&

        log_info "Added $ip_addr to $ipset_name ipset. Direct ipset - no other action needed"

        return 0

        fi

    # add to ipset
    create_ipset_if_not_exists \
        "$ROUTE_VPN_IPSET" hash:net

    $IPSET_CMD add \
        "$ROUTE_VPN_IPSET" \
        "$subnet24" \
        -exist \
        $ip_comment \
        2>/dev/null &&

    log_info "Added $subnet24 to VPN ipset"

    #
    # Default VPN routing
    #

    if [[ "$CREATE_VPN_ROUTES" == "yes" ]]; then

        log_info "Adding VPN route for $subnet24 via $VPN_GATEWAY"

        system_default=$($IP_CMD route get "$VPN_GATEWAY" 2>/dev/null || true)

        if [[ -z "$system_default" ]]; then
            error_exit "VPN gateway $VPN_GATEWAY is not reachable"
        fi

        cur_gate=$($IP_CMD route get fibmatch "$ip_addr" 2>/dev/null |
                   grep -E "via $VPN_GATEWAY" || true)

        if [[ -z "$cur_gate" ]]; then

            if $IP_CMD route add "$subnet24" via "$VPN_GATEWAY" 2>/dev/null; then
                log_info "Added route $subnet24 via $VPN_GATEWAY"
            else
                error_exit "Failed to add route $subnet24"
            fi

        else
            log_debug "Route already exists for $subnet24"
        fi

    fi

}

main "$@"

exit 0
