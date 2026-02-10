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

    # Build auth profile block
    local auth_block=""
    if [[ -n "${GOOSE_API_KEY:-}" ]]; then
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

    # Store the API key in auth-profiles.json if provided
    if [[ -n "${GOOSE_API_KEY:-}" ]]; then
        local agent_dir="$config_dir/agents/main/agent"
        mkdir -p "$agent_dir"
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

    # TOOLS.md, MEMORY.md, HEARTBEAT.md — only create if missing
    for file in TOOLS.md MEMORY.md HEARTBEAT.md; do
        if [[ ! -f "$workspace_dir/$file" && -f "$template_dir/$file" ]]; then
            cp "$template_dir/$file" "$workspace_dir/$file"
        fi
    done

    log_success "Workspace ready at $workspace_dir"
}

# Main optimization function
main_optimize() {
    log_info "🚀 Optimizing system configuration..."

    generate_openclaw_config
    setup_workspace

    echo ""
    log_success "System optimization complete!"
    echo -e "  ${GREEN}✅${NC} OpenClaw config generated (optimized for ${GOOSE_RAM_GB:-?}GB RAM)"
    echo -e "  ${GREEN}✅${NC} Local embeddings configured (\$0 cost)"
    echo -e "  ${GREEN}✅${NC} Subagents: ollama/${GOOSE_OLLAMA_MODEL:-qwen3:14b} (local, \$0)"
    echo -e "  ${GREEN}✅${NC} Thinking mode: low (best quality/cost ratio)"
    echo -e "  ${GREEN}✅${NC} Workspace files ready"
}

main_optimize
