#!/bin/bash
# GooseStack OpenClaw Installation
# Installs OpenClaw globally and sets up directories

set -euo pipefail

# Install OpenClaw via npm
install_openclaw_npm() {
    log_info "📦 Installing OpenClaw..."

    if command -v openclaw >/dev/null 2>&1; then
        local current_version
        current_version=$(openclaw --version 2>/dev/null || echo "unknown")
        log_info "OpenClaw already installed: $current_version"
        
        # Verify the install is healthy (node_modules intact)
        if openclaw --help >/dev/null 2>&1; then
            log_success "OpenClaw installation is healthy"
            log_info "Checking for updates..."
            npm update -g openclaw 2>/dev/null || {
                log_warning "Update check failed (continuing)"
                true
            }
        else
            log_warning "OpenClaw install appears broken (--help failed) — reinstalling..."
            log_info "This usually means incomplete node_modules (missing @mariozechner/jiti, undici, etc)"
            npm install -g openclaw --force || {
                log_error "Failed to reinstall OpenClaw"
                exit 1
            }
            
            # Verify the fix worked
            if openclaw --help >/dev/null 2>&1; then
                log_success "OpenClaw reinstallation successful"
            else
                log_error "OpenClaw still not working after reinstall"
                exit 1
            fi
        fi
    else
        log_info "Installing OpenClaw globally via npm..."
        npm install -g openclaw

        if ! command -v openclaw >/dev/null 2>&1; then
            log_error "OpenClaw installation failed"
            exit 1
        fi
    fi

    local version
    version=$(openclaw --version 2>/dev/null || echo "installed")
    log_success "OpenClaw installed: $version"
}

# Generate gateway token
generate_gateway_token() {
    if command -v openssl >/dev/null 2>&1; then
        GOOSE_GATEWAY_TOKEN=$(openssl rand -hex 24)
    else
        GOOSE_GATEWAY_TOKEN=$(head -c 24 /dev/urandom | xxd -p)
    fi
    export GOOSE_GATEWAY_TOKEN
    log_info "Generated secure gateway token"
}

# Create workspace + config directories
setup_directories() {
    log_info "🗂️  Setting up directories..."

    local workspace_dir="$HOME/.openclaw/workspace"
    local config_dir="$HOME/.openclaw"

    mkdir -p "$workspace_dir/memory"
    mkdir -p "$config_dir/logs"
    mkdir -p "$config_dir/agents/main/agent"

    # Export for other scripts to use
    export GOOSE_WORKSPACE_DIR="$workspace_dir"
    log_success "Directories ready"
}

# Main installation function
main_install_openclaw() {
    log_info "🔧 Installing and configuring OpenClaw..."

    install_openclaw_npm
    generate_gateway_token
    setup_directories

    log_success "OpenClaw installation complete!"

    echo -e "\n${BOLD}${BLUE}🎯 OpenClaw Setup:${NC}"
    echo -e "  ✅ OpenClaw binary installed"
    echo -e "  ✅ Workspace: $GOOSE_WORKSPACE_DIR"
    echo -e "  ✅ Gateway token generated"
    echo -e "  ✅ Config will be generated in optimization step"
}

main_install_openclaw
