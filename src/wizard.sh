#!/bin/bash
# GooseStack Configuration Wizard
# Interactive setup for personalization and API keys

# Exit on any error
set -euo pipefail

# Wizard state variables
GOOSE_USER_NAME=""
GOOSE_AGENT_PERSONA=""
GOOSE_API_MODE=""  # "byok" or "proxy"
GOOSE_API_KEY=""
GOOSE_PROXY_KEY=""
GOOSE_TELEGRAM_ENABLED="false"
GOOSE_TELEGRAM_BOT_TOKEN=""

# Prompt for user's name
prompt_user_name() {
    local default_name
    default_name=$(whoami)
    
    echo -e "\n${BOLD}${PURPLE}👋 Let's personalize your AI agent!${NC}\n"
    
    echo -e "${CYAN}What's your name?${NC}"
    echo -e "${YELLOW}Press Enter for default: $default_name${NC}"
    echo -n "> "
    read -r user_input
    
    if [[ -n "$user_input" ]]; then
        GOOSE_USER_NAME="$user_input"
    else
        GOOSE_USER_NAME="$default_name"
    fi
    
    log_success "Hello, $GOOSE_USER_NAME!"
}

# Prompt for agent persona
prompt_agent_persona() {
    echo -e "\n${CYAN}What personality should your agent have?${NC}"
    echo -e "  ${BOLD}1)${NC} ${GREEN}Assistant${NC} - Professional, helpful, formal"
    echo -e "  ${BOLD}2)${NC} ${BLUE}Partner${NC} - Collaborative, friendly, casual"
    echo -e "  ${BOLD}3)${NC} ${PURPLE}Coder${NC} - Technical, direct, development-focused"
    echo -e "  ${BOLD}4)${NC} ${YELLOW}Creative${NC} - Witty, expressive, imaginative"
    echo -e ""
    echo -e "${YELLOW}Choose 1-4 (default: 2 - Partner):${NC}"
    echo -n "> "
    read -r persona_choice
    
    case "${persona_choice:-2}" in
        1)
            GOOSE_AGENT_PERSONA="assistant"
            log_info "Selected: Professional Assistant"
            ;;
        2)
            GOOSE_AGENT_PERSONA="partner"
            log_info "Selected: Collaborative Partner"
            ;;
        3)
            GOOSE_AGENT_PERSONA="coder"
            log_info "Selected: Technical Coder"
            ;;
        4)
            GOOSE_AGENT_PERSONA="creative"
            log_info "Selected: Creative Companion"
            ;;
        *)
            GOOSE_AGENT_PERSONA="partner"
            log_info "Selected: Collaborative Partner (default)"
            ;;
    esac
}

# Prompt for API setup mode
prompt_api_setup() {
    echo -e "\n${BOLD}${PURPLE}🔑 How do you want to connect to AI models?${NC}\n"
    echo -e "  ${BOLD}1)${NC} ${GREEN}Bring Your Own Key (BYOK)${NC} - Free forever"
    echo -e "     Use your own Anthropic/OpenAI API key. Full control over costs."
    echo -e ""
    echo -e "  ${BOLD}2)${NC} ${BLUE}GooseStack API${NC} - Zero friction (prepaid credits)"
    echo -e "     No API key needed. Buy credits, start chatting."
    echo -e "     40% markup on token costs. You control spending."
    echo -e ""
    echo -e "  ${BOLD}3)${NC} ${YELLOW}Local only${NC} - 100% free, 100% private"
    echo -e "     Use only local Ollama models. No cloud, no costs."
    echo -e ""
    echo -e "${YELLOW}Choose 1-3 (default: 1 - BYOK):${NC}"
    echo -n "> "
    read -r api_choice

    case "${api_choice:-1}" in
        1)
            GOOSE_API_MODE="byok"
            prompt_api_key_byok
            ;;
        2)
            GOOSE_API_MODE="proxy"
            prompt_proxy_key
            ;;
        3)
            GOOSE_API_MODE="local"
            log_info "Local only mode — using Ollama models, no cloud API"
            echo -e "${YELLOW}Note: Local models are less capable than cloud models like Claude Opus.${NC}"
            echo -e "${YELLOW}You can switch to BYOK or GooseStack API later in the config.${NC}"
            ;;
        *)
            GOOSE_API_MODE="byok"
            prompt_api_key_byok
            ;;
    esac
}

# Prompt for BYOK API key
prompt_api_key_byok() {
    echo -e "\n${CYAN}Paste your Anthropic API key:${NC}"
    echo -e "Get one at: ${BLUE}https://console.anthropic.com/${NC}"
    echo -e ""
    echo -e "${YELLOW}Paste your API key (or press Enter to skip for now):${NC}"
    echo -n "> "
    read -r -s api_key_input
    echo ""

    if [[ -n "$api_key_input" ]]; then
        if [[ "$api_key_input" =~ ^sk-ant-[a-zA-Z0-9_-]+$ ]]; then
            GOOSE_API_KEY="$api_key_input"
            log_success "API key saved and validated"
        else
            log_warning "API key format doesn't look standard, but saving anyway"
            GOOSE_API_KEY="$api_key_input"
        fi
    else
        log_info "Skipped API key — you can add it later in ~/.openclaw/openclaw.json"
        echo -e "${YELLOW}Without an API key, your agent will use local models only until configured.${NC}"
    fi
}

# Prompt for GooseStack Proxy key
prompt_proxy_key() {
    echo -e "\n${CYAN}GooseStack API Setup${NC}"
    echo -e ""
    echo -e "To use the GooseStack API, you need prepaid credits."
    echo -e "Buy credits at: ${BLUE}https://goosestack.dev/credits${NC}"
    echo -e ""
    echo -e "${YELLOW}Paste your GooseStack API key (or press Enter to set up later):${NC}"
    echo -n "> "
    read -r -s proxy_key_input
    echo ""

    if [[ -n "$proxy_key_input" ]]; then
        GOOSE_PROXY_KEY="$proxy_key_input"
        log_success "GooseStack API key saved"
    else
        log_info "No key yet — your agent will use local models until you add credits"
        echo -e "${YELLOW}Visit https://goosestack.dev/credits to buy credits and get your key.${NC}"
    fi
}

# Prompt for Telegram integration
prompt_telegram() {
    echo -e "\n${CYAN}Want to connect your agent to Telegram?${NC}"
    echo -e "${YELLOW}This lets you chat with your agent from anywhere via Telegram${NC}"
    echo -e ""
    echo -e "${YELLOW}Enable Telegram? (y/N):${NC}"
    echo -n "> "
    read -r telegram_choice
    
    if [[ "$telegram_choice" =~ ^[Yy]$ ]]; then
        GOOSE_TELEGRAM_ENABLED="true"
        
        echo -e "\n${CYAN}To set up Telegram:${NC}"
        echo -e "1. Message @BotFather on Telegram"
        echo -e "2. Send: /newbot"
        echo -e "3. Choose a name and username for your bot"
        echo -e "4. Copy the bot token from BotFather"
        echo -e ""
        echo -e "${YELLOW}Paste your Telegram bot token:${NC}"
        echo -n "> "
        read -r telegram_token
        
        if [[ -n "$telegram_token" ]]; then
            # Basic validation
            if [[ "$telegram_token" =~ ^[0-9]+:[a-zA-Z0-9_-]+$ ]]; then
                GOOSE_TELEGRAM_BOT_TOKEN="$telegram_token"
                log_success "Telegram bot token saved"
            else
                log_warning "Bot token format doesn't look correct, but saving anyway"
                GOOSE_TELEGRAM_BOT_TOKEN="$telegram_token"
            fi
        else
            log_info "No token provided, disabling Telegram"
            GOOSE_TELEGRAM_ENABLED="false"
        fi
    else
        log_info "Telegram integration disabled"
    fi
}

# Show configuration summary
show_summary() {
    echo -e "\n${BOLD}${BLUE}📋 Configuration Summary:${NC}"
    echo -e "  👤 Name: $GOOSE_USER_NAME"
    echo -e "  🎭 Persona: $GOOSE_AGENT_PERSONA"
    
    case "$GOOSE_API_MODE" in
        byok)
            if [[ -n "$GOOSE_API_KEY" ]]; then
                echo -e "  🔑 API: BYOK ✅ Key configured"
            else
                echo -e "  🔑 API: BYOK ⚠️  Key not yet provided"
            fi
            ;;
        proxy)
            if [[ -n "$GOOSE_PROXY_KEY" ]]; then
                echo -e "  🔑 API: GooseStack Proxy ✅ Key configured"
            else
                echo -e "  🔑 API: GooseStack Proxy ⚠️  Key not yet provided"
            fi
            ;;
        local)
            echo -e "  🔑 API: Local only (Ollama)"
            ;;
    esac
    
    if [[ "$GOOSE_TELEGRAM_ENABLED" == "true" ]]; then
        echo -e "  💬 Telegram: ✅ Enabled"
    else
        echo -e "  💬 Telegram: ❌ Disabled"
    fi
    
    echo -e "\n${YELLOW}Is this correct? (Y/n):${NC}"
    echo -n "> "
    read -r confirm
    
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log_info "Restarting wizard..."
        main_wizard
        return
    fi
    
    log_success "Configuration confirmed!"
}

# Export variables for template processing
export_wizard_vars() {
    export GOOSE_USER_NAME
    export GOOSE_AGENT_PERSONA
    export GOOSE_API_MODE
    export GOOSE_API_KEY
    export GOOSE_PROXY_KEY
    export GOOSE_TELEGRAM_ENABLED
    export GOOSE_TELEGRAM_BOT_TOKEN
    
    log_info "Configuration variables exported for template processing"
}

# Main wizard function
main_wizard() {
    log_info "🧙‍♂️ Starting configuration wizard..."
    
    prompt_user_name
    prompt_agent_persona
    prompt_api_setup
    prompt_telegram
    show_summary
    export_wizard_vars
    
    log_success "Configuration wizard complete!"
}

# Run wizard
main_wizard