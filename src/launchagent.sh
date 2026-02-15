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
    
    # Get the Node.js binary and OpenClaw entry point
    # LaunchAgents need explicit paths — symlinks and PATH tricks don't work reliably
    local node_path
    local openclaw_entry
    
    if ! command -v openclaw >/dev/null 2>&1; then
        log_error "OpenClaw binary not found in PATH"
        exit 1
    fi
    
    # Find the actual node binary
    # Note: Node.js can be in several locations depending on installation:
    # - /usr/local/bin/node (npm global install)
    # - /opt/homebrew/bin/node (Homebrew on Apple Silicon)
    # - /usr/bin/node (system install)
    # `which node` will find the first one in PATH, which is correct
    node_path=$(which node)
    
    # Find OpenClaw's real entry point (resolve the symlink chain)
    # On macOS: `which openclaw` → symlink → ../lib/node_modules/openclaw/openclaw.mjs
    local openclaw_symlink
    openclaw_symlink=$(which openclaw)
    
    # Resolve symlink manually (macOS readlink doesn't support -f)
    if [ -L "$openclaw_symlink" ]; then
        local link_target
        link_target=$(readlink "$openclaw_symlink")
        # If relative, resolve against the symlink's directory
        if [[ "$link_target" != /* ]]; then
            openclaw_entry="$(cd "$(dirname "$openclaw_symlink")" && cd "$(dirname "$link_target")" && pwd)/$(basename "$link_target")"
        else
            openclaw_entry="$link_target"
        fi
    else
        openclaw_entry="$openclaw_symlink"
    fi
    
    log_info "Node.js: $node_path"
    log_info "OpenClaw entry: $openclaw_entry"
    
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
        <string>$node_path</string>
        <string>$openclaw_entry</string>
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
        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
        <key>NODE_PATH</key>
        <string>$(npm root -g):/opt/homebrew/lib/node_modules:/usr/local/lib/node_modules</string>
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

# Load and start the LaunchAgent with retry logic
load_launch_agent() {
    log_info "Loading OpenClaw LaunchAgent..."
    
    local plist_file="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"
    local max_retries=2
    local retry=0
    
    while [[ $retry -lt $max_retries ]]; do
        if [[ $retry -gt 0 ]]; then
            log_info "Retry attempt $retry/$max_retries..."
            
            # Clean bootout and reload for retry attempts
            log_info "Performing clean bootout and reload..."
            launchctl bootout gui/$(id -u) "$plist_file" 2>/dev/null || true
            sleep 3
        else
            # First attempt - just unload if already loaded
            if launchctl list | grep -q "ai.openclaw.gateway"; then
                log_info "Unloading existing LaunchAgent..."
                launchctl unload "$plist_file" 2>/dev/null || true
                sleep 2
            fi
        fi
        
        # Load the LaunchAgent
        log_info "Loading LaunchAgent (attempt $((retry + 1))/$max_retries)..."
        launchctl load "$plist_file"
        
        if [[ $? -eq 0 ]]; then
            log_success "LaunchAgent loaded successfully"
            
            # Give it a moment to start
            sleep 5
            
            # Verify the gateway actually responds
            log_info "Verifying gateway responds to HTTP requests..."
            local verify_attempts=6  # 30 seconds total
            local verify_count=0
            
            while [[ $verify_count -lt $verify_attempts ]]; do
                if curl -s -f -m 3 "http://localhost:18789/status" >/dev/null 2>&1 || \
                   curl -s -f -m 3 "http://localhost:18789" >/dev/null 2>&1; then
                    log_success "Gateway is responding to HTTP requests"
                    return 0
                fi
                
                sleep 5
                ((verify_count++))
                
                if [[ $((verify_count % 3)) -eq 0 ]]; then
                    log_info "Still waiting for gateway HTTP response... (${verify_count}/$verify_attempts)"
                fi
            done
            
            # If we get here, the LaunchAgent loaded but gateway isn't responding
            log_warning "LaunchAgent loaded but gateway not responding to HTTP requests"
            
            # Show quick diagnostics on each failed attempt
            local stderr_log="$HOME/.openclaw/logs/gateway-stderr.log"
            if [[ -f "$stderr_log" ]] && [[ -s "$stderr_log" ]]; then
                log_info "Gateway stderr (last 5 lines):"
                tail -5 "$stderr_log" | sed 's/^/    /'
            fi
        else
            log_error "Failed to load LaunchAgent on attempt $((retry + 1))"
        fi
        
        ((retry++))
        
        if [[ $retry -lt $max_retries ]]; then
            log_info "Will retry in 5 seconds..."
            sleep 5
        fi
    done
    
    # All retries failed
    log_error "Failed to load LaunchAgent after $max_retries attempts"
    return 1
}

# Verify the gateway is running (simplified since retry logic moved to load_launch_agent)
verify_gateway_running() {
    log_info "🔍 Final verification that OpenClaw gateway is running..."
    
    # Quick final check
    if launchctl list | grep -q "ai.openclaw.gateway" && \
       (curl -s -f -m 3 "http://localhost:18789/status" >/dev/null 2>&1 || \
        curl -s -f -m 3 "http://localhost:18789" >/dev/null 2>&1); then
        log_success "OpenClaw gateway is running and responding"
        return 0
    fi
    
    log_error "OpenClaw gateway failed to start properly after all attempts"
    
    # Show comprehensive diagnostics
    show_gateway_diagnostics
    
    return 1
}

# Show comprehensive diagnostics when gateway startup fails
show_gateway_diagnostics() {
    echo -e "\n${YELLOW}🔧 Gateway Startup Diagnostics:${NC}"
    
    echo -e "\n📋 LaunchAgent Status:"
    if launchctl list | grep -q "ai.openclaw.gateway"; then
        launchctl list | grep "ai.openclaw.gateway"
    else
        echo "  ❌ LaunchAgent not found in launchctl list"
    fi
    
    echo -e "\n📄 Error Logs:"
    local stderr_log="$HOME/.openclaw/logs/gateway-stderr.log"
    local stdout_log="$HOME/.openclaw/logs/gateway-stdout.log"
    
    if [[ -f "$stderr_log" ]]; then
        echo -e "  Last 10 lines of $stderr_log:"
        tail -10 "$stderr_log" | sed 's/^/    /'
    else
        echo -e "  ❌ Error log not found: $stderr_log"
    fi
    
    if [[ -f "$stdout_log" ]]; then
        echo -e "\n  Last 10 lines of $stdout_log:"
        tail -10 "$stdout_log" | sed 's/^/    /'
    else
        echo -e "  ❌ Output log not found: $stdout_log"
    fi
    
    echo -e "\n🔧 Manual Recovery Steps:"
    echo -e "  1. Try OpenClaw doctor command:"
    echo -e "     ${CYAN}openclaw doctor --fix${NC}"
    echo -e ""
    echo -e "  2. Or manually restart the LaunchAgent:"
    echo -e "     ${CYAN}launchctl bootout gui/\$(id -u) ~/Library/LaunchAgents/ai.openclaw.gateway.plist${NC}"
    echo -e "     ${CYAN}launchctl load ~/Library/LaunchAgents/ai.openclaw.gateway.plist${NC}"
    echo -e ""
    echo -e "  3. Check logs for more details:"
    echo -e "     ${CYAN}~/.openclaw/manage-gateway.sh logs${NC}"
    echo -e ""
    echo -e "  4. Verify Node.js and OpenClaw are working:"
    echo -e "     ${CYAN}which node && node --version${NC}"
    echo -e "     ${CYAN}which openclaw && openclaw --version${NC}"
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
    
    # On reinstall, check if gateway already works
    if [[ "${GOOSE_REINSTALL:-false}" == "true" ]]; then
        if curl -s -f -m 3 "http://localhost:18789/status" >/dev/null 2>&1; then
            log_success "OpenClaw gateway already running, skipping setup"
            create_management_script
            return 0
        fi
        log_info "Gateway not responding, reconfiguring..."
    fi
    
    # Don't create plist manually — openclaw gateway install handles it in Phase 8
    create_management_script
    setup_watchdog
    prevent_sleep
    
    log_success "Auto-start setup complete (gateway will start in Phase 8)"
}

# Run LaunchAgent setup
main_setup_launchagent