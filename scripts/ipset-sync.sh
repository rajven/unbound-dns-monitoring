#!/bin/bash
# Script: ipset-sync.sh
# Description: Reconcile routing ipsets and system routes with the
#              monitored hash:ip sets. For every IPv4 address found in a
#              monitored set the script ensures the corresponding entry in
#              the routing set, according to the config:
#
#                * 'direct'  -> skipped (mark-based routing, no routing set)
#                * 'youtube' -> ROUTE_YOUTUBE_IPSET, only when YOUTUBE_DIRECT
#                               is enabled; never creates system routes
#                * any other -> the routing set of the target interface
#                               (ROUTE_VPN_IPSETS[<iface>], iface from
#                               VPN_NAMES), plus system routes when
#                               CREATE_VPN_ROUTES="yes" (gateway is taken
#                               from VPN_DNS_UPLINKS, like in ipset-hook.sh)
#
#              The entry granularity (NET24/IP) is taken from
#              ROUTE_VPN_ADD_MODE / ROUTE_YOUTUBE_ADD_MODE, the same way
#              ipset-hook.sh does at real-time processing. The domain
#              comment is carried over from the source entry.
#
#              The script is additive and idempotent: it never removes
#              entries. With NET24 several source addresses share one /24,
#              so ownership of a stale entry is ambiguous - removal would
#              need per-entry history that does not exist.
#
# Usage: ipset-sync.sh [--dry-run] [set_name ...]
#   --dry-run   print the planned actions, change nothing
#   set_name    one or more monitored ipset names (must be listed in
#               UNBOUND_IPSETS); default: all of them
#
# Examples:
#   ipset-sync.sh --dry-run          # show what would be done
#   ipset-sync.sh vpn youtube        # sync only these sets
#   ipset-sync.sh                    # full sync (cron / boot)
#
# Environment:
#   CONFIG_FILE   config path override
#                 (default /etc/unbound-dns-monitor/unbound-dns-monitor.cfg)
#   DNS_MONITOR_LIB  library path override (default /usr/local/lib/
#                 dns-monitor-lib.sh), useful for testing

set -o nounset
#set -o pipefail

LIBRARY="${DNS_MONITOR_LIB:-/usr/local/lib/dns-monitor-lib.sh}"

[[ -r "$LIBRARY" ]] || {
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
}

source "$LIBRARY"

# Counters (globals, updated by the helpers)
ENSURED=0
FAILED=0
SKIPPED=0
ROUTES_ADDED=0
ROUTES_EXISTING=0
ROUTES_FAILED=0

DRY_RUN=0

usage() {
    cat <<EOF
Usage: $0 [--dry-run] [set_name ...]

Sync routing ipsets (route_vpn / route_youtube) and system routes with the
monitored hash:ip sets from UNBOUND_IPSETS.

  --dry-run   print planned actions, change nothing
  set_name    sync only these monitored sets (default: all)
EOF
}

# Strict IPv4 validation (4 dotted-decimal octets, each 0-255) - same check
# as in ipset-hook.sh
validate_ipv4() {
    local ip="$1"
    local re_ipv4='^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'
    [[ "$ip" =~ $re_ipv4 ]] || return 1
    local -a octets=()
    IFS='.' read -r -a octets <<< "$ip"
    local octet
    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
    return 0
}

# Comment whitelist - same as in ipset-hook.sh: the comment travels into
# ipset/hook arguments, so only [A-Za-z0-9._-] is allowed
comment_ok() {
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,255}$ ]]
}

# Parse 'ipset list <set> -output save' of a source hash:ip set into an
# associative array entry -> comment (first non-empty comment wins).
# Only plain IPv4 addresses are accepted; anything else is skipped.
# Usage: read_set_entries <set_name> <assoc_array_name>
read_set_entries() {
    local src_set="$1"
    local -n out_entries="$2"
    local line cmd set_name entry rest comment
    local re_comment='^comment "(.*)"$'

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        read -r cmd set_name entry rest <<< "$line"
        [[ "$cmd" == "add" && "$set_name" == "$src_set" ]] || continue

        comment=""
        if [[ "$rest" =~ $re_comment ]]; then
            comment="${BASH_REMATCH[1]}"
            comment_ok "$comment" || comment=""
        fi

        # hash:ip sets must contain plain addresses only
        if [[ "$entry" == */* ]] || ! validate_ipv4 "$entry"; then
            log_warn "Skipping unexpected entry in $src_set: $entry"
            SKIPPED=$((SKIPPED+1))
            continue
        fi

        if [[ -z "${out_entries[$entry]+x}" ]]; then
            out_entries["$entry"]="$comment"
        elif [[ -z "${out_entries[$entry]}" && -n "$comment" ]]; then
            out_entries["$entry"]="$comment"
        fi
    done < <($IPSET_CMD list "$src_set" -output save 2>/dev/null)
    return 0
}

main() {
    local -a requested_sets=()
    local arg

    while (( $# )); do
        arg="$1"
        shift
        case "$arg" in
            --dry-run|-n)
                DRY_RUN=1
                ;;
            -h|--help)
                usage
                return 0
                ;;
            -*)
                echo "ERROR: Unknown option: $arg" >&2
                usage >&2
                return 1
                ;;
            *)
                requested_sets+=("$arg")
                ;;
        esac
    done

    # Dry-run is read-only, so root is not required for it
    (( DRY_RUN )) || check_root
    load_config
    init_logging
    check_net_cmds

    require_vars \
        IP_CMD \
        IPSET_CMD \
        IPSET_HASHSIZE \
        IPSET_MAXELEM \
        DIRECT_IPSET \
        ROUTE_YOUTUBE_IPSET \
        ROUTE_VPN_ADD_MODE \
        ROUTE_YOUTUBE_ADD_MODE \
        YOUTUBE_DIRECT \
        CREATE_VPN_ROUTES || \
        error_exit "Required configuration variables missing"

    # NOTE: for arrays the set-test must use [@] - ${arr+x} checks the
    # scalar view (element "0") and is empty for a populated assoc array
    if [[ -z "${ROUTE_VPN_IPSETS[@]+x}" ]] || (( ${#ROUTE_VPN_IPSETS[@]} == 0 )); then
        error_exit "ROUTE_VPN_IPSETS is empty"
    fi
    if [[ -z "${UNBOUND_IPSETS[@]+x}" ]] || (( ${#UNBOUND_IPSETS[@]} == 0 )); then
        error_exit "UNBOUND_IPSETS is empty"
    fi

    # Monitored set names (UNBOUND_IPSETS holds "name=type" items)
    local -a monitored=()
    local item set_name
    for item in "${UNBOUND_IPSETS[@]}"; do
        set_name="${item%%=*}"
        [[ -n "$set_name" ]] && monitored+=("$set_name")
    done
    (( ${#monitored[@]} > 0 )) || error_exit "UNBOUND_IPSETS is empty"

    # Expand and validate the requested set names
    local -a sync_sets=()
    if (( ${#requested_sets[@]} == 0 )); then
        sync_sets=("${monitored[@]}")
    else
        for set_name in "${requested_sets[@]}"; do
            local found=0
            for item in "${monitored[@]}"; do
                [[ "$set_name" == "$item" ]] && { found=1; break; }
            done
            (( found )) || error_exit "Set '$set_name' is not in UNBOUND_IPSETS"
            sync_sets+=("$set_name")
        done
    fi

    local default_gw
    default_gw="$($IP_CMD route show to 0/0 | awk '/via/ { print $3; exit }')"

    local route_set mode_name target_dev routes_enabled add_mode
    local -A planned=() entries=()
    local entry comment ip

    for set_name in "${sync_sets[@]}"; do

        # direct set is mark-based and has no routing counterpart
        if [[ "$set_name" == "$DIRECT_IPSET" ]]; then
            log_debug "Set '$set_name' is direct, nothing to sync"
            continue
        fi

        target_dev=""
        routes_enabled=0

        if [[ "$set_name" == "youtube" ]]; then
            case "${YOUTUBE_DIRECT:-no}" in
                yes|1|on|true|TRUE|YES|ON)
                    # YouTube bypass: routing set only, no system routes
                    route_set="$ROUTE_YOUTUBE_IPSET"
                    mode_name="$ROUTE_YOUTUBE_ADD_MODE"
                    ;;
                *)
                    log_debug "YOUTUBE_DIRECT is disabled, skipping set '$set_name'"
                    continue
                    ;;
            esac
        else
            # Same interface resolution as in ipset-hook.sh: VPN_NAMES first,
            # then the first interface from ROUTE_VPN_IPSETS
            if [[ -n "${VPN_NAMES[$set_name]:-}" ]]; then
                target_dev="${VPN_NAMES[$set_name]}"
                log_debug "Found target interface '$target_dev' for set '$set_name' in VPN_NAMES"
            else
                local -a route_ifaces=("${!ROUTE_VPN_IPSETS[@]}")
                target_dev="${route_ifaces[0]}"
                log_debug "Using default interface '$target_dev' for set '$set_name'"
            fi

            route_set="${ROUTE_VPN_IPSETS[$target_dev]:-}"
            if [[ -z "$route_set" ]]; then
                log_warn "No routing ipset for interface '$target_dev', skipping set '$set_name'"
                SKIPPED=$((SKIPPED+1))
                continue
            fi

            mode_name="$ROUTE_VPN_ADD_MODE"
            [[ "${CREATE_VPN_ROUTES:-no}" == "yes" ]] && routes_enabled=1
        fi

        add_mode="$(ipset_add_mode "$mode_name")" || {
            log_error "Unknown add mode '$mode_name', falling back to NET24"
            add_mode="NET24"
        }

        if ! $IPSET_CMD list "$set_name" -n &>/dev/null; then
            log_warn "Source ipset '$set_name' does not exist, skipping"
            SKIPPED=$((SKIPPED+1))
            continue
        fi

        if (( DRY_RUN )); then
            if ! $IPSET_CMD list "$route_set" -n &>/dev/null; then
                echo "[DRY-RUN] NOTE: routing ipset '$route_set' does not exist and would be created"
            fi
        elif ! create_ipset_if_not_exists "$route_set" hash:net; then
            log_error "Cannot ensure routing ipset '$route_set', skipping set '$set_name'"
            FAILED=$((FAILED+1))
            continue
        fi

        planned=()
        read_set_entries "$set_name" planned
        (( ${#planned[@]} > 0 )) || {
            log_debug "No valid entries in set '$set_name'"
            continue
        }

        # Convert raw addresses into the configured entry granularity
        # (NET24 / IP) and dedupe again: with NET24 several addresses of the
        # same /24 collapse into one entry (first non-empty comment wins)
        entries=()
        for ip in "${!planned[@]}"; do
            entry="$(ipset_entry_from_ip "$ip" "$add_mode")" || {
                log_warn "Cannot build entry for $ip in mode $add_mode, skipping"
                SKIPPED=$((SKIPPED+1))
                continue
            }
            comment="${planned[$ip]}"
            if [[ -z "${entries[$entry]+x}" ]]; then
                entries["$entry"]="$comment"
            elif [[ -z "${entries[$entry]}" && -n "$comment" ]]; then
                entries["$entry"]="$comment"
            fi
        done
        (( ${#entries[@]} > 0 )) || {
            log_debug "No valid entries in set '$set_name' after mode conversion"
            continue
        }

        # Gateway for the target interface, once per set (same logic as
        # ipset-hook.sh: the first 'via' that differs from the default gw)
        local vpn_gateway=""
        if (( routes_enabled )); then
            if ! $IP_CMD link show "$target_dev" &>/dev/null; then
                log_error "Target interface '$target_dev' does not exist, skipping system routes"
                routes_enabled=0
            elif [[ -z "${VPN_DNS_UPLINKS[$target_dev]:-}" ]]; then
                log_error "No VPN_DNS_UPLINK defined for interface '$target_dev', skipping system routes"
                routes_enabled=0
            else
                vpn_gateway="$($IP_CMD route get "${VPN_DNS_UPLINKS[$target_dev]}" 2>/dev/null | awk -v def="$default_gw" '/via/ && $3 != def { print $3; exit }')"
                if [[ -z "$vpn_gateway" ]]; then
                    log_error "VPN gateway not found for interface '$target_dev', skipping system routes"
                    routes_enabled=0
                elif ! $IP_CMD route get "$vpn_gateway" &>/dev/null; then
                    log_error "VPN gateway $vpn_gateway is not reachable, skipping system routes"
                    routes_enabled=0
                fi
            fi
        fi

        log_info "Syncing set '$set_name' -> '$route_set' (mode: $add_mode, ${#entries[@]} entries, routes: $routes_enabled)"

        for entry in $(printf '%s\n' "${!entries[@]}" | sort); do
            comment="${entries[$entry]}"

            # 1. Routing ipset entry
            if (( DRY_RUN )); then
                if [[ -n "$comment" ]]; then
                    echo "[DRY-RUN] ipset add $route_set $entry -exist comment \"$comment\""
                else
                    echo "[DRY-RUN] ipset add $route_set $entry -exist"
                fi
                ENSURED=$((ENSURED+1))
            elif $IPSET_CMD add "$route_set" "$entry" -exist ${comment:+comment "$comment"} 2>/dev/null; then
                log_info "Ensured $entry in $route_set (from $set_name${comment:+, comment: $comment})"
                ENSURED=$((ENSURED+1))
            else
                log_error "Failed to add $entry to $route_set"
                FAILED=$((FAILED+1))
            fi

            # 2. System route (VPN-routed sets only, when enabled)
            if (( routes_enabled )); then
                if $IP_CMD route get fibmatch "$entry" 2>/dev/null | grep -qE "via $vpn_gateway"; then
                    log_debug "Route already exists for $entry via $vpn_gateway"
                    ROUTES_EXISTING=$((ROUTES_EXISTING+1))
                elif (( DRY_RUN )); then
                    echo "[DRY-RUN] ip route add $entry via $vpn_gateway"
                    ROUTES_ADDED=$((ROUTES_ADDED+1))
                elif $IP_CMD route add "$entry" via "$vpn_gateway" 2>/dev/null; then
                    log_info "Added route $entry via $vpn_gateway"
                    ROUTES_ADDED=$((ROUTES_ADDED+1))
                else
                    log_error "Failed to add route $entry via $vpn_gateway"
                    ROUTES_FAILED=$((ROUTES_FAILED+1))
                fi
            fi
        done
    done

    local summary
    summary="Sync finished: ensured=$ENSURED failed=$FAILED skipped=$SKIPPED routes_added=$ROUTES_ADDED routes_existing=$ROUTES_EXISTING routes_failed=$ROUTES_FAILED dry_run=$DRY_RUN"
    log_info "$summary"
    echo "$summary"

    (( FAILED == 0 && ROUTES_FAILED == 0 ))
}

main "$@"

exit $?
