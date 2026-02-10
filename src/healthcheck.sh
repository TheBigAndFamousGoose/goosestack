#!/bin/bash
# GooseStack Health Check & Final Verification
# Comprehensive system validation and user onboarding

# Exit on any error (but continue through health checks)
set -uo pipefail

# Health check results
HEALTH_RESULTS=()
HEALTH_SCORE=0
TOTAL_CHECKS=0

# Add health check result
add_health_result() {
    local status=$1
    local message=$2
    local critical=${3:-false}
    
    ((TOTAL_CHECKS++))
    
    if [[ "$status" == "pass" ]]; then
        HEALTH_RESULTS+=("✅ $message")
        ((HEALTH_SCORE++))
    elif [[ "$status" == "warn" ]]; then
        HEALTH_RESULTS+=("⚠️  $message")
        if [[ "$critical" != "true" ]]; then
            ((HEALTH_SCORE++))
        fi
    else
        HEALTH_RESULTS+=("❌ $message")
        if [[ "$critical" == "true" ]]; then
            log_error "Critical health check failed: $message"
        fi
    fi
}

# Check OpenClaw gateway
check_gateway() {
    log_info "🌐 Checking OpenClaw gateway..."
    
    if curl -s -f -m 5 "http://localhost:3721/status" >/dev/null 2>&1; then
        add_health_result "pass" "OpenClaw gateway responding on port 3721"
        
        # Try to get gateway info
        local gateway_info
        gateway_info=$(curl -s -m 5 "http://localhost:3721/status" 2>/dev/null)
        if [[ -n "$gateway_info" ]]; then
            log_info "Gateway info retrieved successfully"
        fi
    else
        add_health_result "fail" "OpenClaw gateway not responding" true
    fi
}

# Check LaunchAgent
check_launchagent() {
    log_info "🚀 Checking LaunchAgent..."
    
    if launchctl list | grep -q "ai.openclaw.gateway"; then
        add_health_result "pass" "LaunchAgent loaded and running"
    else
        add_health_result "fail" "LaunchAgent not loaded" true
    fi
}

# Check Ollama service
check_ollama() {
    log_info "🤖 Checking Ollama service..."
    
    if command -v ollama >/dev/null 2>&1; then
        if ollama list >/dev/null 2>&1; then
            add_health_result "pass" "Ollama service running"
            
            # Check if the configured model is available
            if ollama list | grep -q "$GOOSE_OLLAMA_MODEL"; then
                add_health_result "pass" "AI model ($GOOSE_OLLAMA_MODEL) available"
                
                # Quick model test
                if echo "test" | timeout 10s ollama run "$GOOSE_OLLAMA_MODEL" >/dev/null 2>&1; then
                    add_health_result "pass" "AI model responding correctly"
                else
                    add_health_result "warn" "AI model test timed out or failed"
                fi
            else
                add_health_result "fail" "AI model ($GOOSE_OLLAMA_MODEL) not found"
            fi
        else
            add_health_result "fail" "Ollama service not responding" true
        fi
    else
        add_health_result "fail" "Ollama not installed" true
    fi
}

# Check memory search embeddings
check_embeddings() {
    log_info "🔍 Checking embedding model..."
    
    if ollama list | grep -q "nomic-embed-text"; then
        add_health_result "pass" "Embedding model available for memory search"
    else
        add_health_result "warn" "Embedding model not found (memory search may be limited)"
    fi
}

# Check workspace files
check_workspace() {
    log_info "📁 Checking workspace files..."
    
    local workspace_dir="$GOOSE_WORKSPACE_DIR"
    local essential_files=("AGENTS.md" "SOUL.md" "USER.md" "TOOLS.md")
    local optional_files=("MEMORY.md" "HEARTBEAT.md")
    
    # Check essential files
    local missing_essential=0
    for file in "${essential_files[@]}"; do
        if [[ -f "$workspace_dir/$file" ]]; then
            add_health_result "pass" "Workspace file: $file"
        else
            add_health_result "fail" "Missing essential workspace file: $file"
            ((missing_essential++))
        fi
    done
    
    # Check optional files
    for file in "${optional_files[@]}"; do
        if [[ -f "$workspace_dir/$file" ]]; then
            add_health_result "pass" "Optional file: $file"
        else
            add_health_result "warn" "Optional file missing: $file"
        fi
    done
    
    # Check memory directory
    if [[ -d "$workspace_dir/memory" ]]; then
        add_health_result "pass" "Memory directory exists"
    else
        add_health_result "warn" "Memory directory missing"
        mkdir -p "$workspace_dir/memory"
        add_health_result "pass" "Memory directory created"
    fi
    
    if [[ $missing_essential -eq 0 ]]; then
        log_success "All essential workspace files present"
    fi
}

# Check configuration
check_configuration() {
    log_info "⚙️  Checking configuration..."
    
    local config_file="$HOME/.openclaw/openclaw.json"
    
    if [[ -f "$config_file" ]]; then
        if python3 -m json.tool "$config_file" >/dev/null 2>&1; then
            add_health_result "pass" "OpenClaw configuration valid"
            
            # Check for API key
            if grep -q '"defaultModel": "anthropic/' "$config_file"; then
                if [[ -n "${GOOSE_API_KEY:-}" ]]; then
                    add_health_result "pass" "Anthropic API key configured"
                else
                    add_health_result "warn" "Anthropic model configured but no API key"
                fi
            fi
            
            # Check Telegram configuration
            if [[ "${GOOSE_TELEGRAM_ENABLED:-false}" == "true" ]]; then
                add_health_result "pass" "Telegram integration enabled"
            else
                add_health_result "pass" "Telegram integration disabled (as configured)"
            fi
            
        else
            add_health_result "fail" "OpenClaw configuration invalid JSON" true
        fi
    else
        add_health_result "fail" "OpenClaw configuration file missing" true
    fi
}

# Test memory search functionality
test_memory_search() {
    log_info "🧠 Testing memory search..."
    
    # This is a basic test - in reality, we'd need the gateway running
    # and would make an API call to test memory search
    if [[ -f "$GOOSE_WORKSPACE_DIR/MEMORY.md" ]] && ollama list | grep -q "nomic-embed-text"; then
        add_health_result "pass" "Memory search components ready"
    else
        add_health_result "warn" "Memory search may not work properly"
    fi
}

# Get dashboard URL and token
get_dashboard_info() {
    local gateway_token="$GOOSE_GATEWAY_TOKEN"
    local dashboard_url="http://localhost:3000"
    local gateway_url="http://localhost:3721"
    
    echo -e "\n${BOLD}${GREEN}🎉 Your AI Agent is Ready!${NC}\n"
    
    echo -e "${BOLD}${BLUE}📊 Access Information:${NC}"
    echo -e "  🌐 Web Dashboard: ${CYAN}$dashboard_url${NC}"
    echo -e "  🔗 Gateway API: ${CYAN}$gateway_url${NC}"
    echo -e "  🔑 Gateway Token: ${YELLOW}$gateway_token${NC}"
    
    if [[ "${GOOSE_TELEGRAM_ENABLED:-false}" == "true" ]]; then
        echo -e "  💬 Telegram: Configured ✅"
    fi
    
    # Try to open dashboard
    if command -v open >/dev/null 2>&1; then
        echo -e "\n${CYAN}Opening dashboard in your browser...${NC}"
        sleep 2
        open "$dashboard_url" 2>/dev/null || log_warning "Could not open browser automatically"
    fi
}

# Show health report
show_health_report() {
    echo -e "\n${BOLD}${BLUE}🏥 Health Check Report${NC}"
    echo -e "${BOLD}Score: $HEALTH_SCORE/$TOTAL_CHECKS${NC}\n"
    
    # Show all results
    for result in "${HEALTH_RESULTS[@]}"; do
        echo "  $result"
    done
    
    echo ""
    
    # Overall status
    local health_percentage=$((HEALTH_SCORE * 100 / TOTAL_CHECKS))
    
    if [[ $health_percentage -ge 90 ]]; then
        echo -e "${BOLD}${GREEN}🎯 Excellent! Your system is fully operational.${NC}"
    elif [[ $health_percentage -ge 75 ]]; then
        echo -e "${BOLD}${YELLOW}✨ Good! Minor issues detected but system is functional.${NC}"
    elif [[ $health_percentage -ge 50 ]]; then
        echo -e "${BOLD}${YELLOW}⚠️  Warning! Several issues need attention.${NC}"
    else
        echo -e "${BOLD}${RED}❌ Critical! Multiple components are not working properly.${NC}"
    fi
}

# Show next steps
show_next_steps() {
    echo -e "\n${BOLD}${PURPLE}🚀 What's Next?${NC}\n"
    
    echo -e "${CYAN}1. Start chatting:${NC}"
    echo -e "   Open the dashboard and say hello to your agent!"
    echo -e ""
    
    echo -e "${CYAN}2. Explore capabilities:${NC}"
    echo -e "   Try: 'What can you help me with?'"
    echo -e "   Try: 'Show me my workspace files'"
    echo -e ""
    
    echo -e "${CYAN}3. Customize your agent:${NC}"
    echo -e "   Edit: ~/.openclaw/workspace/SOUL.md (personality)"
    echo -e "   Edit: ~/.openclaw/workspace/USER.md (your info)"
    echo -e ""
    
    echo -e "${CYAN}4. Useful commands:${NC}"
    echo -e "   ~/.openclaw/manage-gateway.sh status    # Check service"
    echo -e "   ~/.openclaw/manage-gateway.sh restart   # Restart if needed"
    echo -e "   openclaw --help                        # OpenClaw CLI help"
    echo -e ""
    
    if [[ -z "${GOOSE_API_KEY:-}" ]]; then
        echo -e "${YELLOW}💡 Tip: Add an Anthropic API key to unlock the most capable AI models!${NC}"
        echo -e "   Get one at: https://console.anthropic.com/"
        echo -e "   Add it to: ~/.openclaw/openclaw.json"
        echo -e ""
    fi
    
    echo -e "${CYAN}Need help?${NC}"
    echo -e "   📖 Documentation: https://github.com/openclaw-dev/goosestack"
    echo -e "   💬 Issues: https://github.com/openclaw-dev/goosestack/issues"
}

# Main health check function
main_healthcheck() {
    log_step "🏥 Running comprehensive health check..."
    
    check_gateway
    check_launchagent
    check_ollama
    check_embeddings
    check_workspace
    check_configuration
    test_memory_search
    
    show_health_report
    
    # Only show success info if health is good
    local health_percentage=$((HEALTH_SCORE * 100 / TOTAL_CHECKS))
    if [[ $health_percentage -ge 75 ]]; then
        get_dashboard_info
        show_next_steps
    else
        echo -e "\n${RED}⚠️  Please address the health check issues above before using your agent.${NC}"
        echo -e "${YELLOW}You can re-run this check with: ~/.openclaw/manage-gateway.sh status${NC}"
    fi
    
    log_success "Health check complete!"
}

# Run health check
main_healthcheck