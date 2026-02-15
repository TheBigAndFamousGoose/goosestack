#!/bin/bash
# install-security.sh - ClawSec Security Suite Installation for GooseStack
set -euo pipefail







# Check if OpenClaw is available for cron setup
check_openclaw() {
    if command -v openclaw >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Download and install a ClawSec skill from GitHub releases (no npm dependency)
install_clawsec_skill() {
    local skill_name="$1"
    local version="$2"
    local dest="$HOME/.openclaw/workspace/skills/$skill_name"
    local base_url="https://github.com/prompt-security/clawsec/releases/download/${skill_name}-v${version}"
    local max_retries=3
    local retry_delay=5

    mkdir -p "$dest"

    local attempt=0
    while (( attempt < max_retries )); do
        attempt=$((attempt + 1))

        # Try GitHub release tarball first
        local tarball_url="${base_url}/${skill_name}.tar.gz"
        if curl -fsSL --retry 2 "$tarball_url" -o "/tmp/${skill_name}.tar.gz" 2>/dev/null; then
            if tar xzf "/tmp/${skill_name}.tar.gz" -C "$dest" --strip-components=1 2>/dev/null || \
               tar xzf "/tmp/${skill_name}.tar.gz" -C "$dest" 2>/dev/null; then
                rm -f "/tmp/${skill_name}.tar.gz"
                return 0
            fi
        fi

        # Fallback: try npx clawhub
        if npx clawhub@latest install "$skill_name" 2>/dev/null; then
            return 0
        fi

        if (( attempt < max_retries )); then
            log_warning "Attempt $attempt/$max_retries failed for $skill_name, retrying in ${retry_delay}s..."
            sleep "$retry_delay"
            retry_delay=$((retry_delay * 2))
        fi
    done

    return 1
}

# Install ClawSec security suite
install_clawsec() {
    log_step "Installing ClawSec Security Suite..."
    
    # Install clawsec-suite
    log_info "Installing clawsec-suite package..."
    if ! install_clawsec_skill "clawsec-suite" "0.0.9"; then
        log_error "Failed to install clawsec-suite"
        return 1
    fi
    
    # Install soul-guardian
    log_info "Installing soul-guardian package..."
    if ! install_clawsec_skill "soul-guardian" "0.0.3"; then
        log_error "Failed to install soul-guardian"
        return 1
    fi
    
    log_success "ClawSec packages installed successfully"
    
    # Initialize soul-guardian baselines
    log_info "Initializing soul-guardian security baselines..."
    local soul_guardian_script="$HOME/.openclaw/workspace/skills/soul-guardian/scripts/soul_guardian.py"
    
    if [[ -f "$soul_guardian_script" ]]; then
        if python3 "$soul_guardian_script" init --actor setup --note "GooseStack initial baseline"; then
            log_success "Soul-guardian baselines initialized"
        else
            log_warning "Soul-guardian initialization had issues, but continuing..."
        fi
    else
        log_warning "Soul-guardian script not found at expected location, skipping initialization"
    fi
    
    # Update HEARTBEAT.md template with soul-guardian check
    log_info "Adding soul-guardian check to HEARTBEAT.md template..."
    local heartbeat_template="$INSTALL_DIR/src/templates/HEARTBEAT.md"
    
    if [[ -f "$heartbeat_template" ]]; then
        # Add soul-guardian check section if not already present
        if ! grep -q "Soul-Guardian Security" "$heartbeat_template"; then
            # Insert before the "## Settings" section
            local temp_file=$(mktemp)
            awk '/^## Settings/ {
                print "## Soul-Guardian Security"
                print ""
                print "*Security monitoring and file integrity checks:*"
                print ""
                print "- [ ] Run soul-guardian scan for file tampering"
                print "- [ ] Check for suspicious process activity"  
                print "- [ ] Review security audit logs"
                print ""
                print $0
                next
            } {print}' "$heartbeat_template" > "$temp_file"
            
            mv "$temp_file" "$heartbeat_template"
            log_success "Updated HEARTBEAT.md template with security checks"
        else
            log_info "HEARTBEAT.md template already contains soul-guardian checks"
        fi
    else
        log_warning "HEARTBEAT.md template not found, skipping update"
    fi
    
    # Set up daily security audit cron if OpenClaw is available
    if check_openclaw; then
        log_info "Setting up daily security audit cron job..."
        
        # Create a daily security audit cron job
        local cron_command="python3 ~/.openclaw/workspace/skills/soul-guardian/scripts/soul_guardian.py scan --mode full --report --actor cron --note \"Daily GooseStack security audit\""
        
        if openclaw cron add --schedule "0 2 * * *" --command "$cron_command" --description "Daily GooseStack Security Audit" 2>/dev/null; then
            log_success "Daily security audit cron job scheduled for 2:00 AM"
        else
            log_warning "Could not set up cron job - you can manually run security scans"
        fi
    else
        log_warning "OpenClaw not available - skipping cron setup"
        log_info "You can manually run security scans with: python3 ~/.openclaw/workspace/skills/soul-guardian/scripts/soul_guardian.py scan"
    fi
    
    log_success "ClawSec security suite installation complete!"
    log_info "Your GooseStack installation is now protected with:"
    log_info "  • File integrity monitoring"
    log_info "  • Security vulnerability scanning"
    log_info "  • Automated daily security audits"
    log_info "  • Heartbeat security checks"
    
    return 0
}

# Main security installation function
main_install_security() {
    # On reinstall, skip security suite setup (it's already installed)
    if [[ "${GOOSE_REINSTALL:-false}" == "true" ]]; then
        local soul_guardian="$HOME/.openclaw/workspace/skills/soul-guardian/scripts/soul_guardian.py"
        if [[ -f "$soul_guardian" ]]; then
            log_success "Security suite already installed, preserving baselines"
            return 0
        fi
        # If not found, fall through to install
    fi
    
    echo -e "\n${BOLD}${PURPLE}🛡️  GooseStack Security Suite${NC}\n"
    
    log_info "ClawSec provides advanced security monitoring for your AI agent:"
    log_info "  • Protects core files from tampering"
    log_info "  • Monitors for vulnerabilities and suspicious activity"
    log_info "  • Runs automated security audits"
    log_info "  • Integrates with your agent's heartbeat checks"
    echo ""
    
    # Ask user if they want to install ClawSec
    while true; do
        echo -e "${BOLD}Would you like to install ClawSec security suite? (Recommended) [Y/n]${NC}"
        if [[ -e /dev/tty ]]; then
            read -r response < /dev/tty || response="Y"
        else
            response="Y"
        fi
        
        case "${response:-Y}" in
            [Yy]|[Yy][Ee][Ss]|"")
                if install_clawsec; then
                    echo -e "\n${GREEN}🛡️  Security suite installed successfully!${NC}"
                    return 0
                else
                    log_warning "Security suite installation failed — this is non-critical"
                    log_info "Your agent works fine without it. Install later with:"
                    log_info "  npx clawhub@latest install clawsec-suite"
                    log_info "  npx clawhub@latest install soul-guardian"
                    return 0
                fi
                ;;
            [Nn]|[Nn][Oo])
                log_info "Skipping ClawSec security suite installation"
                log_info "You can install it later with:"
                log_info "  npx clawhub@latest install clawsec-suite"
                log_info "  npx clawhub@latest install soul-guardian"
                echo ""
                return 0
                ;;
            *)
                log_warning "Please answer Y (yes) or n (no)"
                ;;
        esac
    done
}

# Run security installation


main_install_security
