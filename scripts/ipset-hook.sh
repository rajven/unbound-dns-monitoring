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

    local entry
    local add_mode
    local youtube_mode
    local youtube_entry
    local default_gw
    local default_dev=""
    local route_dev=""
    local target_dev=""
    local target_ipset=""
    local vpn_gateway=""

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

    # Check associative arrays
    if [[ ${#ROUTE_VPN_IPSETS[@]} -eq 0 ]]; then
        error_exit "ROUTE_VPN_IPSETS is empty"
    fi

    # 1. Validate args
    if [[ -z "$ipset_name" || -z "$ip_addr" ]]; then
        log_error "Usage: $0 <ipset_name> <ip> [comment]"
        return 1
    fi

    # 2. Strict IPv4 validation (4 dotted-decimal octets, each 0-255)
    if [[ ! "$ip_addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        log_error "Invalid IP address format: $ip_addr"
        return 1
    fi
    local -a octets=()
    IFS='.' read -r -a octets <<< "$ip_addr"
    local octet
    for octet in "${octets[@]}"; do
        if (( 10#$octet > 255 )); then
            log_error "Invalid IP address (octet out of range): $ip_addr"
            return 1
        fi
    done

    # 3. Add-modes for the hash:net sets:
    #    NET24 - the /24 network calculated from the address (default)
    #    IP    - the address is added as is
    #    ROUTE_VPN_ADD_MODE     - VPN routing ipset (route_vpn) and its routes
    #    ROUTE_YOUTUBE_ADD_MODE - YouTube bypass ipset (route_youtube)
    add_mode="$(ipset_add_mode "${ROUTE_VPN_ADD_MODE:-NET24}")" || {
        log_error "Unknown ROUTE_VPN_ADD_MODE='${ROUTE_VPN_ADD_MODE}', falling back to NET24"
        add_mode="NET24"
    }

    youtube_mode="$(ipset_add_mode "${ROUTE_YOUTUBE_ADD_MODE:-NET24}")" || {
        log_error "Unknown ROUTE_YOUTUBE_ADD_MODE='${ROUTE_YOUTUBE_ADD_MODE}', falling back to NET24"
        youtube_mode="NET24"
    }

    # Entry for the VPN routing ipset and the matching route
    entry="$(ipset_entry_from_ip "$ip_addr" "$add_mode")" || {
        log_error "Cannot build ipset entry for '$ip_addr' in mode '$add_mode'"
        return 1
    }

    # Entry for the YouTube bypass ipset
    youtube_entry="$(ipset_entry_from_ip "$ip_addr" "$youtube_mode")" || {
        log_error "Cannot build YouTube bypass entry for '$ip_addr' in mode '$youtube_mode'"
        return 1
    }

    log_info "Processing: IPSET='$ipset_name' IP='$ip_addr' ENTRY='$entry' MODE='$add_mode' YOUTUBE_ENTRY='$youtube_entry' YOUTUBE_MODE='$youtube_mode' COMMENT='${comment:-none}'"

    # 4. Validate comment before passing it to ipset: it originates from DNS
    #    log data, so restrict it to a fixed safe charset and pass it only as
    #    a single quoted argument (never reassembled into a shell line)
    if [[ -n "$comment" ]] && [[ ! "$comment" =~ ^[A-Za-z0-9._-]{1,255}$ ]]; then
        log_warn "Comment contains characters outside [A-Za-z0-9._-] (or too long), dropping it"
        comment=""
    fi

    # 5. Detect default gateway and the WAN device that owns it
    default_gw="$($IP_CMD route show to 0/0 | awk '/via/ { print $3; exit }')"
    default_dev="$($IP_CMD route show to default | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')"

    # 6. Handle YouTube special case
    if [[ "$ipset_name" == "youtube" ]]; then
        case "${YOUTUBE_DIRECT:-no}" in
            yes|1|on|true|TRUE|YES|ON)
                # The address is bypassed only when its current route exits
                # via the WAN device: ip route get never prints "default via"
                # (output starts with the target address), so comparing the
                # exit device with the default-route device is the reliable
                # equivalent of the intended check
                route_dev="$($IP_CMD route get "$ip_addr" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i+1); exit } }')"
                if [[ -n "$default_dev" && "$route_dev" == "$default_dev" ]]; then
                    log_info "Route for $ip_addr exits via WAN device '$route_dev', YouTube bypass active for $youtube_entry"

                    if $IPSET_CMD add "$ROUTE_YOUTUBE_IPSET" "$youtube_entry" -exist ${comment:+comment "$comment"} 2>/dev/null; then
                        log_info "Added $youtube_entry to YouTube bypass ipset (mode: $youtube_mode)"
                    else
                        log_error "Failed to add $youtube_entry to $ROUTE_YOUTUBE_IPSET"
                    fi
                else
                    log_debug "Route for $ip_addr exits via '${route_dev:-none}', not via WAN device '${default_dev:-none}', skipping YouTube bypass"
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
        if $IPSET_CMD add "direct" "$ip_addr" -exist ${comment:+comment "$comment"} 2>/dev/null; then
            log_info "Added $ip_addr to direct ipset. Direct ipset - no other action needed"
        else
            log_error "Failed to add $ip_addr to direct ipset"
        fi
        return 0
    fi

    # 8. Determine target VPN interface and ipset
    # First look up the set name in VPN_NAMES
    if [[ -n "${VPN_NAMES[$ipset_name]:-}" ]]; then
        target_dev="${VPN_NAMES[$ipset_name]}"
        log_debug "Found target interface '$target_dev' for ipset '$ipset_name' in VPN_NAMES"
    else
        # If not found, take the first interface from ROUTE_VPN_IPSETS
        target_dev="${!ROUTE_VPN_IPSETS[@]}"
        # Take the first element
        target_dev="${target_dev%% *}"
        log_debug "Using default interface '$target_dev' from ROUTE_VPN_IPSETS"
    fi

    # Get the ipset for this interface
    target_ipset="${ROUTE_VPN_IPSETS[$target_dev]:-}"
    if [[ -z "$target_ipset" ]]; then
        log_error "No ipset found for interface '$target_dev'"
        return 1
    fi

    # 9. Add to VPN ipset
    if $IPSET_CMD add "$target_ipset" "$entry" -exist ${comment:+comment "$comment"} 2>/dev/null; then
        log_info "Added $entry to VPN ipset '$target_ipset' (interface: $target_dev, mode: $add_mode)"
    else
        log_error "Failed to add $entry to $target_ipset"
    fi

    # 10. Add system route if enabled
    if [[ "${CREATE_VPN_ROUTES:-no}" == "yes" ]]; then

        # Check that the interface exists
        if ! $IP_CMD link show "$target_dev" &>/dev/null; then
            log_error "Target interface '$target_dev' does not exist or is completely removed. Cannot add VPN routes."
            return 1
        fi

        # Get the gateway for this interface
        if [[ -z "${VPN_DNS_UPLINKS[$target_dev]:-}" ]]; then
            log_error "No VPN_DNS_UPLINK defined for interface '$target_dev'"
            return 1
        fi

        vpn_gateway="$($IP_CMD route get "${VPN_DNS_UPLINKS[$target_dev]}" 2>/dev/null | awk -v def="$default_gw" '/via/ && $3 != def { print $3; exit }')"
        
        if [[ -z "$vpn_gateway" ]]; then
            log_error "VPN gateway not found for interface '$target_dev'"
            return 1
        fi

        log_info "Adding VPN route for $entry via $vpn_gateway (interface: $target_dev)"

        # Check that the gateway is reachable
        if ! $IP_CMD route get "$vpn_gateway" &>/dev/null; then
            log_error "VPN gateway $vpn_gateway is not reachable"
            return 1
        fi

        # Check whether the route already exists
        if $IP_CMD route get fibmatch "$ip_addr" 2>/dev/null | grep -qE "via $vpn_gateway"; then
            log_debug "Route already exists for $entry via $vpn_gateway"
        else
            if $IP_CMD route add "$entry" via "$vpn_gateway" 2>/dev/null; then
                log_info "Successfully added route $entry via $vpn_gateway"
            else
                log_error "Failed to add route $entry via $vpn_gateway"
                return 1
            fi
        fi
    fi

    return 0
}

main "$@"

exit $?
