#!/bin/bash
# GooseStack System Optimization
# Generates proper OpenClaw config and applies hardware-specific optimizations

set -euo pipefail

# Generate OpenClaw configuration (proper schema)
generate_openclaw_config() {
    log_info "🎨 Generating OpenClaw configuration..."

    local config_dir="$HOME/.openclaw"
    local config_file="$config_dir/openclaw.json"
    
    # On reinstall, preserve existing config UNLESS user chose to reconfigure
    if [[ "${GOOSE_REINSTALL:-false}" == "true" && -f "$config_file" && -z "${GOOSE_API_MODE:-}" ]]; then
        log_success "Preserving existing OpenClaw configuration"
        
        # Still ensure gateway token is available for healthcheck
        if [[ -f "$config_dir/.gateway-token" ]]; then
            export GOOSE_GATEWAY_TOKEN=$(cat "$config_dir/.gateway-token")
        fi
        
        # Ensure all directories exist (in case any were deleted)
        local agent_dir="$config_dir/agents/main/agent"
        mkdir -p "$agent_dir"
        mkdir -p "$config_dir/agents/main/sessions"
        mkdir -p "$config_dir/credentials"
        mkdir -p "$config_dir/logs"
        mkdir -p "${GOOSE_WORKSPACE_DIR:-$config_dir/workspace}/memory"
        
        return
    fi
    
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
        "baseUrl": "https://goosestack.com/api/v1"
      }
    }
AUTHEOF
)
    elif [[ "$api_mode" == "proxy" && -z "${GOOSE_PROXY_KEY:-}" ]]; then
        # Proxy mode requested but no key provided - fallback to local-only with warning
        log_warning "GooseStack Proxy mode selected but no key provided - falling back to local-only mode"
        log_info "Visit https://goosestack.com/credits to get your proxy key, then update ~/.openclaw/openclaw.json"
        auth_block=$(cat <<AUTHEOF
    "profiles": {
      "local:default": {
        "provider": "ollama",
        "mode": "endpoint",
        "baseUrl": "http://localhost:11434"
      }
    }
AUTHEOF
)
        # Override the API mode so the rest of the config logic works correctly
        api_mode="local"
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
    else
        # No API key provided - create a local-only auth profile
        if [[ "$api_mode" == "byok" ]]; then
            log_warning "BYOK mode selected but no key provided - falling back to local-only mode"
        fi
        auth_block=$(cat <<AUTHEOF
    "profiles": {
      "local:default": {
        "provider": "ollama",
        "mode": "endpoint",
        "baseUrl": "http://localhost:11434"
      }
    }
AUTHEOF
)
        # Override the API mode so the rest of the config logic works correctly
        api_mode="local"
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

    # Determine default model based on API mode
    local default_model
    if [[ "$api_mode" == "local" ]]; then
        default_model="ollama/${GOOSE_OLLAMA_MODEL:-qwen3:14b}"
    elif [[ "$api_mode" == "proxy" ]]; then
        default_model="openai/gpt-4o"
    else
        default_model="anthropic/claude-sonnet-4-20250514"
    fi

    # Determine subagent model
    local subagent_model="ollama/${GOOSE_OLLAMA_MODEL:-qwen3:14b}"

    # Build the config
    cat > "$config_file" <<CONFIGEOF
{
  "auth": {
    ${auth_block}
  },
  "agents": {
    "defaults": {
      "model": { "primary": "${default_model}" },
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
    # Create all required directories upfront (prevents openclaw doctor complaints)
    local agent_dir="$config_dir/agents/main/agent"
    local workspace_dir="${config_dir}/workspace"
    mkdir -p "$agent_dir"
    mkdir -p "$config_dir/agents/main/sessions"  
    mkdir -p "$config_dir/credentials"
    mkdir -p "$config_dir/logs"
    mkdir -p "$workspace_dir/memory"
    
    # Set proper permissions (secure by default)
    chmod 700 "$config_dir"
    chmod 700 "$config_dir/agents"
    chmod 700 "$config_dir/agents/main"
    chmod 700 "$agent_dir"
    chmod 700 "$config_dir/agents/main/sessions"
    chmod 700 "$config_dir/credentials"
    chmod 700 "$config_dir/logs"
    chmod 755 "$workspace_dir"  # Workspace can be slightly more permissive
    chmod 755 "$workspace_dir/memory"
    chmod 600 "$config_file"
    
    if [[ "$api_mode" == "proxy" && -n "${GOOSE_PROXY_KEY:-}" ]]; then
        cat > "$agent_dir/auth-profiles.json" <<AUTHFILEEOF
{
  "version": 1,
  "profiles": {
    "goosestack:default": {
      "type": "api_key",
      "provider": "openai-compatible",
      "key": "${GOOSE_PROXY_KEY}",
      "baseUrl": "https://goosestack.com/api/v1"
    }
  },
  "lastGood": {
    "openai-compatible": "goosestack:default"
  }
}
AUTHFILEEOF
        chmod 600 "$agent_dir/auth-profiles.json"
        log_success "GooseStack Proxy API key stored securely"
    elif [[ "$api_mode" == "local" || -z "${GOOSE_API_KEY:-}" ]]; then
        # Local-only mode or fallback from proxy mode - create auth profile for Ollama
        cat > "$agent_dir/auth-profiles.json" <<AUTHFILEEOF
{
  "version": 1,
  "profiles": {
    "local:default": {
      "type": "endpoint",
      "provider": "ollama",
      "baseUrl": "http://localhost:11434"
    }
  },
  "lastGood": {
    "ollama": "local:default"
  }
}
AUTHFILEEOF
        chmod 600 "$agent_dir/auth-profiles.json"
        log_success "Local-only auth profile created"
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

    # Validate JSON syntax
    if python3 -m json.tool "$config_file" > /dev/null 2>&1; then
        log_success "OpenClaw configuration generated and validated"
        
        # Also validate the auth-profiles.json if it was created
        if [[ -f "$agent_dir/auth-profiles.json" ]]; then
            if python3 -m json.tool "$agent_dir/auth-profiles.json" > /dev/null 2>&1; then
                log_success "Auth profiles configuration validated"
            else
                log_error "Generated auth-profiles.json has invalid JSON"
                exit 1
            fi
        fi
    else
        log_error "Generated openclaw.json has invalid JSON — please report this bug"
        echo -e "${YELLOW}Generated config for debugging:${NC}"
        cat "$config_file" | head -20
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
    
    # Verify template directory exists
    if [[ ! -d "$template_dir" ]]; then
        log_error "Template directory not found: $template_dir"
        exit 1
    fi

    # Determine if we should overwrite persona files (user chose to reconfigure)
    local overwrite_persona="false"
    if [[ -n "${GOOSE_AGENT_PERSONA:-}" && "${GOOSE_REINSTALL:-false}" == "true" ]]; then
        overwrite_persona="true"
    fi

    # AGENTS.md — only create if missing (user may have customized)
    if [[ ! -f "$workspace_dir/AGENTS.md" ]]; then
        cp "$template_dir/AGENTS.md" "$workspace_dir/AGENTS.md"
        chmod 644 "$workspace_dir/AGENTS.md"
    else
        log_info "AGENTS.md already exists, preserving"
    fi

    # SOUL.md — overwrite if reconfiguring persona, otherwise only create if missing
    if [[ "$overwrite_persona" == "true" || ! -f "$workspace_dir/SOUL.md" ]]; then
        local persona="${GOOSE_AGENT_PERSONA:-assistant}"
        local soul_file="$template_dir/SOUL-${persona}.md"
        if [[ -f "$soul_file" ]]; then
            cp "$soul_file" "$workspace_dir/SOUL.md"
            chmod 644 "$workspace_dir/SOUL.md"
            log_success "Persona: $persona"
        else
            cp "$template_dir/SOUL-assistant.md" "$workspace_dir/SOUL.md"
            chmod 644 "$workspace_dir/SOUL.md"
            log_warning "Persona '$persona' not found, using assistant"
        fi
    else
        log_info "SOUL.md already exists, preserving"
    fi

    # USER.md — overwrite if reconfiguring, otherwise only create if missing
    if [[ "$overwrite_persona" == "true" || ! -f "$workspace_dir/USER.md" ]]; then
        local user_name="${GOOSE_USER_NAME:-$(whoami)}"
        local setup_date=$(date +"%Y-%m-%d")
        sed -e "s/{{USER_NAME}}/${user_name}/g" \
            -e "s/{{SETUP_DATE}}/${setup_date}/g" \
            -e "s/{{GOOSE_CHIP}}/${GOOSE_CHIP:-Unknown}/g" \
            -e "s/{{GOOSE_RAM_GB}}/${GOOSE_RAM_GB:-8}/g" \
            "$template_dir/USER.md.tmpl" > "$workspace_dir/USER.md"
        chmod 644 "$workspace_dir/USER.md"
        log_success "User: ${user_name}"
    else
        log_info "USER.md already exists, preserving"
    fi

    # Compute template values once for both TOOLS.md and MEMORY.md
    local setup_date=$(date +"%Y-%m-%d")
    local api_status="Local models only"
    [[ -n "${GOOSE_API_KEY:-}" ]] && api_status="Anthropic Claude configured"
    local telegram_status="Telegram integration disabled"
    [[ "${GOOSE_TELEGRAM_ENABLED:-false}" == "true" ]] && telegram_status="Telegram integration enabled"

    # TOOLS.md, MEMORY.md — process templates with sed, only create if missing
    if [[ ! -f "$workspace_dir/TOOLS.md" && -f "$template_dir/TOOLS.md" ]]; then
        sed -e "s|{{GOOSE_CHIP:-Unknown}}|${GOOSE_CHIP:-Unknown}|g" \
            -e "s|{{GOOSE_RAM_GB:-8}}|${GOOSE_RAM_GB:-8}|g" \
            -e "s|{{GOOSE_ARCH:-arm64}}|${GOOSE_ARCH:-arm64}|g" \
            -e "s|{{GOOSE_MACOS_VER:-Unknown}}|${GOOSE_MACOS_VER:-Unknown}|g" \
            -e "s|{{GOOSE_LANG}}|${GOOSE_LANG:-en}|g" \
            -e "s|{{GOOSE_OLLAMA_MODEL}}|${GOOSE_OLLAMA_MODEL:-qwen3:14b}|g" \
            -e "s|{{SETUP_DATE}}|${setup_date}|g" \
            -e "s|{{API_STATUS}}|${api_status}|g" \
            "$template_dir/TOOLS.md" > "$workspace_dir/TOOLS.md"
        chmod 644 "$workspace_dir/TOOLS.md"
    fi

    if [[ ! -f "$workspace_dir/MEMORY.md" && -f "$template_dir/MEMORY.md" ]]; then
        sed -e "s|{{GOOSE_AGENT_PERSONA:-partner}}|${GOOSE_AGENT_PERSONA:-partner}|g" \
            -e "s|{{GOOSE_OLLAMA_MODEL}}|${GOOSE_OLLAMA_MODEL:-qwen3:14b}|g" \
            -e "s|{{GOOSE_RAM_GB:-8}}|${GOOSE_RAM_GB:-8}|g" \
            -e "s|{{SETUP_DATE}}|${setup_date}|g" \
            -e "s|{{API_STATUS}}|${api_status}|g" \
            -e "s|{{TELEGRAM_STATUS}}|${telegram_status}|g" \
            "$template_dir/MEMORY.md" > "$workspace_dir/MEMORY.md"
        chmod 644 "$workspace_dir/MEMORY.md"
    fi

    # HEARTBEAT.md — copy only if missing
    if [[ ! -f "$workspace_dir/HEARTBEAT.md" && -f "$template_dir/HEARTBEAT.md" ]]; then
        cp "$template_dir/HEARTBEAT.md" "$workspace_dir/HEARTBEAT.md"
        chmod 644 "$workspace_dir/HEARTBEAT.md"
    fi

    # IDENTITY.md — agent identity (only if missing)
    if [[ ! -f "$workspace_dir/IDENTITY.md" && -f "$template_dir/IDENTITY.md" ]]; then
        cp "$template_dir/IDENTITY.md" "$workspace_dir/IDENTITY.md"
        chmod 644 "$workspace_dir/IDENTITY.md"
    fi

    # BOOTSTRAP.md — first-run onboarding flow (only if workspace is fresh)
    if [[ ! -f "$workspace_dir/BOOTSTRAP.md" && -f "$template_dir/BOOTSTRAP.md" ]]; then
        cp "$template_dir/BOOTSTRAP.md" "$workspace_dir/BOOTSTRAP.md"
        chmod 644 "$workspace_dir/BOOTSTRAP.md"
        log_success "First-run onboarding flow ready"
    fi

    log_success "Workspace ready at $workspace_dir"
}

# Copy dashboard files and setup convenience access
setup_dashboard() {
    log_info "📊 Setting up dashboard files..."
    
    local dashboard_src="$INSTALL_DIR/dashboard"
    local dashboard_dest="$HOME/.openclaw/dashboard"
    
    # Copy dashboard files if they exist
    if [[ -d "$dashboard_src" ]]; then
        mkdir -p "$dashboard_dest"
        cp -r "$dashboard_src/"* "$dashboard_dest/"
        [[ -f "$dashboard_dest/server.sh" ]] && chmod +x "$dashboard_dest/server.sh"
        log_success "Dashboard files copied to ~/.openclaw/dashboard/"
        
        # Write dashboard config with pre-loaded API key for proxy mode
        if [[ "${GOOSE_API_MODE:-}" == "proxy" && -n "${GOOSE_PROXY_KEY:-}" ]]; then
            cat > "$dashboard_dest/config.json" <<EOF
{"apiKey":"${GOOSE_PROXY_KEY}","apiBase":"https://goosestack.com/api"}
EOF
            chmod 600 "$dashboard_dest/config.json"
            log_success "Dashboard pre-configured with GooseStack API key"
        fi
    else
        log_info "Dashboard files not bundled — use web dashboard at https://goosestack.com"
    fi
    
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
    if [[ -d "$HOME/.openclaw/dashboard" ]]; then
        echo -e "  ${GREEN}✅${NC} Dashboard ready at ~/.openclaw/dashboard/"
    else
        echo -e "  ${GREEN}✅${NC} Web dashboard at https://goosestack.com"
    fi
}

main_optimize
