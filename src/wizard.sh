#!/bin/bash
# GooseStack Configuration Wizard
# Interactive setup for personalization and API keys

# Exit on any error
set -euo pipefail

# Wizard state variables
GOOSE_USER_NAME=""
GOOSE_AGENT_PERSONA=""
GOOSE_API_KEY=""
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

# Prompt for API key
prompt_api_key() {
    echo -e "\n${CYAN}Do you have an Anthropic API key for Claude?${NC}"
    echo -e "${YELLOW}This enables the most capable AI models (highly recommended)${NC}"
    echo -e ""
    echo -e "Get one at: ${BLUE}https://console.anthropic.com/${NC}"
    echo -e ""
    echo -e "${YELLOW}Paste your API key (or press Enter to skip):${NC}"
    echo -n "> "
    read -r -s api_key_input
    echo ""  # New line after hidden input
    
    if [[ -n "$api_key_input" ]]; then
        # Basic validation
        if [[ "$api_key_input" =~ ^sk-ant-[a-zA-Z0-9_-]+$ ]]; then
            GOOSE_API_KEY="$api_key_input"
            log_success "API key saved and validated"
        else
            log_warning "API key format doesn't look correct, but saving anyway"
            GOOSE_API_KEY="$api_key_input"
        fi
    else
        log_info "Skipped API key - you can add it later in the config"
        echo -e "${YELLOW}Note: Without an API key, your agent will use local models only${NC}"
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
    
    if [[ -n "$GOOSE_API_KEY" ]]; then
        echo -e "  🔑 API Key: ✅ Configured"
    else
        echo -e "  🔑 API Key: ❌ Not configured (local models only)"
    fi
    
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
    export GOOSE_API_KEY
    export GOOSE_TELEGRAM_ENABLED
    export GOOSE_TELEGRAM_BOT_TOKEN
    
    log_info "Configuration variables exported for template processing"
}

# Main wizard function
main_wizard() {
    log_info "🧙‍♂️ Starting configuration wizard..."
    
    prompt_user_name
    prompt_agent_persona
    prompt_api_key
    prompt_telegram
    show_summary
    export_wizard_vars
    
    log_success "Configuration wizard complete!"
}

# Run wizard
main_wizard