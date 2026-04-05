#!/bin/bash
# Script: ipset-hook.sh
# Description: Hook script for ipset operations

# Load common library
SCRIPT_NAME="ipset-hook"
LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

if [[ ! -f "$LIBRARY" ]]; then
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
fi

source "$LIBRARY"

# Initialize logging
init_logging "$SCRIPT_NAME"

# Get parameters
IPSET_NAME=$1
IP_ADDR=$2
COMMENT=$3

# Validate parameters
if [ -z "$IPSET_NAME" ] || [ -z "$IP_ADDR" ]; then
    error_exit "Missing required parameters. Usage: $0 <ipset_name> <ip> [comment]"
fi

# Validate IP address format
if ! echo "$IP_ADDR" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
    error_exit "Invalid IP address format: $IP_ADDR"
fi

# Validate ipset name (updated to include youtube)
if [[ ! "$IPSET_NAME" =~ ^(direct|vpn|youtube)$ ]]; then
    error_exit "Invalid ipset name: $IPSET_NAME (must be 'direct', 'vpn', or 'youtube')"
fi

# Load configuration
source "$CONFIG_FILE"

create_ipset_if_not_exists "$IPSET_NAME" "hash:ip"

# Get system default gateway
SYSTEM_DEFAULT=$($IP_CMD r show to 0/0 | $AWK_CMD '{ print $3 }')
if [ -z "$SYSTEM_DEFAULT" ]; then
    error_exit "Cannot determine system default gateway"
fi

# Calculate /24 subnet
SUBNET24=$(echo "$IP_ADDR" | $AWK_CMD -F "." '{ print $1"."$2"."$3".0/24" }')

log_info "Processing: IPSET=$IPSET_NAME IP=$IP_ADDR COMMENT=$COMMENT SUBNET=$SUBNET24"

# Prepare comment for ipset
IP_COMMENT=""
if [ -n "$COMMENT" ]; then
    IP_COMMENT=" comment $COMMENT"
fi

# Handle direct routing
if [ "x$IPSET_NAME" == "xdirect" ]; then
    log_debug "Direct route for $IP_ADDR - no action needed"
    exit 0
fi

# Handle youtube routing
if [ "x$IPSET_NAME" == "xyoutube" ]; then
    # Проверяем, нужно ли вообще обрабатывать YouTube
    case "$YOUTUBE_DIRECT" in
        yes|1|on|true|TRUE|YES|ON)
            # Включаем логику обхода через direct
            CUR_GATE=$($IP_CMD r get fibmatch $IP_ADDR 2>/dev/null | grep -E "^default via")
            if [ -n "$CUR_GATE" ]; then
                log_info "Found route for $IP_ADDR via default gateway"
                create_ipset_if_not_exists "$ROUTE_YOUTUBE_IPSET" "hash:net"
                if $IPSET_CMD add "$ROUTE_YOUTUBE_IPSET" "$SUBNET24" -exist $IP_COMMENT 2>/dev/null; then
                    log_info "Added $SUBNET24 to ipset $ROUTE_YOUTUBE_IPSET"
                else
                    log_warn "Failed to add $SUBNET24 to ipset $ROUTE_YOUTUBE_IPSET"
                fi
            else
                log_debug "Route for $SUBNET24 already exists, skipping"
            fi
            ;;
        no|0|off|false|FALSE|OFF|NO)
            log_info "YOUTUBE_DIRECT explicitly disabled, skipping YouTube routing exception"
            ;;
        *)
            # Ничего не делаем
            log_debug "YOUTUBE_DIRECT disabled, skipping YouTube routing"
            ;;
    esac
    exit 0
fi

# Handle VPN routing (default case)
log_info "Adding VPN route for $SUBNET24 via $VPN_GATEWAY"

# Check if VPN gateway is reachable
if ! $IP_CMD route get "$VPN_GATEWAY" >/dev/null 2>&1; then
    error_exit "VPN gateway $VPN_GATEWAY is not reachable"
fi

# Check if route already exists
CUR_GATE=$($IP_CMD r get fibmatch "$IP_ADDR" 2>/dev/null | grep -E "via $VPN_GATEWAY dev")
if [ -z "$CUR_GATE" ]; then
    if $IP_CMD r add "$SUBNET24" via "$VPN_GATEWAY" 2>/dev/null; then
        log_info "Added route $SUBNET24 via $VPN_GATEWAY"
    else
        error_exit "Failed to add route $SUBNET24 via $VPN_GATEWAY"
    fi
    if $IPSET_CMD add "$ROUTE_VPN_IPSET" "$SUBNET24" -exist $IP_COMMENT 2>/dev/null; then
        log_info "Added $SUBNET24 to ipset $ROUTE_VPN_IPSET"
    else
        log_warn "Failed to add $SUBNET24 to ipset $ROUTE_VPN_IPSET"
    fi
else
    log_debug "Route for $SUBNET24 already exists, skipping"
fi

exit 0
