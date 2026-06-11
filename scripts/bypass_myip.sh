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

    local domain
    local ip
    local ips
    local total_ips=0
    local added_ips=0

    init_logging
    init_script

    check_net_cmds

    require_vars \
        DIG_CMD \
        DNS_RESOLVER \
        DIRECT_IPSET \
        RU_IPSET ||
        error_exit "Required configuration variables missing"

    declare -p DETECT_IP_DOMAINS &>/dev/null ||
        DETECT_IP_DOMAINS=()

    ensure_ipsets \
        "$DIRECT_IPSET" hash:ip \
        "$RU_IPSET" hash:net

    log_info "Starting"

    log_info "Processing ${#DETECT_IP_DOMAINS[@]} domains"

    for domain in "${DETECT_IP_DOMAINS[@]}"; do

        log_debug "Resolving domain: $domain"

        ips=$(
            $DIG_CMD \
                @"$DNS_RESOLVER" \
                +short \
                +time=2 \
                +tries=1 \
                A "$domain" 2>/dev/null |
            grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
        )

        if [[ -z "$ips" ]]; then
            log_warn "No IPs resolved for domain: $domain"
            continue
        fi

        for ip in $ips; do

            ((total_ips++))

            if $IPSET_CMD test "$RU_IPSET" "$ip" &>/dev/null; then
                log_debug "IP $ip already in RU_IPSET"
                continue
            fi

            if $IPSET_CMD add \
                "$DIRECT_IPSET" \
                "$ip" \
                -exist \
                comment \
                "$domain" \
                &>/dev/null; then

                log_info \
                    "Ensured IP $ip ($domain) in $DIRECT_IPSET"

                ((added_ips++))

            else

                log_warn \
                    "Cannot add IP $ip to $DIRECT_IPSET"

            fi

        done

    done

    log_info \
        "Completed: processed $total_ips IPs, ensured $added_ips entries"
}

main "$@"

exit 0
