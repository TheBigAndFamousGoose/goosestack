#!/bin/bash
# GooseStack LaunchAgent Setup
# Creates and loads macOS LaunchAgent for OpenClaw gateway auto-start

# Exit on any error
set -euo pipefail

# Create LaunchAgent plist
create_launch_agent() {
    log_info "🚀 Setting up OpenClaw auto-start..."
    
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    local plist_file="$launch_agents_dir/ai.openclaw.gateway.plist"
    
    # Create LaunchAgents directory if it doesn't exist
    mkdir -p "$launch_agents_dir"
    
    # Get the path to openclaw binary (resolve symlinks for launchd)
    local openclaw_path
    if command -v openclaw >/dev/null 2>&1; then
        # Try different ways to resolve symlinks (different macOS versions have different tools)
        if command -v greadlink >/dev/null 2>&1; then
            # If GNU coreutils is installed
            openclaw_path=$(greadlink -f "$(which openclaw)")
        elif command -v readlink >/dev/null 2>&1 && readlink -f "$(which openclaw)" >/dev/null 2>&1; then
            # If readlink supports -f
            openclaw_path=$(readlink -f "$(which openclaw)")
        else
            # Fallback: use the symlink as-is (should work fine for most cases)
            openclaw_path=$(which openclaw)
            log_info "Using openclaw path as-is (symlink resolution not available): $openclaw_path"
        fi
    else
        log_error "OpenClaw binary not found in PATH"
        exit 1
    fi
    
    # Create the plist file
    log_info "Creating LaunchAgent configuration..."
    
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.openclaw.gateway</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>$openclaw_path</string>
        <string>gateway</string>
        <string>start</string>
    </array>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>KeepAlive</key>
    <true/>
    
    <key>StandardOutPath</key>
    <string>$HOME/.openclaw/logs/gateway-stdout.log</string>
    
    <key>StandardErrorPath</key>
    <string>$HOME/.openclaw/logs/gateway-stderr.log</string>
    
    <key>WorkingDirectory</key>
    <string>$HOME/.openclaw</string>
    
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>NODE_ENV</key>
        <string>production</string>
    </dict>
    
    <key>ThrottleInterval</key>
    <integer>10</integer>
    
    <key>ExitTimeOut</key>
    <integer>30</integer>
    
    <key>SoftResourceLimits</key>
    <dict>
        <key>NumberOfFiles</key>
        <integer>8192</integer>
    </dict>
    
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF
    
    # Create logs directory
    mkdir -p "$HOME/.openclaw/logs"
    
    log_success "LaunchAgent configuration created"
    echo -e "  📄 File: $plist_file"
}

# Load and start the LaunchAgent
load_launch_agent() {
    log_info "Loading OpenClaw LaunchAgent..."
    
    local plist_file="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    
    # Unload if already loaded (to reload with new settings)
    if launchctl list | grep -q "ai.openclaw.gateway"; then
        log_info "Unloading existing LaunchAgent..."
        launchctl unload "$plist_file" 2>/dev/null || true
        sleep 2
    fi
    
    # Load the LaunchAgent
    launchctl load "$plist_file"
    
    if [[ $? -eq 0 ]]; then
        log_success "LaunchAgent loaded successfully"
    else
        log_error "Failed to load LaunchAgent"
        exit 1
    fi
    
    # Give it a moment to start
    sleep 3
}

# Verify the gateway is running
verify_gateway_running() {
    log_info "🔍 Verifying OpenClaw gateway is running..."
    
    local max_attempts=30
    local attempt=0
    
    while [[ $attempt -lt $max_attempts ]]; do
        # Check if the process is running via launchctl
        if launchctl list | grep -q "ai.openclaw.gateway"; then
            # Check if the gateway is responding (try both /status and root)
            if curl -s -f -m 3 "http://localhost:18789/status" >/dev/null 2>&1 || \
               curl -s -f -m 3 "http://localhost:18789" >/dev/null 2>&1; then
                log_success "OpenClaw gateway is running and responding"
                return 0
            fi
        fi
        
        sleep 2
        ((attempt++))
        
        # Show progress
        if [[ $((attempt % 5)) -eq 0 ]]; then
            log_info "Still waiting for gateway to start... (${attempt}/${max_attempts})"
        fi
    done
    
    log_error "OpenClaw gateway failed to start properly"
    
    # Show some diagnostics
    echo -e "\n${YELLOW}🔧 Diagnostics:${NC}"
    echo -e "LaunchAgent status:"
    launchctl list | grep -E "(PID|ai.openclaw)" || echo "  Not found in launchctl list"
    
    echo -e "\nRecent logs:"
    if [[ -f "$HOME/.openclaw/logs/gateway-stderr.log" ]]; then
        tail -10 "$HOME/.openclaw/logs/gateway-stderr.log" || echo "  No error logs found"
    else
        echo "  No log files found"
    fi
    
    return 1
}

# Create helpful management aliases
create_management_script() {
    log_info "📝 Creating management shortcuts..."
    
    local script_file="$HOME/.openclaw/manage-gateway.sh"
    
    cat > "$script_file" << 'EOF'
#!/bin/bash
# OpenClaw Gateway Management Script

PLIST_FILE="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"

case "${1:-status}" in
    start)
        echo "Starting OpenClaw gateway..."
        launchctl load "$PLIST_FILE" 2>/dev/null || echo "Already loaded"
        ;;
    stop)
        echo "Stopping OpenClaw gateway..."
        launchctl unload "$PLIST_FILE" 2>/dev/null || echo "Not loaded"
        ;;
    restart)
        echo "Restarting OpenClaw gateway..."
        launchctl unload "$PLIST_FILE" 2>/dev/null || true
        sleep 2
        launchctl load "$PLIST_FILE"
        ;;
    status)
        echo "OpenClaw Gateway Status:"
        if launchctl list | grep -q "ai.openclaw.gateway"; then
            echo "  ✅ LaunchAgent: Running"
        else
            echo "  ❌ LaunchAgent: Not running"
        fi
        
        if curl -s -f "http://localhost:18789/status" >/dev/null 2>&1; then
            echo "  ✅ HTTP Gateway: Responding"
        else
            echo "  ❌ HTTP Gateway: Not responding"
        fi
        ;;
    logs)
        echo "Recent gateway logs:"
        echo "--- STDOUT ---"
        tail -20 "$HOME/.openclaw/logs/gateway-stdout.log" 2>/dev/null || echo "No stdout logs"
        echo -e "\n--- STDERR ---"
        tail -20 "$HOME/.openclaw/logs/gateway-stderr.log" 2>/dev/null || echo "No stderr logs"
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|logs}"
        echo ""
        echo "Commands:"
        echo "  start   - Start the OpenClaw gateway"
        echo "  stop    - Stop the OpenClaw gateway"
        echo "  restart - Restart the OpenClaw gateway"
        echo "  status  - Show gateway status"
        echo "  logs    - Show recent logs"
        ;;
esac
EOF
    
    chmod +x "$script_file"
    
    log_success "Management script created: $script_file"
    log_info "You can manage the gateway with: ~/.openclaw/manage-gateway.sh {start|stop|restart|status|logs}"
}

# Prevent sleep and keep system awake for AI workloads
prevent_sleep() {
    log_info "⏰ Configuring sleep prevention for AI workloads..."
    
    # Disable ALL sleep modes: system sleep, display sleep, disk sleep,
    # hibernate, standby, and auto power off. Display sleep alone can
    # escalate to hibernate on some Macs.
    log_info "Disabling all sleep and hibernate modes..."
    sudo pmset -a sleep 0 displaysleep 0 disksleep 0 hibernatemode 0 standby 0 autopoweroff 0
    
    if [[ $? -eq 0 ]]; then
        log_success "All sleep/hibernate modes disabled via pmset"
    else
        log_warning "Could not configure pmset (requires sudo) — trying caffeinate fallback"
    fi
    
    # Start caffeinate as belt-and-suspenders backup
    # -d = prevent display sleep, -i = prevent idle sleep,
    # -m = prevent disk sleep, -s = prevent system sleep on AC
    log_info "Starting caffeinate background process..."
    
    # Kill any existing caffeinate processes
    killall caffeinate 2>/dev/null || true
    
    # Start caffeinate with ALL prevention flags
    nohup caffeinate -dims > "$HOME/.openclaw/logs/caffeinate.log" 2>&1 &
    local caffeinate_pid=$!
    
    # Save the PID so we can manage it later
    echo "$caffeinate_pid" > "$HOME/.openclaw/caffeinate.pid"
    
    log_success "Caffeinate started (PID: $caffeinate_pid)"
    
    # User notification
    echo -e "\n${YELLOW}☕ Sleep Prevention Active:${NC}"
    echo -e "  • System will not sleep automatically"
    echo -e "  • Display and disk sleep disabled"
    echo -e "  • Caffeinate keeping system awake"
    echo -e "  • This ensures AI agents can work 24/7"
    echo -e "  • To restore normal sleep: sudo pmset -a sleep 1 displaysleep 10 disksleep 10"
}

# Setup watchdog monitoring
setup_watchdog() {
    log_info "🐕 Setting up gateway watchdog..."
    
    local src_watchdog="${INSTALL_DIR}/src/templates/watchdog.sh"
    local dest_watchdog="$HOME/.openclaw/watchdog.sh"
    local plist_file="$HOME/Library/LaunchAgents/ai.openclaw.watchdog.plist"
    
    # Copy watchdog script
    if [[ -f "$src_watchdog" ]]; then
        cp "$src_watchdog" "$dest_watchdog"
        chmod +x "$dest_watchdog"
        log_info "Watchdog script installed to $dest_watchdog"
    else
        log_error "Watchdog template not found at $src_watchdog"
        return 1
    fi
    
    # Create LaunchAgent plist for watchdog
    cat > "$plist_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.openclaw.watchdog</string>
    
    <key>ProgramArguments</key>
    <array>
        <string>$dest_watchdog</string>
    </array>
    
    <key>RunAtLoad</key>
    <true/>
    
    <key>StartInterval</key>
    <integer>300</integer>
    
    <key>StandardOutPath</key>
    <string>$HOME/.openclaw/logs/watchdog-stdout.log</string>
    
    <key>StandardErrorPath</key>
    <string>$HOME/.openclaw/logs/watchdog-stderr.log</string>
    
    <key>WorkingDirectory</key>
    <string>$HOME/.openclaw</string>
</dict>
</plist>
EOF
    
    # Load the watchdog LaunchAgent
    if launchctl unload "$plist_file" 2>/dev/null; then
        log_info "Unloaded existing watchdog LaunchAgent"
    fi
    
    if launchctl load "$plist_file" 2>/dev/null; then
        log_success "Watchdog LaunchAgent loaded successfully"
    else
        log_error "Failed to load watchdog LaunchAgent"
        return 1
    fi
    
    log_success "Gateway watchdog configured to run every 5 minutes"
}

# Main LaunchAgent setup function
main_setup_launchagent() {
    log_info "🎯 Setting up OpenClaw auto-start service..."
    
    create_launch_agent
    load_launch_agent
    create_management_script
    setup_watchdog
    prevent_sleep
    
    # Verify it's working
    if verify_gateway_running; then
        log_success "OpenClaw LaunchAgent setup complete!"
        
        # Summary
        echo -e "\n${BOLD}${BLUE}🎯 Auto-Start Summary:${NC}"
        echo -e "  ✅ LaunchAgent created and loaded"
        echo -e "  ✅ OpenClaw gateway running on port 18789"
        echo -e "  ✅ Auto-starts on login"
        echo -e "  ✅ Restarts automatically if crashed"
        echo -e "  ✅ Management script available"
        echo -e "  ✅ Sleep prevention configured"
        
        echo -e "\n${CYAN}💡 Management commands:${NC}"
        echo -e "  ~/.openclaw/manage-gateway.sh status   # Check status"
        echo -e "  ~/.openclaw/manage-gateway.sh restart  # Restart service"
        echo -e "  ~/.openclaw/manage-gateway.sh logs     # View logs"
        
    else
        log_warning "LaunchAgent was created but gateway is not responding"
        log_info "You may need to start it manually or check the logs"
    fi
}

# Run LaunchAgent setup
main_setup_launchagent