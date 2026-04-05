#!/bin/bash
# Script: save_ipsets.sh
# Description: Save specific ipsets content to web directory

# Load common library
SCRIPT_NAME="save_ipsets"
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
    log_info "Starting ipset backup"

    # Check root
    check_root

    # Load configuration
    source "$CONFIG_FILE"

    # Create output directory if it doesn't exist
    if [[ ! -d "$WEB_OUTPUT_DIR" ]]; then
        log_info "Creating output directory: $WEB_OUTPUT_DIR"
        mkdir -p "$WEB_OUTPUT_DIR" || error_exit "Failed to create directory $WEB_OUTPUT_DIR"
        chmod 755 "$WEB_OUTPUT_DIR"
    fi

    # List of ipsets to save (configurable). All route ipset - hash:net
    local IPSET_LIST="$ROUTE_YOUTUBE_IPSET"

    log_info "Backing up ipsets: $IPSET_LIST"

    local processed=0
    local failed=0
    local not_found=0

    # Process each ipset
    for IPSET_NAME in $IPSET_LIST; do
        local output_file="$WEB_OUTPUT_DIR/$IPSET_NAME.txt"
        local temp_file="${TEMP_DIR}/${IPSET_NAME}.tmp"

        create_ipset_if_not_exists "${IPSET_NAME}" "hash:net"

        log_debug "Processing ipset: $IPSET_NAME -> $output_file"

        # Clear temp file
        > "$temp_file"

        # Parse ipset entries
        $IPSET_CMD list "$IPSET_NAME" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | while read line; do
            # Extract IP/CIDR (first field)
            local ip=$(echo "$line" | $AWK_CMD '{print $1}')
            # Extract comment if exists
            local comment=$(echo "$line" | grep -o 'comment "[^"]*"' | sed 's/comment "\(.*\)"/\1/')

            if [[ -n "$comment" ]]; then
                echo "$ip $comment" >> "$temp_file"
            else
                echo "$ip" >> "$temp_file"
            fi
        done

        # Move temp file to final destination
        if mv "$temp_file" "$output_file" 2>/dev/null; then
            chmod 644 "$output_file" 2>/dev/null
            local count=$(wc -l < "$output_file")
            log_info "Saved $count entries from $IPSET_NAME"
            ((processed++))
        else
            log_error "Failed to save $IPSET_NAME"
            ((failed++))
        fi
    done

    # Create index file
    local index_file="$WEB_OUTPUT_DIR/index.txt"
    {
        echo "# IPSets Backup Summary"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# Target ipsets: $IPSET_LIST"
        echo "# Successfully saved: $processed"
        echo "# Not found: $not_found"
        echo "# Failed: $failed"
        echo ""
        echo "## Available files:"
        for IPSET_NAME in $IPSET_LIST; do
            if [[ -f "$WEB_OUTPUT_DIR/$IPSET_NAME.txt" ]]; then
                local count=$(wc -l < "$WEB_OUTPUT_DIR/$IPSET_NAME.txt")
                echo "$IPSET_NAME.txt - $count entries"
            else
                echo "$IPSET_NAME.txt - NOT FOUND or EMPTY"
            fi
        done
    } > "$index_file"

    chmod 644 "$index_file"
    log_info "Created index file: $index_file"

    # Create JSON format if enabled
    if [[ "$ENABLE_WEB_EXPORT" == "yes" ]]; then
        local json_file="$WEB_OUTPUT_DIR/ipsets.json"
        {
            echo "{"
            echo "  \"generated\": \"$(date -Iseconds)\","
            echo "  \"ipsets\": ["
            local first=true
            for IPSET_NAME in $IPSET_LIST; do
                if [[ -f "$WEB_OUTPUT_DIR/$IPSET_NAME.txt" ]]; then
                    if [[ "$first" = true ]]; then
                        first=false
                    else
                        echo ","
                    fi
                    echo "    {"
                    echo "      \"name\": \"$IPSET_NAME\","
                    echo "      \"file\": \"$IPSET_NAME.txt\","
                    echo "      \"entries\": $(wc -l < "$WEB_OUTPUT_DIR/$IPSET_NAME.txt"),"
                    echo "      \"exists\": true"
                    echo -n "    }"
                else
                    if [[ "$first" = true ]]; then
                        first=false
                    else
                        echo ","
                    fi
                    echo "    {"
                    echo "      \"name\": \"$IPSET_NAME\","
                    echo "      \"exists\": false"
                    echo -n "    }"
                fi
            done
            echo ""
            echo "  ]"
            echo "}"
        } > "$json_file"

        chmod 644 "$json_file"
        log_info "Created JSON file: $json_file"
    fi

    log_info "Backup completed - Processed: $processed, Not found: $not_found, Failed: $failed"
}

# Run main function
main

exit 0
