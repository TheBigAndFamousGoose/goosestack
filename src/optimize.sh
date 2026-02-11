#!/bin/bash
# GooseStack System Optimization
# Generates proper OpenClaw config and applies hardware-specific optimizations

set -euo pipefail

# Generate OpenClaw configuration (proper schema)
generate_openclaw_config() {
    log_info "🎨 Generating OpenClaw configuration..."

    local config_dir="$HOME/.openclaw"
    local config_file="$config_dir/openclaw.json"
    local gateway_token
    gateway_token=$(openssl rand -hex 24)

    # Build auth profile block based on API mode
    local auth_block=""
    local api_mode="${GOOSE_API_MODE:-byok}"
    
    if [[ "$api_mode" == "proxy" && -n "${GOOSE_PROXY_KEY:-}" ]]; then
        # GooseStack Proxy API — routes through our proxy with prepaid credits
        auth_block=$(cat <<AUTHEOF
    "profiles": {
      "goosestack:default": {
        "provider": "openai-compatible",
        "mode": "api_key",
        "baseUrl": "https://api.goosestack.com/v1"
      }
    }
AUTHEOF
)
    elif [[ -n "${GOOSE_API_KEY:-}" ]]; then
        auth_block=$(cat <<AUTHEOF
    "profiles": {
      "anthropic:default": {
        "provider": "anthropic",
        "mode": "api_key"
      }
    }
AUTHEOF
)
    fi

    # Build telegram channel block
    local telegram_channel=""
    local telegram_plugin=""
    if [[ "${GOOSE_TELEGRAM_ENABLED:-false}" == "true" && -n "${GOOSE_TELEGRAM_BOT_TOKEN:-}" ]]; then
        telegram_channel=$(cat <<TELEOF
    "telegram": {
      "enabled": true,
      "dmPolicy": "pairing",
      "botToken": "${GOOSE_TELEGRAM_BOT_TOKEN}",
      "groupPolicy": "allowlist",
      "streamMode": "partial"
    }
TELEOF
)
        telegram_plugin='"telegram": { "enabled": true }'
    fi

    # Determine subagent concurrency based on RAM
    local max_concurrent=4
    local subagent_concurrent=8
    if [[ ${GOOSE_RAM_GB:-8} -ge 32 ]]; then
        max_concurrent=6
        subagent_concurrent=12
    elif [[ ${GOOSE_RAM_GB:-8} -le 8 ]]; then
        max_concurrent=2
        subagent_concurrent=4
    fi

    # Build the config
    cat > "$config_file" <<CONFIGEOF
{
  "auth": {
    ${auth_block}
  },
  "agents": {
    "defaults": {
      "workspace": "${config_dir}/workspace",
      "memorySearch": {
        "provider": "local",
        "fallback": "none"
      },
      "compaction": {
        "mode": "safeguard"
      },
      "thinkingDefault": "low",
      "elevatedDefault": "on",
      "timeoutSeconds": 600,
      "maxConcurrent": ${max_concurrent},
      "subagents": {
        "maxConcurrent": ${subagent_concurrent},
        "model": "ollama/${GOOSE_OLLAMA_MODEL:-qwen3:14b}",
        "thinking": "off"
      }
    }
  },
  "tools": {
    "web": {
      "search": {
        "provider": "brave"
      }
    }
  },
  "commands": {
    "native": "auto",
    "nativeSkills": "auto"
  },
  "channels": {
    ${telegram_channel}
  },
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback",
    "auth": {
      "mode": "token",
      "token": "${gateway_token}"
    }
  },
  "plugins": {
    "entries": {
      ${telegram_plugin}
    }
  }
}
CONFIGEOF

    # Store API key in auth-profiles.json
    local agent_dir="$config_dir/agents/main/agent"
    mkdir -p "$agent_dir"
    
    if [[ "$api_mode" == "proxy" && -n "${GOOSE_PROXY_KEY:-}" ]]; then
        cat > "$agent_dir/auth-profiles.json" <<AUTHFILEEOF
{
  "version": 1,
  "profiles": {
    "goosestack:default": {
      "type": "api_key",
      "provider": "openai-compatible",
      "key": "${GOOSE_PROXY_KEY}",
      "baseUrl": "https://api.goosestack.com/v1"
    }
  },
  "lastGood": {
    "openai-compatible": "goosestack:default"
  }
}
AUTHFILEEOF
        chmod 600 "$agent_dir/auth-profiles.json"
        log_success "GooseStack Proxy API key stored securely"
    elif [[ -n "${GOOSE_API_KEY:-}" ]]; then
        cat > "$agent_dir/auth-profiles.json" <<AUTHFILEEOF
{
  "version": 1,
  "profiles": {
    "anthropic:default": {
      "type": "api_key",
      "provider": "anthropic",
      "key": "${GOOSE_API_KEY}"
    }
  },
  "lastGood": {
    "anthropic": "anthropic:default"
  }
}
AUTHFILEEOF
        chmod 600 "$agent_dir/auth-profiles.json"
        log_success "API key stored securely"
    fi

    # Validate JSON
    if python3 -m json.tool "$config_file" > /dev/null 2>&1; then
        log_success "OpenClaw configuration generated"
    else
        log_error "Generated config has invalid JSON — please report this bug"
        exit 1
    fi

    # Save gateway token for healthcheck
    export GOOSE_GATEWAY_TOKEN="$gateway_token"
    echo "$gateway_token" > "$config_dir/.gateway-token"
    chmod 600 "$config_dir/.gateway-token"
}

# Set up workspace files from templates
setup_workspace() {
    log_info "📁 Setting up workspace files..."

    local template_dir="$INSTALL_DIR/src/templates"
    local workspace_dir="${GOOSE_WORKSPACE_DIR:-$HOME/.openclaw/workspace}"

    mkdir -p "$workspace_dir/memory"

    # AGENTS.md — always overwrite with our version
    cp "$template_dir/AGENTS.md" "$workspace_dir/AGENTS.md"

    # SOUL.md — from selected persona
    local persona="${GOOSE_AGENT_PERSONA:-assistant}"
    local soul_file="$template_dir/SOUL-${persona}.md"
    if [[ -f "$soul_file" ]]; then
        cp "$soul_file" "$workspace_dir/SOUL.md"
        log_success "Persona: $persona"
    else
        cp "$template_dir/SOUL-assistant.md" "$workspace_dir/SOUL.md"
        log_warning "Persona '$persona' not found, using assistant"
    fi

    # USER.md — substitute name
    local user_name="${GOOSE_USER_NAME:-$(whoami)}"
    sed "s/{{USER_NAME}}/${user_name}/g" "$template_dir/USER.md.tmpl" > "$workspace_dir/USER.md"
    log_success "User: $user_name"

    # TOOLS.md, MEMORY.md — process templates with sed, only create if missing
    if [[ ! -f "$workspace_dir/TOOLS.md" && -f "$template_dir/TOOLS.md" ]]; then
        sed -e "s|{{GOOSE_CHIP:-Unknown}}|${GOOSE_CHIP:-Unknown}|g" \
            -e "s|{{GOOSE_RAM_GB:-8}}|${GOOSE_RAM_GB:-8}|g" \
            -e "s|{{GOOSE_ARCH:-arm64}}|${GOOSE_ARCH:-arm64}|g" \
            -e "s|{{GOOSE_MACOS_VER:-Unknown}}|${GOOSE_MACOS_VER:-Unknown}|g" \
            -e "s|{{GOOSE_OLLAMA_MODEL:-qwen2.5:7b}}|${GOOSE_OLLAMA_MODEL:-qwen3:14b}|g" \
            "$template_dir/TOOLS.md" > "$workspace_dir/TOOLS.md"
    fi

    if [[ ! -f "$workspace_dir/MEMORY.md" && -f "$template_dir/MEMORY.md" ]]; then
        sed -e "s|{{GOOSE_AGENT_PERSONA:-partner}}|${GOOSE_AGENT_PERSONA:-partner}|g" \
            -e "s|{{GOOSE_OLLAMA_MODEL:-qwen2.5:7b}}|${GOOSE_OLLAMA_MODEL:-qwen3:14b}|g" \
            -e "s|{{GOOSE_RAM_GB:-8}}|${GOOSE_RAM_GB:-8}|g" \
            "$template_dir/MEMORY.md" > "$workspace_dir/MEMORY.md"
    fi

    # HEARTBEAT.md — copy only if missing
    if [[ ! -f "$workspace_dir/HEARTBEAT.md" && -f "$template_dir/HEARTBEAT.md" ]]; then
        cp "$template_dir/HEARTBEAT.md" "$workspace_dir/HEARTBEAT.md"
    fi

    log_success "Workspace ready at $workspace_dir"
}

# Copy dashboard files and setup convenience access
setup_dashboard() {
    log_info "📊 Setting up dashboard files..."
    
    local dashboard_src="$INSTALL_DIR/dashboard"
    local dashboard_dest="$HOME/.openclaw/dashboard"
    
    # Copy dashboard files
    mkdir -p "$dashboard_dest"
    cp -r "$dashboard_src/"* "$dashboard_dest/"
    chmod +x "$dashboard_dest/server.sh"
    
    log_success "Dashboard files copied to ~/.openclaw/dashboard/"
    
    # Create convenience alias script
    local alias_script="$HOME/.openclaw/dashboard-start.sh"
    cat > "$alias_script" << 'ALIASEOF'
#!/bin/bash
# GooseStack Dashboard Quick Start
cd "$HOME/.openclaw/dashboard" && ./server.sh
ALIASEOF
    chmod +x "$alias_script"
    
    log_success "Dashboard quick-start script created"
}

# Main optimization function
main_optimize() {
    log_info "🚀 Optimizing system configuration..."

    generate_openclaw_config
    setup_workspace
    setup_dashboard

    echo ""
    log_success "System optimization complete!"
    echo -e "  ${GREEN}✅${NC} OpenClaw config generated (optimized for ${GOOSE_RAM_GB:-?}GB RAM)"
    echo -e "  ${GREEN}✅${NC} Local embeddings configured (\$0 cost)"
    echo -e "  ${GREEN}✅${NC} Subagents: ollama/${GOOSE_OLLAMA_MODEL:-qwen3:14b} (local, \$0)"
    echo -e "  ${GREEN}✅${NC} Thinking mode: low (best quality/cost ratio)"
    echo -e "  ${GREEN}✅${NC} Workspace files ready"
    echo -e "  ${GREEN}✅${NC} Dashboard ready at ~/.openclaw/dashboard/"
}

main_optimize
