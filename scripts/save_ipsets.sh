#!/bin/bash

set -o nounset
set -o pipefail

LIBRARY="/usr/local/lib/dns-monitor-lib.sh"

[[ -r "$LIBRARY" ]] || {
    echo "ERROR: Common library not found: $LIBRARY" >&2
    exit 1
}

source "$LIBRARY"

show_help() {
    cat << EOF
Usage: $0 [ipset_name ...]

Arguments:
  ipset_name   One or more specific ipset names to backup (e.g., telegram youtube).
               If no arguments are provided, backups all ipsets based on config flags.

Examples:
  $0                     # Backup based on ENABLE_WEB_*_EXPORT flags
  $0 telegram whatsapp   # Backup only 'telegram' and 'whatsapp' ipsets
  $0 --help              # Show this help message
EOF
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        show_help
        exit 0
    fi

    local target_ipsets=()
    local ipset_name
    local processed=0
    local failed=0
    local skipped=0

    init_script
    init_logging
    check_net_cmds

    require_vars \
        IPSET_CMD \
        AWK_CMD \
        WEB_OUTPUT_DIR \
        TEMP_DIR \
        ENABLE_WEB_EXPORT \
        ENABLE_WEB_TXT_EXPORT \
        ENABLE_WEB_MIKROTIK_EXPORT \
        ENABLE_WEB_RU_IPSET_EXPORT || \
        error_exit "Required configuration variables missing"

    # 1. ГЛАВНЫЙ ВЫКЛЮЧАТЕЛЬ
    local enable_web="${ENABLE_WEB_EXPORT:-no}"
    [[ "$enable_web" =~ ^(yes|1|on|true|YES|ON|TRUE)$ ]] && enable_web="yes" || enable_web="no"

    if [[ "$enable_web" != "yes" ]]; then
        log_info "Web export is disabled (ENABLE_WEB_EXPORT=no). Exiting."
        exit 0
    fi

    # 2. Нормализуем флаги конкретных форматов
    local enable_txt="${ENABLE_WEB_TXT_EXPORT:-no}"
    local enable_mikrotik="${ENABLE_WEB_MIKROTIK_EXPORT:-no}"
    local enable_ru="${ENABLE_WEB_RU_IPSET_EXPORT:-no}"

    [[ "$enable_txt" =~ ^(yes|1|on|true|YES|ON|TRUE)$ ]] && enable_txt="yes" || enable_txt="no"
    [[ "$enable_mikrotik" =~ ^(yes|1|on|true|YES|ON|TRUE)$ ]] && enable_mikrotik="yes" || enable_mikrotik="no"
    [[ "$enable_ru" =~ ^(yes|1|on|true|YES|ON|TRUE)$ ]] && enable_ru="yes" || enable_ru="no"

    # Если главный включен, но ни один формат не выбран — предупреждаем и выходим
    if [[ "$enable_txt" == "no" && "$enable_mikrotik" == "no" ]]; then
        log_warn "Web export is enabled, but no specific formats (TXT or MikroTik) are selected. Exiting."
        exit 0
    fi

    # 3. Формируем список целевых ipset
    if [[ $# -gt 0 ]]; then
        target_ipsets=("$@")
        log_info "Explicit ipsets specified: ${target_ipsets[*]}"
    else
        log_info "No ipsets specified, collecting all configured ipsets..."
        
        for item in "${UNBOUND_IPSETS[@]}"; do
            target_ipsets+=("${item%%=*}")
        done

        local special_sets=("${ROUTE_YOUTUBE_IPSET:-}" "${ROUTE_VPN_IPSETS[@]:-}")
        for set in "${special_sets[@]}"; do
            [[ -n "$set" ]] && target_ipsets+=("$set")
        done

        if [[ "$enable_ru" == "yes" && -n "${RU_IPSET:-}" ]]; then
            target_ipsets+=("$RU_IPSET")
        fi
        
        local -A unique_sets
        for set in "${target_ipsets[@]}"; do
            [[ -n "$set" ]] && unique_sets["$set"]=1
        done
        target_ipsets=("${!unique_sets[@]}")
        
        log_info "Auto-detected ipsets to backup: ${target_ipsets[*]}"
    fi

    mkdir -p "$WEB_OUTPUT_DIR" || error_exit "Failed to create directory $WEB_OUTPUT_DIR"
    chmod 755 "$WEB_OUTPUT_DIR"

    log_info "Starting ipset backup (TXT: $enable_txt, MikroTik: $enable_mikrotik, RU: $enable_ru)"

    # 4. Export ipsets
    for ipset_name in "${target_ipsets[@]}"; do
        local txt_saved=false
        local rsc_saved=false
        
        local temp_file=""
        local rsc_temp_file=""
        
        [[ "$enable_txt" == "yes" ]] && temp_file="$TEMP_DIR/${ipset_name}.tmp"
        [[ "$enable_mikrotik" == "yes" ]] && rsc_temp_file="$TEMP_DIR/${ipset_name}.rsc.tmp"

        if ! $IPSET_CMD list "$ipset_name" -n &>/dev/null; then
            log_warn "IPSet '$ipset_name' does not exist, skipping"
            ((skipped++))
            continue
        fi

        log_debug "Processing $ipset_name"

        local awk_script='
        /^add / {
            ip = $3
            comment = ""
            for(i=4; i<=NF; i++) {
                if ($i == "comment") {
                    comment = $(i+1)
                    gsub(/^"|"$/, "", comment)
                    break
                }
            }
            if (enable_txt == "yes") {
                if (comment != "") print ip " " comment > "/dev/fd/3"
                else print ip > "/dev/fd/3"
            }
            if (enable_mk == "yes") {
                if (comment != "") print "add address=" ip " list=" list_name " comment=\"" comment "\"" > "/dev/fd/4"
                else print "add address=" ip " list=" list_name > "/dev/fd/4"
            }
        }'

        if [[ "$enable_txt" == "yes" && "$enable_mikrotik" == "yes" ]]; then
            $IPSET_CMD save "$ipset_name" 2>/dev/null | \
                awk -v list_name="$ipset_name" -v enable_txt="yes" -v enable_mk="yes" "$awk_script" \
                3>"$temp_file" 4>"$rsc_temp_file"
        elif [[ "$enable_txt" == "yes" ]]; then
            $IPSET_CMD save "$ipset_name" 2>/dev/null | \
                awk -v list_name="$ipset_name" -v enable_txt="yes" -v enable_mk="no" "$awk_script" \
                3>"$temp_file"
        elif [[ "$enable_mikrotik" == "yes" ]]; then
            $IPSET_CMD save "$ipset_name" 2>/dev/null | \
                awk -v list_name="$ipset_name" -v enable_txt="no" -v enable_mk="yes" "$awk_script" \
                4>"$rsc_temp_file"
        fi

        if [[ "$enable_txt" == "yes" && -n "$temp_file" ]]; then
            local output_file="$WEB_OUTPUT_DIR/$ipset_name.txt"
            if mv "$temp_file" "$output_file" 2>/dev/null; then
                chmod 644 "$output_file" 2>/dev/null || true
                local count=$(wc -l < "$output_file" | tr -d ' ')
                log_info "Saved $ipset_name.txt ($count entries)"
                txt_saved=true
            else
                log_error "Failed to save $ipset_name.txt"
            fi
        fi

        if [[ "$enable_mikrotik" == "yes" && -n "$rsc_temp_file" ]]; then
            local rsc_file="$WEB_OUTPUT_DIR/$ipset_name.rsc"
            if mv "$rsc_temp_file" "$rsc_file" 2>/dev/null; then
                chmod 644 "$rsc_file" 2>/dev/null || true
                local count=$(wc -l < "$rsc_file" | tr -d ' ')
                log_info "Saved $ipset_name.rsc ($count entries)"
                rsc_saved=true
            else
                log_error "Failed to save $ipset_name.rsc"
            fi
        fi

        if [[ "$txt_saved" == "true" || "$rsc_saved" == "true" ]]; then
            ((processed++))
        else
            ((failed++))
        fi
    done

    # 5. Index file (отчёт)
    local index_file="$WEB_OUTPUT_DIR/index.txt"
    {
        echo "# IPSets Backup Summary"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Processed: $processed"
        echo "# Skipped (missing): $skipped"
        echo "# Failed: $failed"
        echo "# Formats: TXT=$enable_txt, MikroTik=$enable_mikrotik"
        echo ""
        echo "## Files:"

        for ipset_name in "${target_ipsets[@]}"; do
            local has_files=false
            
            if [[ "$enable_txt" == "yes" && -f "$WEB_OUTPUT_DIR/$ipset_name.txt" ]]; then
                local count=$(wc -l < "$WEB_OUTPUT_DIR/$ipset_name.txt" | tr -d ' ')
                echo "$ipset_name.txt - $count entries"
                has_files=true
            fi
            
            if [[ "$enable_mikrotik" == "yes" && -f "$WEB_OUTPUT_DIR/$ipset_name.rsc" ]]; then
                local count=$(wc -l < "$WEB_OUTPUT_DIR/$ipset_name.rsc" | tr -d ' ')
                echo "$ipset_name.rsc - $count entries (MikroTik)"
                has_files=true
            fi
            
            if [[ "$has_files" == "false" ]]; then
                echo "$ipset_name - missing/skipped"
            fi
        done
    } > "$index_file"

    chmod 644 "$index_file"
    log_info "Index created: $index_file"

    # 6. JSON export (отчёт)
    local json_file="$WEB_OUTPUT_DIR/ipsets.json"
    {
        echo "{"
        echo "  \"generated\": \"$(date -Iseconds)\","
        echo "  \"summary\": {"
        echo "    \"processed\": $processed,"
        echo "    \"skipped\": $skipped,"
        echo "    \"failed\": $failed,"
        echo "    \"txt_export\": \"$enable_txt\","
        echo "    \"mikrotik_export\": \"$enable_mikrotik\""
        echo "  },"
        echo "  \"ipsets\": ["

        local first=true
        for ipset_name in "${target_ipsets[@]}"; do
            if [[ "$first" == true ]]; then
                first=false
            else
                echo ","
            fi

            local safe_name="${ipset_name//\\/\\\\}"
            safe_name="${safe_name//\"/\\\"}"
            
            if [[ -f "$WEB_OUTPUT_DIR/$ipset_name.txt" || -f "$WEB_OUTPUT_DIR/$ipset_name.rsc" ]]; then
                echo -n "    {\"name\": \"$safe_name\", \"exists\": true"
                
                if [[ "$enable_txt" == "yes" && -f "$WEB_OUTPUT_DIR/$ipset_name.txt" ]]; then
                    local count=$(wc -l < "$WEB_OUTPUT_DIR/$ipset_name.txt" | tr -d ' ')
                    echo -n ", \"txt_file\": \"$safe_name.txt\", \"txt_entries\": $count"
                fi
                
                if [[ "$enable_mikrotik" == "yes" && -f "$WEB_OUTPUT_DIR/$ipset_name.rsc" ]]; then
                    local count=$(wc -l < "$WEB_OUTPUT_DIR/$ipset_name.rsc" | tr -d ' ')
                    echo -n ", \"mikrotik_file\": \"$safe_name.rsc\", \"mikrotik_entries\": $count"
                fi
                
                echo -n "}"
            else
                echo -n "    {\"name\": \"$safe_name\", \"exists\": false}"
            fi
        done

        echo ""
        echo "  ]"
        echo "}"
    } > "$json_file"

    chmod 644 "$json_file"
    log_info "JSON export created: $json_file"

    log_info "Backup completed successfully: processed=$processed, skipped=$skipped, failed=$failed"
}

main "$@"
exit 0
