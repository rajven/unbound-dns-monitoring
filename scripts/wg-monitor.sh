#!/bin/bash

# Usage:
#   wg-monitor.sh [INTERFACE] [TUNNEL_TYPE] [CHECK_MODE]
#
# Defaults:
#   INTERFACE=wg0
#   TUNNEL_TYPE=awg
#   CHECK_MODE=all
#
# Examples:
#   wg-monitor.sh
#   wg-monitor.sh wg1
#   wg-monitor.sh wg1 wg
#   wg-monitor.sh wg0 awg dns
#   wg-monitor.sh wg1 wg rules
#   wg-monitor.sh wg0 awg all
#
# Settings are read from /etc/unbound-dns-monitor/unbound-dns-monitor.cfg:
#   VPN_DNS_UPLINKS[<interface>] - DNS server to check
#   ROUTE_TABLES[<interface>]    - routing table to check

set -o nounset
set -o pipefail

LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

[[ -r "$LIBRARY" ]] || {
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
}

source "$LIBRARY"

# Test domain for the DNS check
DNS_TEST_DOMAIN="one.one.one.one"

# Maximum number of failures before the restart cycle
MAX_FAILURES=5

# Check that the DNS server is reachable
check_dns() {
    local dns_server="$1"
    local result

    # Try to resolve the test domain through the given DNS server
    if [[ -n "${DIG_CMD:-}" ]] && command -v "$DIG_CMD" &>/dev/null; then
        result=$("$DIG_CMD" +short +time=2 +tries=1 "@$dns_server" "$DNS_TEST_DOMAIN" A 2>/dev/null)
        if [[ -n "$result" ]]; then
            log_debug "DNS check via dig succeeded: $dns_server -> $result"
            return 0
        fi
    fi

    # Fallback to nslookup
    if command -v nslookup &>/dev/null; then
        result=$(nslookup -timeout=2 "$DNS_TEST_DOMAIN" "$dns_server" 2>/dev/null | grep -A1 "Name:" | grep "Address")
        if [[ -n "$result" ]]; then
            log_debug "DNS check via nslookup succeeded: $dns_server"
            return 0
        fi
    fi

    # Fallback to host
    if command -v host &>/dev/null; then
        result=$(host -W 2 "$DNS_TEST_DOMAIN" "$dns_server" 2>/dev/null)
        if [[ -n "$result" && "$result" != *"not found"* && "$result" != *"NXDOMAIN"* ]]; then
            log_debug "DNS check via host succeeded: $dns_server"
            return 0
        fi
    fi

    # Fallback to a TCP port 53 check
    if (echo > "/dev/tcp/$dns_server/53") 2>/dev/null; then
        log_debug "DNS server $dns_server port 53 is open (TCP check)"
        return 0
    fi

    log_debug "DNS check failed for $dns_server"
    return 1
}

# Check the routing rules
check_routing_rules() {
    local table_name="$1"
    local rule_count

    rule_count=$($IP_CMD rule show table "$table_name" 2>/dev/null | wc -l)

    if [[ "$rule_count" -eq 0 ]]; then
        log_warn "No routing rules in table $table_name (found: $rule_count)"
        return 1
    else
        log_debug "Routing rules in table $table_name present (found: $rule_count)"
        return 0
    fi
}

# Check that the interface exists
check_interface_exists() {
    local iface="$1"
    if ! $IP_CMD link show "$iface" &>/dev/null; then
        return 1
    fi
    return 0
}

# Restart the service
restart_service() {
    local service_name="$1"
    local iface="$2"

    log_info "Restarting service $service_name"

    if systemctl restart "$service_name"; then
        log_info "Service $service_name restarted successfully"

        # After the restart check whether the rules came back
        sleep 2
        if check_routing_rules "${ROUTE_TABLES[$iface]:-}"; then
            log_info "Routing rules in table ${ROUTE_TABLES[$iface]:-} restored"
        else
            log_warn "Routing rules in table ${ROUTE_TABLES[$iface]:-} not restored after restart"
        fi

        return 0
    else
        log_error "Failed to restart service $service_name"
        return 1
    fi
}

# Save the state
save_state() {
    local iface="$1"
    local attempts="$2"
    local status="$3"
    local timestamp
    local state_file="/var/spool/${iface}.state"

    timestamp=$(date +%s)
    echo "$attempts|$status|$timestamp" > "$state_file"
    log_debug "State saved: interface=$iface, attempts=$attempts, status=$status"
}

# Read the state
read_state() {
    local iface="$1"
    local state_file="/var/spool/${iface}.state"
    local content
    local attempts
    local status

    if [[ -f "$state_file" ]]; then
        content=$(<"$state_file")
        attempts=$(echo "$content" | cut -d'|' -f1)
        status=$(echo "$content" | cut -d'|' -f2)
        echo "${attempts:-0}|${status:-ok}"
    else
        echo "0|ok"
    fi
}

# Show the help message
show_help() {
    cat << EOF
Usage: $0 [INTERFACE] [TUNNEL_TYPE] [CHECK_MODE]

Parameters:
  INTERFACE    Interface name (default: wg0)
  TUNNEL_TYPE  Tunnel type: awg or wg (default: awg)
  CHECK_MODE   Check mode: dns, rules, or all (default: all)
               - dns:   Check only DNS server availability
               - rules: Check only routing rules presence
               - all:   Check both DNS and routing rules

Configuration is read from:
  /etc/unbound-dns-monitor/unbound-dns-monitor.cfg
  - VPN_DNS_UPLINKS[<interface>] - DNS server for health check
  - ROUTE_TABLES[<interface>]    - routing table for rules check

Examples:
  $0                  # wg0, awg, all
  $0 wg1              # wg1, awg, all
  $0 wg1 wg           # wg1, wg, all
  $0 wg0 awg dns      # wg0, awg, check DNS only
  $0 wg1 wg rules     # wg1, wg, check routing rules only
  $0 wg0 awg all      # wg0, awg, check both DNS and rules

Description:
  Checks DNS server availability and/or routing rules presence.
  Restarts the VPN service if problems are detected.
EOF
}

# Main logic
main() {
    local interface="${1:-wg0}"
    local tunnel_type="${2:-awg}"
    local check_mode="${3:-all}"
    local service_prefix
    local service_name
    local dns_server
    local table_name
    local state
    local total_attempts
    local last_status
    local fail_count
    local dns_available
    local rules_exist
    local need_restart
    local reason

    # Initialization
    init_script
    init_logging
    check_net_cmds

    # Check the tunnel type
    case "$tunnel_type" in
        awg) service_prefix="awg-quick" ;;
        wg)  service_prefix="wg-quick" ;;
        *)
            log_error "Unsupported tunnel type: $tunnel_type (supported: awg, wg)"
            exit 2
            ;;
    esac

    # Check the inspection mode
    case "$check_mode" in
        dns|rules|all) ;;
        *)
            log_error "Unsupported check mode: $check_mode (supported: dns, rules, all)"
            exit 2
            ;;
    esac

    service_name="${service_prefix}@${interface}.service"

    # Get the interface DNS server from the config (if needed)
    dns_server=""
    if [[ "$check_mode" == "dns" || "$check_mode" == "all" ]]; then
        dns_server="${VPN_DNS_UPLINKS[$interface]:-}"
        if [[ -z "$dns_server" ]]; then
            log_error "No DNS server configured for interface '$interface' in VPN_DNS_UPLINKS"
            exit 1
        fi
    fi

    # Get the routing table from the config (if needed)
    table_name=""
    if [[ "$check_mode" == "rules" || "$check_mode" == "all" ]]; then
        table_name="${ROUTE_TABLES[$interface]:-}"
        if [[ -z "$table_name" ]]; then
            log_error "No routing table configured for interface '$interface' in ROUTE_TABLES"
            exit 1
        fi
    fi

    log_info "Starting check: interface=$interface, tunnel=$tunnel_type, mode=$check_mode, service=$service_name"

    # Check that the interface exists
    if ! check_interface_exists "$interface"; then
        log_error "Interface $interface does not exist"
        exit 1
    fi

    # Read the current state
    state=$(read_state "$interface")
    total_attempts=$(echo "$state" | cut -d'|' -f1)
    last_status=$(echo "$state" | cut -d'|' -f2)
    total_attempts=$((total_attempts + 1))

    # Check the DNS server (if needed)
    dns_available=true
    if [[ "$check_mode" == "dns" || "$check_mode" == "all" ]]; then
        if check_dns "$dns_server"; then
            dns_available=true
            log_info "DNS server $dns_server is reachable"
        else
            dns_available=false
            log_warn "DNS server $dns_server is UNREACHABLE"
        fi
    fi

    # Check the routing rules (if needed)
    rules_exist=true
    if [[ "$check_mode" == "rules" || "$check_mode" == "all" ]]; then
        if check_routing_rules "$table_name"; then
            rules_exist=true
        else
            rules_exist=false
        fi
    fi

    # Decide whether to restart
    need_restart=false
    reason=""

    if [[ "$dns_available" = false ]]; then
        need_restart=true
        reason="DNS server unreachable"
    fi

    if [[ "$rules_exist" = false ]]; then
        need_restart=true
        reason="${reason}${reason:+; }routing rules missing"
    fi

    if [[ "$need_restart" = true ]]; then
        log_warn "Restart required: $reason"

        # Get the number of consecutive failures
        if [[ "$last_status" = "ok" || -z "$last_status" ]]; then
            fail_count=1
        else
            fail_count=$(echo "$last_status" | cut -d':' -f2)
            if ! [[ "$fail_count" =~ ^[0-9]+$ ]]; then
                fail_count=0
            fi
            fail_count=$((fail_count + 1))
        fi

        log_info "Consecutive failures: $fail_count"

        if [[ "$fail_count" -ge "$MAX_FAILURES" ]]; then
            # After MAX_FAILURES is reached, restart on every MAX_FAILURES-th attempt
            if [[ $((fail_count % MAX_FAILURES)) -eq 0 ]]; then
                log_warn "Critical state: $fail_count consecutive failures. Restarting service"
                restart_service "$service_name" "$interface"
            else
                log_warn "Critical state: $fail_count consecutive failures. Restart deferred"
            fi
        else
            # Before MAX_FAILURES, restart on every failure
            log_warn "Failure #$fail_count. Restarting service"
            restart_service "$service_name" "$interface"
        fi

        save_state "$interface" "$total_attempts" "failed:$fail_count"
        exit 1
    else
        # Build the success message depending on the mode
        case "$check_mode" in
            dns)
                log_info "Check passed: DNS reachable"
                ;;
            rules)
                log_info "Check passed: routing rules present"
                ;;
            all)
                log_info "All checks passed: DNS reachable, routing rules present"
                ;;
        esac
        save_state "$interface" "$total_attempts" "ok"
        exit 0
    fi
}

# Handle --help
if [[ "${1:-}" = "-h" || "${1:-}" = "--help" ]]; then
    show_help
    exit 0
fi

main "$@"
exit 0
