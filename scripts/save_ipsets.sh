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

    local ipset_list
    local ipset_name
    local output_file
    local temp_file
    local index_file
    local json_file

    local processed=0
    local failed=0

    init_logging
    init_script

    check_net_cmds

    require_vars \
        IPSET_CMD \
        AWK_CMD \
        ROUTE_YOUTUBE_IPSET \
        WEB_OUTPUT_DIR \
        TEMP_DIR \
        ENABLE_WEB_EXPORT ||
        error_exit "Required configuration variables missing"

    source "$CONFIG_FILE"

    mkdir -p "$WEB_OUTPUT_DIR" ||
        error_exit "Failed to create directory $WEB_OUTPUT_DIR"

    chmod 755 "$WEB_OUTPUT_DIR"

    ipset_list="${ROUTE_YOUTUBE_IPSET:-}"

    log_info "Starting ipset backup"
    log_info "Backing up ipsets: $ipset_list"

    #
    # ------------------------------------------------------------------
    # Export ipsets
    # ------------------------------------------------------------------
    #

    for ipset_name in $ipset_list; do

        output_file="$WEB_OUTPUT_DIR/$ipset_name.txt"
        temp_file="$TEMP_DIR/${ipset_name}.tmp"

        ensure_ipsets \
            "$ipset_name" hash:net

        log_debug "Processing $ipset_name -> $output_file"

        : > "$temp_file"

        $IPSET_CMD list "$ipset_name" 2>/dev/null |
        grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' |
        while read -r line; do

            local ip comment

            ip=$($AWK_CMD '{print $1}' <<< "$line")
            comment=$(echo "$line" | grep -o 'comment "[^"]*"' | sed 's/comment "\(.*\)"/\1/')

            if [[ -n "$comment" ]]; then
                echo "$ip $comment" >> "$temp_file"
            else
                echo "$ip" >> "$temp_file"
            fi

        done

        if mv "$temp_file" "$output_file"; then

            chmod 644 "$output_file" 2>/dev/null || true

            log_info "Saved $ipset_name ($(wc -l < "$output_file")) entries"

            ((processed++))

        else
            log_error "Failed to save $ipset_name"
            ((failed++))
        fi

    done

    #
    # ------------------------------------------------------------------
    # Index file
    # ------------------------------------------------------------------
    #

    index_file="$WEB_OUTPUT_DIR/index.txt"

    {
        echo "# IPSets Backup Summary"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# IPsets: $ipset_list"
        echo "# Processed: $processed"
        echo "# Failed: $failed"
        echo ""

        echo "## Files:"

        for ipset_name in $ipset_list; do
            if [[ -f "$WEB_OUTPUT_DIR/$ipset_name.txt" ]]; then
                echo "$ipset_name.txt - $(wc -l < "$WEB_OUTPUT_DIR/$ipset_name.txt") entries"
            else
                echo "$ipset_name.txt - missing"
            fi
        done

    } > "$index_file"

    chmod 644 "$index_file"

    log_info "Index created: $index_file"

    #
    # ------------------------------------------------------------------
    # JSON export
    # ------------------------------------------------------------------
    #

    if [[ "${ENABLE_WEB_EXPORT:-no}" == "yes" ]]; then

        json_file="$WEB_OUTPUT_DIR/ipsets.json"

        {
            echo "{"
            echo "  \"generated\": \"$(date -Iseconds)\","
            echo "  \"ipsets\": ["

            local first=true

            for ipset_name in $ipset_list; do

                if [[ "$first" == true ]]; then
                    first=false
                else
                    echo ","
                fi

                if [[ -f "$WEB_OUTPUT_DIR/$ipset_name.txt" ]]; then
                    echo "    {"
                    echo "      \"name\": \"$ipset_name\","
                    echo "      \"file\": \"$ipset_name.txt\","
                    echo "      \"entries\": $(wc -l < "$WEB_OUTPUT_DIR/$ipset_name.txt"),"
                    echo "      \"exists\": true"
                    echo -n "    }"
                else
                    echo "    {"
                    echo "      \"name\": \"$ipset_name\","
                    echo "      \"exists\": false"
                    echo -n "    }"
                fi

            done

            echo ""
            echo "  ]"
            echo "}"

        } > "$json_file"

        chmod 644 "$json_file"

        log_info "JSON export created: $json_file"

    fi

    log_info "Backup completed: processed=$processed failed=$failed"
}

main "$@"

exit 0
