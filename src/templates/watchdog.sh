#!/bin/bash
# OpenClaw Gateway Watchdog Script
# Monitors the gateway on localhost:18789 and restarts it if not responding
# Designed to run every 5 minutes via cron or launchd

set -euo pipefail

# Configuration
GATEWAY_URL="http://localhost:18789"
LOG_FILE="$HOME/.openclaw/logs/watchdog.log"
MAX_RESTART_ATTEMPTS=3
RESTART_COOLDOWN=300  # 5 minutes between restart attempts

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Logging function
log_message() {
    local level=$1
    local message=$2
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
}

# Check if gateway is responding
check_gateway() {
    # Try to ping the gateway with a 10 second timeout
    if curl -s -f -m 10 "$GATEWAY_URL/health" >/dev/null 2>&1; then
        return 0  # Gateway is responding
    elif curl -s -f -m 10 "$GATEWAY_URL" >/dev/null 2>&1; then
        return 0  # Gateway is responding (even if no /health endpoint)
    else
        return 1  # Gateway is not responding
    fi
}

# Get restart attempt count for today
get_restart_count() {
    local today=$(date '+%Y-%m-%d')
    grep -c "\[$today.*\] \[INFO\] Restarting OpenClaw gateway" "$LOG_FILE" 2>/dev/null || echo "0"
}

# Check if we're in cooldown period
in_cooldown() {
    local last_restart=$(grep "Restarting OpenClaw gateway" "$LOG_FILE" | tail -1 | grep -o '\[.*\]' | head -1 | tr -d '[]' || echo "")
    if [[ -n "$last_restart" ]]; then
        local last_restart_epoch=$(date -j -f '%Y-%m-%d %H:%M:%S' "$last_restart" '+%s' 2>/dev/null || echo "0")
        local current_epoch=$(date '+%s')
        local time_diff=$((current_epoch - last_restart_epoch))
        
        if [[ $time_diff -lt $RESTART_COOLDOWN ]]; then
            log_message "DEBUG" "In cooldown period (${time_diff}s since last restart, need ${RESTART_COOLDOWN}s)"
            return 0  # In cooldown
        fi
    fi
    return 1  # Not in cooldown
}

# Restart the gateway via launchctl
restart_gateway() {
    local plist_file="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    
    log_message "INFO" "Restarting OpenClaw gateway..."
    
    # First try to unload
    if launchctl unload "$plist_file" 2>/dev/null; then
        log_message "INFO" "Successfully unloaded LaunchAgent"
        sleep 3
    else
        log_message "WARN" "Could not unload LaunchAgent (may not be loaded)"
    fi
    
    # Then load it again
    if launchctl load "$plist_file" 2>/dev/null; then
        log_message "INFO" "Successfully reloaded LaunchAgent"
        return 0
    else
        log_message "ERROR" "Failed to reload LaunchAgent"
        return 1
    fi
}

# Main watchdog logic
main() {
    log_message "DEBUG" "Watchdog check started"
    
    # Check if gateway is responding
    if check_gateway; then
        log_message "DEBUG" "Gateway is responding normally"
        return 0
    fi
    
    log_message "WARN" "Gateway is not responding on $GATEWAY_URL"
    
    # Check restart limits
    local restart_count=$(get_restart_count)
    if [[ $restart_count -ge $MAX_RESTART_ATTEMPTS ]]; then
        log_message "ERROR" "Max restart attempts ($MAX_RESTART_ATTEMPTS) reached for today. Manual intervention required."
        return 1
    fi
    
    # Check cooldown period
    if in_cooldown; then
        log_message "INFO" "Skipping restart due to cooldown period"
        return 0
    fi
    
    # Attempt restart
    log_message "INFO" "Attempting to restart gateway (attempt $((restart_count + 1))/$MAX_RESTART_ATTEMPTS)"
    
    if restart_gateway; then
        # Wait a bit and verify it's working
        sleep 10
        if check_gateway; then
            log_message "INFO" "Gateway restart successful and verified"
        else
            log_message "ERROR" "Gateway restart completed but still not responding"
        fi
    else
        log_message "ERROR" "Gateway restart failed"
        return 1
    fi
}

# Run the watchdog
main "$@"