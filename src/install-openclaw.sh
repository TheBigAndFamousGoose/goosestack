#!/bin/bash
# GooseStack OpenClaw Installation
# Installs OpenClaw globally and sets up initial configuration

# Exit on any error
set -euo pipefail

# Install OpenClaw via npm
install_openclaw_npm() {
    log_info "📦 Installing OpenClaw..."
    
    # Check if already installed
    if command -v openclaw >/dev/null 2>&1; then
        local current_version
        current_version=$(openclaw --version 2>/dev/null || echo "unknown")
        log_info "OpenClaw already installed: $current_version"
        
        # Check for updates
        log_info "Checking for OpenClaw updates..."
        npm update -g openclaw || log_warning "Update check failed (continuing)"
    else
        log_info "Installing OpenClaw globally via npm..."
        npm install -g openclaw
        
        # Verify installation
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
    # Generate a secure random token
    if command -v openssl >/dev/null 2>&1; then
        GOOSE_GATEWAY_TOKEN=$(openssl rand -hex 32)
    else
        # Fallback to using built-in tools
        GOOSE_GATEWAY_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
    fi
    
    export GOOSE_GATEWAY_TOKEN
    log_info "Generated secure gateway token"
}

# Create OpenClaw workspace directory
setup_workspace() {
    log_info "🗂️  Setting up OpenClaw workspace..."
    
    local workspace_dir="$HOME/.openclaw/workspace"
    
    if [[ -d "$workspace_dir" ]]; then
        log_info "Workspace directory already exists: $workspace_dir"
    else
        log_info "Creating workspace directory: $workspace_dir"
        mkdir -p "$workspace_dir"
        mkdir -p "$workspace_dir/memory"
    fi
    
    export GOOSE_WORKSPACE_DIR="$workspace_dir"
    log_success "Workspace directory ready"
}

# Generate base openclaw.json configuration
generate_base_config() {
    log_info "⚙️  Generating OpenClaw configuration..."
    
    local config_dir="$HOME/.openclaw"
    local config_file="$config_dir/openclaw.json"
    
    # Create config directory if it doesn't exist
    mkdir -p "$config_dir"
    
    # Generate base configuration with optimal settings
    cat > "$config_file" << EOF
{
  "gateway": {
    "host": "localhost",
    "port": 3721,
    "token": "$GOOSE_GATEWAY_TOKEN",
    "corsOrigins": ["http://localhost:3000", "https://openclaw.dev"]
  },
  "defaultModel": "anthropic/claude-3-5-sonnet-20241022",
  "timeoutSeconds": 600,
  "thinkingDefault": "low",
  "elevatedDefault": "on",
  "memorySearch": {
    "provider": "local",
    "embeddingModel": "nomic-embed-text",
    "maxResults": 10
  },
  "subagents": {
    "defaultModel": "ollama/$GOOSE_OLLAMA_MODEL",
    "maxConcurrent": 3,
    "timeoutSeconds": 300
  },
  "compaction": {
    "mode": "safeguard",
    "maxTokens": 100000,
    "keepMinTokens": 20000
  },
  "skills": [],
  "channels": {
    "webchat": {
      "enabled": true,
      "port": 3000
    }
  }
}
EOF
    
    export GOOSE_CONFIG_FILE="$config_file"
    log_success "Base configuration generated"
}

# Initialize workspace with minimal files
init_minimal_workspace() {
    log_info "📝 Initializing workspace files..."
    
    # Create basic TOOLS.md
    cat > "$GOOSE_WORKSPACE_DIR/TOOLS.md" << 'EOF'
# TOOLS.md - Local Notes

Skills define _how_ tools work. This file is for _your_ specifics — the stuff that's unique to your setup.

## What Goes Here

Things like:
- Camera names and locations
- SSH hosts and aliases  
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
- Anything environment-specific

---

*Add whatever helps you do your job. This is your cheat sheet.*
EOF

    # Create basic MEMORY.md
    cat > "$GOOSE_WORKSPACE_DIR/MEMORY.md" << 'EOF'
# MEMORY.md - Long-Term Memory

*This file is loaded only in main sessions (direct chats with your human)*

## Important Context
<!-- Personal info, preferences, ongoing projects -->

## Lessons Learned
<!-- Mistakes to avoid, what works well -->

## Key Decisions
<!-- Important choices made, reasoning behind them -->

## Notes
<!-- Anything else worth remembering long-term -->
EOF

    # Create basic HEARTBEAT.md
    cat > "$GOOSE_WORKSPACE_DIR/HEARTBEAT.md" << 'EOF'
# HEARTBEAT.md - Periodic Tasks

<!--
This file defines what to check during heartbeat polls.
Keep it short to minimize token usage.
-->

## Current Tasks
<!-- Nothing scheduled yet -->

## Reminders
<!-- Add items here that you want to check periodically -->

---

*When nothing needs attention, respond with: HEARTBEAT_OK*
EOF

    log_success "Workspace files initialized"
}

# Main installation function
main_install_openclaw() {
    log_info "🔧 Installing and configuring OpenClaw..."
    
    install_openclaw_npm
    generate_gateway_token
    setup_workspace
    generate_base_config
    init_minimal_workspace
    
    log_success "OpenClaw installation complete!"
    
    # Summary
    echo -e "\n${BOLD}${BLUE}🎯 OpenClaw Setup:${NC}"
    echo -e "  ✅ OpenClaw binary installed globally"
    echo -e "  ✅ Workspace: $GOOSE_WORKSPACE_DIR"
    echo -e "  ✅ Config: $GOOSE_CONFIG_FILE"
    echo -e "  ✅ Gateway token generated"
    echo -e "  ✅ Local embeddings configured"
    echo -e "  ✅ Subagents using: $GOOSE_OLLAMA_MODEL"
}

# Run installation
main_install_openclaw