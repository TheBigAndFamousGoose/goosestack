#!/bin/bash
# GooseStack Configuration Wizard
# Interactive setup for personalization and API keys

# Exit on any error
set -euo pipefail

# Wizard state variables
GOOSE_USER_NAME=""
GOOSE_AGENT_PERSONA=""
GOOSE_API_MODE=""  # "byok" or "proxy" or "local"
GOOSE_API_KEY=""
GOOSE_PROXY_KEY=""
GOOSE_TELEGRAM_ENABLED="false"
GOOSE_TELEGRAM_BOT_TOKEN=""

# Load internationalization strings
load_i18n() {
    if [[ "${GOOSE_LANG:-en}" == "ru" ]]; then
        I18N_WELCOME="👋 Давайте настроим вашего AI-агента!"
        I18N_WHATS_YOUR_NAME="Как вас зовут?"
        I18N_PRESS_ENTER_DEFAULT="Нажмите Enter для значения по умолчанию:"
        I18N_HELLO="Привет,"
        I18N_PERSONA_QUESTION="Какой характер должен быть у вашего агента?"
        I18N_PERSONA_1="Ассистент - Профессиональный, полезный, формальный"
        I18N_PERSONA_2="Партнёр - Дружелюбный, неформальный"
        I18N_PERSONA_3="Кодер - Технический, прямолинейный"
        I18N_PERSONA_4="Креативный - Остроумный, творческий"
        I18N_CHOOSE="Выберите 1-4 (по умолчанию: 2 - Партнёр):"
        I18N_SELECTED="Выбрано:"
        I18N_API_TITLE="🔑 Как вы хотите подключиться к AI моделям?"
        I18N_API_BYOK="Свой ключ (BYOK) - Бесплатно навсегда"
        I18N_API_BYOK_DESC="Используйте свой API ключ Anthropic/OpenAI. Полный контроль."
        I18N_API_PROXY="GooseStack API - Без настройки (предоплаченные кредиты)"
        I18N_API_PROXY_DESC="Не нужен API ключ. Купите кредиты и начните общение."
        I18N_API_LOCAL="Только локально - 100% бесплатно, 100% приватно"
        I18N_API_LOCAL_DESC="Только локальные модели Ollama. Без облака, без затрат."
        I18N_CHOOSE_API="Выберите 1-3 (по умолчанию: 1 - Свой ключ):"
        I18N_PASTE_API_KEY="Вставьте ваш API ключ Anthropic:"
        I18N_GET_KEY="Получить ключ:"
        I18N_PASTE_OR_SKIP="Вставьте ключ (или нажмите Enter чтобы пропустить):"
        I18N_KEY_SAVED="API ключ сохранён"
        I18N_KEY_SKIPPED="Ключ пропущен — можно добавить позже"
        I18N_TELEGRAM_QUESTION="Хотите подключить агента к Telegram?"
        I18N_TELEGRAM_DESC="Это позволит общаться с агентом откуда угодно через Telegram"
        I18N_TELEGRAM_ENABLE="Включить Telegram? (y/N):"
        I18N_TELEGRAM_SETUP="Для настройки Telegram:"
        I18N_PASTE_TOKEN="Вставьте токен бота:"
        I18N_SUMMARY="📋 Итого:"
        I18N_NAME="Имя:"
        I18N_PERSONA="Характер:"
        I18N_CORRECT="Всё верно? (Y/n):"
        I18N_RESTARTING="Перезапуск мастера..."
        I18N_CONFIRMED="Настройка подтверждена!"
        I18N_WIZARD_START="🧙 Запуск мастера настройки..."
        I18N_WIZARD_DONE="Мастер настройки завершён!"
    else
        I18N_WELCOME="👋 Let's personalize your AI agent!"
        I18N_WHATS_YOUR_NAME="What's your name?"
        I18N_PRESS_ENTER_DEFAULT="Press Enter for default:"
        I18N_HELLO="Hello,"
        I18N_PERSONA_QUESTION="What personality should your agent have?"
        I18N_PERSONA_1="Assistant - Professional, helpful, formal"
        I18N_PERSONA_2="Partner - Collaborative, friendly, casual"
        I18N_PERSONA_3="Coder - Technical, direct, development-focused"
        I18N_PERSONA_4="Creative - Witty, expressive, imaginative"
        I18N_CHOOSE="Choose 1-4 (default: 2 - Partner):"
        I18N_SELECTED="Selected:"
        I18N_API_TITLE="🔑 How do you want to connect to AI models?"
        I18N_API_BYOK="Bring Your Own Key (BYOK) - Free forever"
        I18N_API_BYOK_DESC="Use your own Anthropic/OpenAI API key. Full control over costs."
        I18N_API_PROXY="GooseStack API - Zero friction (prepaid credits)"
        I18N_API_PROXY_DESC="No API key needed. Buy credits, start chatting."
        I18N_API_LOCAL="Local only - 100% free, 100% private"
        I18N_API_LOCAL_DESC="Use only local Ollama models. No cloud, no costs."
        I18N_CHOOSE_API="Choose 1-3 (default: 1 - BYOK):"
        I18N_PASTE_API_KEY="Paste your Anthropic API key:"
        I18N_GET_KEY="Get one at:"
        I18N_PASTE_OR_SKIP="Paste your API key (or press Enter to skip for now):"
        I18N_KEY_SAVED="API key saved and validated"
        I18N_KEY_SKIPPED="Skipped API key — you can add it later"
        I18N_TELEGRAM_QUESTION="Want to connect your agent to Telegram?"
        I18N_TELEGRAM_DESC="This lets you chat with your agent from anywhere via Telegram"
        I18N_TELEGRAM_ENABLE="Enable Telegram? (y/N):"
        I18N_TELEGRAM_SETUP="To set up Telegram:"
        I18N_PASTE_TOKEN="Paste your Telegram bot token:"
        I18N_SUMMARY="📋 Configuration Summary:"
        I18N_NAME="Name:"
        I18N_PERSONA="Persona:"
        I18N_CORRECT="Is this correct? (Y/n):"
        I18N_RESTARTING="Restarting wizard..."
        I18N_CONFIRMED="Configuration confirmed!"
        I18N_WIZARD_START="🧙 Starting configuration wizard..."
        I18N_WIZARD_DONE="Configuration wizard complete!"
    fi
}

# Load I18N strings with detected language
load_i18n

# Check if we have a TTY for interactive input
HAS_TTY="false"
if [[ -t 0 ]]; then
    HAS_TTY="true"
elif [[ -e /dev/tty ]]; then
    HAS_TTY="true"
fi

# Read from TTY even when stdin is a pipe
wizard_read() {
    local varname="$1"
    local default="${2:-}"
    if [[ "$HAS_TTY" == "true" && -e /dev/tty ]]; then
        read -r "$varname" < /dev/tty || eval "$varname='$default'"
    else
        eval "$varname='$default'"
    fi
}

wizard_read_secret() {
    local varname="$1"
    local default="${2:-}"
    if [[ "$HAS_TTY" == "true" && -e /dev/tty ]]; then
        read -r -s "$varname" < /dev/tty || eval "$varname='$default'"
        echo ""
        # Show masked feedback so user knows something was entered
        local val="${!varname}"
        if [[ -n "$val" ]]; then
            local len=${#val}
            echo -e "  ${GREEN}✓ Received ${len} characters${NC}"
        fi
    else
        eval "$varname='$default'"
    fi
}

# Prompt for language selection (bilingual)
prompt_language() {
    # Determine default choice based on detected language
    local default_choice
    if [[ "${GOOSE_LANG:-en}" == "ru" ]]; then
        default_choice="2"
    else
        default_choice="1"
    fi
    
    echo -e "\n${BOLD}${PURPLE}🌐 Choose your language / Выберите язык:${NC}"
    echo -e "  ${BOLD}1)${NC} ${GREEN}English${NC}"
    echo -e "  ${BOLD}2)${NC} ${BLUE}Русский${NC}"
    echo -e ""
    echo -e "${YELLOW}Choose 1-2 (default: $default_choice):${NC}"
    echo -n "> "
    
    local lang_choice
    wizard_read lang_choice "$default_choice"
    
    case "${lang_choice:-$default_choice}" in
        1)
            export GOOSE_LANG="en"
            log_info "Language set to English"
            ;;
        2)
            export GOOSE_LANG="ru"
            log_info "Язык установлен: Русский"
            ;;
        *)
            export GOOSE_LANG="en"
            log_info "Language set to English (default)"
            ;;
    esac
    
    # Reload I18N strings with the selected language
    load_i18n
}

# Prompt for user's name
prompt_user_name() {
    local default_name
    default_name=$(whoami)
    
    echo -e "\n${BOLD}${PURPLE}${I18N_WELCOME}${NC}\n"
    
    echo -e "${CYAN}${I18N_WHATS_YOUR_NAME}${NC}"
    echo -e "${YELLOW}${I18N_PRESS_ENTER_DEFAULT} $default_name${NC}"
    echo -n "> "
    
    local user_input
    wizard_read user_input "$default_name"
    
    if [[ -n "$user_input" ]]; then
        GOOSE_USER_NAME="$user_input"
    else
        GOOSE_USER_NAME="$default_name"
    fi
    
    log_success "${I18N_HELLO} $GOOSE_USER_NAME!"
}

# Prompt for agent persona
prompt_agent_persona() {
    echo -e "\n${CYAN}${I18N_PERSONA_QUESTION}${NC}"
    echo -e "  ${BOLD}1)${NC} ${GREEN}${I18N_PERSONA_1}${NC}"
    echo -e "  ${BOLD}2)${NC} ${BLUE}${I18N_PERSONA_2}${NC}"
    echo -e "  ${BOLD}3)${NC} ${PURPLE}${I18N_PERSONA_3}${NC}"
    echo -e "  ${BOLD}4)${NC} ${YELLOW}${I18N_PERSONA_4}${NC}"
    echo -e ""
    echo -e "${YELLOW}${I18N_CHOOSE}${NC}"
    echo -n "> "
    
    local persona_choice
    wizard_read persona_choice "2"
    
    case "${persona_choice:-2}" in
        1)
            GOOSE_AGENT_PERSONA="assistant"
            log_info "${I18N_SELECTED} ${I18N_PERSONA_1}"
            ;;
        2)
            GOOSE_AGENT_PERSONA="partner"
            log_info "${I18N_SELECTED} ${I18N_PERSONA_2}"
            ;;
        3)
            GOOSE_AGENT_PERSONA="coder"
            log_info "${I18N_SELECTED} ${I18N_PERSONA_3}"
            ;;
        4)
            GOOSE_AGENT_PERSONA="creative"
            log_info "${I18N_SELECTED} ${I18N_PERSONA_4}"
            ;;
        *)
            GOOSE_AGENT_PERSONA="partner"
            log_info "${I18N_SELECTED} ${I18N_PERSONA_2} (default)"
            ;;
    esac
}

# Prompt for API setup mode
prompt_api_setup() {
    echo -e "\n${BOLD}${PURPLE}${I18N_API_TITLE}${NC}\n"
    echo -e "  ${BOLD}1)${NC} ${GREEN}${I18N_API_BYOK}${NC}"
    echo -e "     ${I18N_API_BYOK_DESC}"
    echo -e ""
    echo -e "  ${BOLD}2)${NC} ${BLUE}${I18N_API_PROXY}${NC}"
    echo -e "     ${I18N_API_PROXY_DESC}"
    echo -e ""
    echo -e "  ${BOLD}3)${NC} ${YELLOW}${I18N_API_LOCAL}${NC}"
    echo -e "     ${I18N_API_LOCAL_DESC}"
    echo -e ""
    echo -e "${YELLOW}${I18N_CHOOSE_API}${NC}"
    echo -n "> "
    
    local api_choice
    wizard_read api_choice "1"

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
    echo -e "\n${CYAN}${I18N_PASTE_API_KEY}${NC}"
    echo -e "${I18N_GET_KEY} ${BLUE}https://console.anthropic.com/${NC}"
    echo -e ""
    echo -e "${YELLOW}${I18N_PASTE_OR_SKIP}${NC}"
    echo -n "> "
    
    local api_key_input
    wizard_read_secret api_key_input ""

    if [[ -n "$api_key_input" ]]; then
        # Detect double-paste: if key contains "sk-ant-" twice, extract just the first valid key
        local key_count
        key_count=$(echo "$api_key_input" | grep -o 'sk-ant-' | wc -l | tr -d ' ')
        if [[ "$key_count" -gt 1 ]]; then
            log_warning "Detected multiple keys pasted (you may have pasted twice)"
            # Extract first valid key: sk-ant- followed by allowed chars
            api_key_input=$(echo "$api_key_input" | grep -o 'sk-ant-[a-zA-Z0-9_-]*' | head -1)
            log_info "Extracted key: ${api_key_input:0:12}..."
        fi
        
        if [[ "$api_key_input" =~ ^sk-ant-[a-zA-Z0-9_-]+$ ]]; then
            GOOSE_API_KEY="$api_key_input"
            log_success "${I18N_KEY_SAVED}"
            echo -e "  ${CYAN}Key: ${api_key_input:0:12}...${api_key_input: -4}${NC}"
        else
            log_warning "API key format doesn't look standard, but saving anyway"
            GOOSE_API_KEY="$api_key_input"
        fi
    else
        log_info "${I18N_KEY_SKIPPED}"
        echo -e "${YELLOW}Without an API key, your agent will use local models only until configured.${NC}"
    fi
}

# Prompt for GooseStack Proxy key
prompt_proxy_key() {
    echo -e "\n${CYAN}GooseStack API Setup${NC}"
    echo -e ""
    echo -e "To use the GooseStack API, you need prepaid credits."
    echo -e "Buy credits at: ${BLUE}https://goosestack.com/credits${NC}"
    echo -e ""
    echo -e "${YELLOW}Paste your GooseStack API key (or press Enter to set up later):${NC}"
    echo -n "> "
    
    local proxy_key_input
    wizard_read_secret proxy_key_input ""

    if [[ -n "$proxy_key_input" ]]; then
        # Detect double-paste for gsk_ keys
        local gsk_count
        gsk_count=$(echo "$proxy_key_input" | grep -o 'gsk_' | wc -l | tr -d ' ')
        if [[ "$gsk_count" -gt 1 ]]; then
            log_warning "Detected multiple keys pasted (you may have pasted twice)"
            proxy_key_input=$(echo "$proxy_key_input" | grep -o 'gsk_[a-zA-Z0-9_-]*' | head -1)
            log_info "Extracted key: ${proxy_key_input:0:12}..."
        fi
        GOOSE_PROXY_KEY="$proxy_key_input"
        log_success "GooseStack API key saved"
        echo -e "  ${CYAN}Key: ${proxy_key_input:0:12}...${NC}"
    else
        log_info "No key yet — your agent will use local models until you add credits"
        echo -e "${YELLOW}Visit https://goosestack.com/credits to buy credits and get your key.${NC}"
    fi
}

# Prompt for Telegram integration
prompt_telegram() {
    echo -e "\n${CYAN}${I18N_TELEGRAM_QUESTION}${NC}"
    echo -e "${YELLOW}${I18N_TELEGRAM_DESC}${NC}"
    echo -e ""
    echo -e "${YELLOW}${I18N_TELEGRAM_ENABLE}${NC}"
    echo -n "> "
    
    local telegram_choice
    wizard_read telegram_choice "n"
    
    if [[ "$telegram_choice" =~ ^[Yy]$ ]]; then
        GOOSE_TELEGRAM_ENABLED="true"
        
        echo -e "\n${CYAN}${I18N_TELEGRAM_SETUP}${NC}"
        echo -e "1. Message @BotFather on Telegram"
        echo -e "2. Send: /newbot"
        echo -e "3. Choose a name and username for your bot"
        echo -e "4. Copy the bot token from BotFather"
        echo -e ""
        echo -e "${YELLOW}${I18N_PASTE_TOKEN}${NC}"
        echo -n "> "
        
        local telegram_token
        wizard_read telegram_token ""
        
        if [[ -n "$telegram_token" ]]; then
            # Detect double-paste for telegram tokens (format: 123456:ABC-DEF)
            local tg_count
            tg_count=$(echo "$telegram_token" | grep -o '[0-9]\+:[a-zA-Z0-9_-]\+' | wc -l | tr -d ' ')
            if [[ "$tg_count" -gt 1 ]]; then
                log_warning "Detected multiple tokens pasted (you may have pasted twice)"
                telegram_token=$(echo "$telegram_token" | grep -o '[0-9]\+:[a-zA-Z0-9_-]\+' | head -1)
                log_info "Extracted token: ${telegram_token:0:10}..."
            fi
            
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
    echo -e "\n${BOLD}${BLUE}${I18N_SUMMARY}${NC}"
    echo -e "  👤 ${I18N_NAME} $GOOSE_USER_NAME"
    echo -e "  🎭 ${I18N_PERSONA} $GOOSE_AGENT_PERSONA"
    
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
    
    echo -e "\n${YELLOW}${I18N_CORRECT}${NC}"
    echo -n "> "
    
    local confirm
    wizard_read confirm "y"
    
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        log_info "${I18N_RESTARTING}"
        main_wizard
        return
    fi
    
    log_success "${I18N_CONFIRMED}"
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
    # On reinstall, offer to skip wizard
    if [[ "${GOOSE_REINSTALL:-false}" == "true" ]]; then
        echo -e "\n${BOLD}${PURPLE}🔄 Existing configuration detected${NC}"
        echo -e "${CYAN}Your previous settings (persona, API key, Telegram) are still in place.${NC}"
        echo -e ""
        echo -e "${YELLOW}Do you want to reconfigure? (y/N):${NC}"
        echo -n "> "
        
        local reconfig
        wizard_read reconfig "n"
        
        if [[ ! "$reconfig" =~ ^[Yy]$ ]]; then
            log_success "Keeping existing configuration"
            
            # Export defaults so later scripts don't fail on missing vars
            export GOOSE_USER_NAME="${GOOSE_USER_NAME:-$(whoami)}"
            export GOOSE_AGENT_PERSONA="${GOOSE_AGENT_PERSONA:-partner}"
            export GOOSE_API_MODE="${GOOSE_API_MODE:-byok}"
            export GOOSE_API_KEY="${GOOSE_API_KEY:-}"
            export GOOSE_PROXY_KEY="${GOOSE_PROXY_KEY:-}"
            export GOOSE_TELEGRAM_ENABLED="${GOOSE_TELEGRAM_ENABLED:-false}"
            export GOOSE_TELEGRAM_BOT_TOKEN="${GOOSE_TELEGRAM_BOT_TOKEN:-}"
            
            log_success "${I18N_WIZARD_DONE}"
            return
        fi
        
        log_info "Starting reconfiguration..."
    fi
    
    log_info "${I18N_WIZARD_START}"
    
    prompt_language
    prompt_user_name
    prompt_agent_persona
    prompt_api_setup
    prompt_telegram
    show_summary
    export_wizard_vars
    
    log_success "${I18N_WIZARD_DONE}"
}

# Run wizard
main_wizard
