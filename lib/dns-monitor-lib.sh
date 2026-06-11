#!/bin/bash
# Common logging library for DNS monitor scripts

init_script() {
    check_root
    load_config
}

load_config() {

    : "${CONFIG_FILE:=/etc/unbound-dns-monitor/unbound-dns-monitor.cfg}"

    [[ -r "$CONFIG_FILE" ]] ||
        error_exit "Configuration file not found: $CONFIG_FILE"

    source "$CONFIG_FILE"
}

# Function: init_logging
# Description: Initialize logging for a script
init_logging() {

    export SCRIPT_NAME=$(basename "$0")
    export SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

    # Set default log level if not defined
    export LOG_LEVEL="${LOG_LEVEL:-INFO}"
    export LOG_TAG_PREFIX="${LOG_TAG_PREFIX:-dns-monitor}"

    export LOG_TAG="${LOG_TAG_PREFIX}-${SCRIPT_NAME}"
    export TEMP_DIR="${TEMP_DIR:=/tmp}"

    # Create temp directory if needed
    if [[ ! -d "$TEMP_DIR" ]]; then
        mkdir -p "$TEMP_DIR" 2>/dev/null || {
            echo "ERROR: Cannot create temp directory: $TEMP_DIR" >&2
        }
    fi
}

# Function: log_message
# Description: Log message with level and tag
# Usage: log_message "LEVEL" "message"
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Check if log level should be written
    case "$LOG_LEVEL" in
        DEBUG)
            [[ "$level" =~ ^(DEBUG|INFO|WARN|ERROR)$ ]] || return 0
            ;;
        INFO)
            [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]] || return 0
            ;;
        WARN)
            [[ "$level" =~ ^(WARN|ERROR)$ ]] || return 0
            ;;
        ERROR)
            [[ "$level" == "ERROR" ]] || return 0
            ;;
        *)
            [[ "$level" =~ ^(INFO|WARN|ERROR)$ ]] || return 0
            ;;
    esac

    local priority=info
    case "$level" in
	DEBUG) priority=debug ;;
        INFO) priority=info ;;
	WARN) priority=warning ;;
        ERROR) priority=err ;;
    esac

    # Log to syslog with tag
    logger -t "$LOG_TAG" -p "user.$priority" "$message"

    # Also output to stderr for errors and debug
    if [[ "$level" == "ERROR" ]] || [[ "$level" == "DEBUG" && "$LOG_LEVEL" == "DEBUG" ]]; then
        echo "$timestamp [$level] $message" >&2
    fi
}

# Function: log_debug
log_debug() { log_message "DEBUG" "$1"; }

# Function: log_info
log_info() { log_message "INFO" "$1"; }

# Function: log_warn
log_warn() { log_message "WARN" "$1"; }

# Function: log_error
log_error() { log_message "ERROR" "$1"; }

# Function: error_exit
error_exit() {
    log_error "$1"
    exit "${2:-1}"
}

# Function: check_root
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error_exit "This script must be run as root"
    fi
}

# Function: check_ipset
check_ipset() {
    local ipset_name="$1"
    if ! $IPSET_CMD list "$ipset_name" -n &>/dev/null; then
        log_warn "IPSet '$ipset_name' does not exist"
        return 1
    fi
    return 0
}

# Function: create_ipset_if_not_exists
create_ipset_if_not_exists() {
    local ipset_name="$1"
    local ipset_type="${2:-hash:net}"

    if ! $IPSET_CMD list "$ipset_name" -n &>/dev/null; then
        log_info "Creating ipset: $ipset_name (type: $ipset_type)"
        $IPSET_CMD create "$ipset_name" "$ipset_type" family inet hashsize "$IPSET_HASHSIZE" maxelem "$IPSET_MAXELEM" comment
        if [[ $? -eq 0 ]]; then
            log_info "IPSet '$ipset_name' created successfully"
            return 0
        else
            log_error "Failed to create ipset '$ipset_name'"
            return 1
        fi
    fi
    return 0
}

require_vars() {
    local missing=0
    local var

    for var in "$@"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required variable '$var' is not set"
            missing=1
        fi
    done

    return $missing
}

check_net_cmds() {
    require_vars \
        IP_CMD \
        IPSET_CMD ||
        error_exit "Required network commands missing"
}

ensure_ipsets() {
    (( $# % 2 == 0 )) || \
        error_exit "ensure_ipsets: arguments must be pairs"

    local set type

    while (( $# )); do
        set="$1"
        type="$2"
        shift 2

        create_ipset_if_not_exists "$set" "$type" ||
            error_exit "Cannot create ipset $set"
    done
}
