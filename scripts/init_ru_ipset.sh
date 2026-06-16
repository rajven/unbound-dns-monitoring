#!/bin/bash
# Script: ru.sh
# Description: Update Russian IPs from ipdeny.com and GeoLite2

set -o nounset
#set -o pipefail

LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

[[ -r "$LIBRARY" ]] || {
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
}

source "$LIBRARY"

main() {

    local temp_set
    local ipdeny_file
    local tmp_conf_ipdeny
    local geolite_csv
    local tmp_conf_geolite
    local entries_count

    init_script
    init_logging

    check_net_cmds

    require_vars \
        AWK_CMD \
        WGET_CMD \
        RU_IPSET \
        IPSET_CONF_DIR \
        IPSET_HASHSIZE \
        IPSET_MAXELEM \
        ENABLE_IPDENY \
        ENABLE_GEOLITE ||
        error_exit "Required configuration variables missing"

    ENABLE_IPDENY="${ENABLE_IPDENY:-no}"
    ENABLE_GEOLITE="${ENABLE_GEOLITE:-no}"

    mkdir -p "$IPSET_CONF_DIR" "$TEMP_DIR" ||
        error_exit "Cannot create working directories"

    temp_set="${RU_IPSET}_new"

    log_info "Starting Russian IPs update"

    #
    # Cleanup old temporary set
    #

    if check_ipset "$temp_set"; then
        $IPSET_CMD destroy "$temp_set" 2>/dev/null || true
    fi

    ensure_ipsets \
        "$temp_set" hash:net

    #
    # ------------------------------------------------------------------
    # 1. Load from ipdeny.com
    # ------------------------------------------------------------------
    #

    if [[ "$ENABLE_IPDENY" == "yes" ]]; then

        log_info "Loading from ipdeny.com..."

        ipdeny_file="$TEMP_DIR/ru.zone"
        tmp_conf_ipdeny="$IPSET_CONF_DIR/ipdeny_restore"

        if $WGET_CMD -q "$IPDENY_URL" -O "$ipdeny_file"; then

            if [[ -s "$ipdeny_file" ]]; then

                $AWK_CMD \
                    -v set="$temp_set" \
                    '{print "add " set " " $0}' \
                    "$ipdeny_file" \
                    > "$tmp_conf_ipdeny"

                if $IPSET_CMD restore \
                    -exist \
                    -f "$tmp_conf_ipdeny" \
                    2>/dev/null
                then
                    log_info "ipdeny.com imported successfully"
                else
                    log_warn "Failed to restore ipdeny data"
                fi

            else
                log_warn "Downloaded ipdeny file is empty"
            fi

            rm -f "$ipdeny_file" "$tmp_conf_ipdeny"

        else
            log_warn "Failed to download ipdeny list"
        fi

    else
        log_info "IPDeny download disabled"
    fi

    #
    # ------------------------------------------------------------------
    # 2. Load from GeoLite2
    # ------------------------------------------------------------------
    #

    if [[ "$ENABLE_GEOLITE" == "yes" ]]; then

        log_info "Loading from GeoLite2..."

        geolite_csv="$TEMP_DIR/geolite2-country-ipv4.csv"
        tmp_conf_geolite="$IPSET_CONF_DIR/geolite_restore"

        if $WGET_CMD -q "$GEOLITE_URL" -O "$geolite_csv"; then

            if [[ -s "$geolite_csv" ]]; then

                $AWK_CMD \
                    -F ',' \
                    -v set="$temp_set" \
                    '$NF=="RU" {print "add " set " " $1 "-" $2}' \
                    "$geolite_csv" \
                    > "$tmp_conf_geolite"

                if [[ -s "$tmp_conf_geolite" ]]; then

                    if $IPSET_CMD restore \
                        -exist \
                        -f "$tmp_conf_geolite" \
                        2>/dev/null
                    then
                        log_info "GeoLite2 ranges added successfully"
                    else
                        log_warn "Failed to add GeoLite2 ranges"
                    fi

                else
                    log_warn "No Russian ranges found in GeoLite2"
                fi

            else
                log_warn "Downloaded GeoLite2 file is empty"
            fi

            rm -f "$geolite_csv" "$tmp_conf_geolite"

        else
            log_warn "Failed to download GeoLite2 list"
        fi

    else
        log_info "GeoLite2 download disabled"
    fi

    #
    # ------------------------------------------------------------------
    # 3. Atomic swap
    # ------------------------------------------------------------------
    #

    entries_count=$(
        $IPSET_CMD list "$temp_set" -t 2>/dev/null |
        $AWK_CMD '/^Number of entries:/ {print $4}'
    )

    entries_count="${entries_count:-0}"

    log_info \
        "Temporary ipset contains $entries_count entries"

    ensure_ipsets \
        "$RU_IPSET" hash:net

    if $IPSET_CMD swap \
        "$temp_set" \
        "$RU_IPSET" \
        2>/dev/null
    then

        log_info "Atomic swap completed"

        $IPSET_CMD destroy \
            "$temp_set" \
            2>/dev/null || true

    else
        error_exit \
            "Atomic swap failed, keeping old set"
    fi

    #
    # Save configuration
    #

    if $IPSET_CMD save \
        "$RU_IPSET" \
        > "$IPSET_CONF_DIR/$RU_IPSET.conf" \
        2>/dev/null
    then

        log_info \
            "Saved configuration to $IPSET_CONF_DIR/$RU_IPSET.conf"

    else

        log_warn \
            "Failed to save configuration"

    fi

    log_info "Russian IPs update completed successfully"
}

main "$@"

exit 0
