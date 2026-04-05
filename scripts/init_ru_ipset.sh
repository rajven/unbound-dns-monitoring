#!/bin/bash
# Script: ru.sh
# Description: Update Russian IPs from ipdeny.com and GeoLite2

# Load common library
SCRIPT_NAME="init_ru_ipset"
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
    log_info "Starting Russian IPs update"

    # Check root
    check_root

    # Load configuration
    source "$CONFIG_FILE"

    # Create temp directory
    mkdir -p "$IPSET_CONF_DIR" "$TEMP_DIR"

    local temp_set="${RU_IPSET}_new"
    local ipdeny_ok=1

    # Remove old temp set if exists
    $IPSET_CMD list "$temp_set" -n &>/dev/null && $IPSET_CMD destroy "$temp_set"

    # create temp set
    create_ipset_if_not_exists "$temp_set" "hash:net"

    # ----------------------------------------------------------------------
    # 1. Load from ipdeny.com (CIDR)
    # ----------------------------------------------------------------------
    if [[ "$ENABLE_IPDENY" == "yes" ]]; then
        log_info "Loading from ipdeny.com..."
        local ipdeny_file="$TEMP_DIR/ru.zone"
        local tmp_conf_ipdeny="$IPSET_CONF_DIR/ipdeny_restore"

        if wget -q "$IPDENY_URL" -O "$ipdeny_file"; then
            if [[ -s "$ipdeny_file" ]]; then
                {
                    $AWK_CMD -v set="$temp_set" '{print "add " set " " $0}' "$ipdeny_file"
                } > "$tmp_conf_ipdeny"

                if $IPSET_CMD restore -exist -f "$tmp_conf_ipdeny" 2>/dev/null; then
                    log_info "ipdeny.com imported successfully"
                    ipdeny_ok=0
                else
                    log_warn "Failed to restore ipdeny data"
                fi
                rm -f "$tmp_conf_ipdeny"
            else
                log_warn "Downloaded ipdeny file is empty"
            fi
            rm -f "$ipdeny_file"
        else
            log_warn "Failed to download ipdeny list"
        fi
    else
        log_info "IPDeny download disabled by configuration"
    fi

    # ----------------------------------------------------------------------
    # 2. Load from GeoLite2 (IP ranges)
    # ----------------------------------------------------------------------
    if [[ "$ENABLE_GEOLITE" == "yes" ]]; then
        log_info "Loading from GeoLite2..."
        local geolite_csv="$TEMP_DIR/geolite2-country-ipv4.csv"
        local tmp_conf_geolite="$IPSET_CONF_DIR/geolite_restore"

        if wget -q "$GEOLITE_URL" -O "$geolite_csv"; then
            if [[ -s "$geolite_csv" ]]; then
                # Generate add commands
                grep "RU$" "$geolite_csv" | $AWK_CMD -F ',' -v set="$temp_set" '{print "add " set " " $1 "-" $2}' > "$tmp_conf_geolite"

                if [[ -s "$tmp_conf_geolite" ]]; then
                    if $IPSET_CMD restore -exist -f "$tmp_conf_geolite" 2>/dev/null; then
                        log_info "GeoLite2 ranges added successfully"
                    else
                        log_warn "Failed to add GeoLite2 ranges"
                    fi
                else
                    log_warn "No Russian ranges found in GeoLite2"
                fi
                rm -f "$tmp_conf_geolite"
            else
                log_warn "Downloaded GeoLite2 file is empty"
            fi
            rm -f "$geolite_csv"
        else
            log_warn "Failed to download GeoLite2 list"
        fi
    else
        log_info "GeoLite2 download disabled by configuration"
    fi

    # ----------------------------------------------------------------------
    # 3. Atomic swap and save
    # ----------------------------------------------------------------------
    local entries_count=$($IPSET_CMD list "$temp_set" -t 2>/dev/null | grep -i "^Number of entries:" | awk '{print $4}')
    entries_count=${entries_count:-0}
    log_info "Temporary ipset contains $entries_count entries"

    create_ipset_if_not_exists "$RU_IPSET" "hash:net"

    if $IPSET_CMD swap "$temp_set" "$RU_IPSET" 2>/dev/null; then
        log_info "Atomic swap completed: $RU_IPSET updated"
        $IPSET_CMD destroy "$temp_set" 2>/dev/null
    else
        error_exit "Atomic swap failed, keeping old set"
    fi

    # Save configuration
    $IPSET_CMD save "$RU_IPSET" > "$IPSET_CONF_DIR/$RU_IPSET.conf" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        log_info "Saved configuration to $IPSET_CONF_DIR/$RU_IPSET.conf"
    else
        log_warn "Failed to save configuration"
    fi

    log_info "Russian IPs update completed successfully"
}

# Run main function
main

exit 0
