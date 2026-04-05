#!/bin/bash
# Script: bypass_myip.sh
# Description: Monitor domains and add IPs to direct ipset

# Load common library
SCRIPT_NAME="bypass_myip"
LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

if [[ ! -f "$LIBRARY" ]]; then
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
fi

source "$LIBRARY"

# Initialize logging
init_logging "$SCRIPT_NAME"

# Main function
main() {
    log_info "Starting $SCRIPT_NAME"

    # Check root
    check_root

    # Load configuration
    if [[ ! -f "$CONFIG_FILE" ]]; then
        error_exit "Configuration file not found: $CONFIG_FILE"
    fi

    source "$CONFIG_FILE"

    # Check required ipsets
    create_ipset_if_not_exists "$DIRECT_IPSET" "hash:ip"
    create_ipset_if_not_exists "$RU_IPSET" "hash:net"

    log_info "Processing ${#DETECT_IP_DOMAINS[@]} domains"

    local total_ips=0
    local added_ips=0

    # Process domains
    for domain in "${DETECT_IP_DOMAINS[@]}"; do
        log_debug "Resolving domain: $domain"

        ips=$($DIG_CMD @"$DNS_RESOLVER" +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$')

        if [[ -z "$ips" ]]; then
            log_warn "No IPs resolved for domain: $domain"
            continue
        fi

        for ip in $ips; do
            ((total_ips++))

            # Check if IP already in RU_IPSET
            if $IPSET_CMD test "$RU_IPSET" "$ip" 2>/dev/null; then
                log_debug "IP $ip is in RU_IPSET, skipping"
                continue
            fi

            # Add to DIRECT_IPSET
            if $IPSET_CMD add "$DIRECT_IPSET" "$ip" -exist comment "$domain" 2>/dev/null; then
                log_info "Added IP $ip (from $domain) to $DIRECT_IPSET"
                ((added_ips++))
            else
                log_warn "Failed to add IP $ip to $DIRECT_IPSET"
            fi
        done
    done

    log_info "Completed: processed $total_ips IPs, added $added_ips new entries"
}

# Run main function
main

exit 0
