#!/bin/bash
set -euo pipefail

# GooseStack Installer v0.1
# One-command setup for OpenClaw AI agent environment

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Globals
INSTALL_DIR=""
TEMP_DIR=""
GOOSE_REPO="https://github.com/TheBigAndFamousGoose/goosestack"

# Cleanup function
cleanup() {
    local exit_code=$?
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR"
    fi
    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}❌ Installation failed! Check the error above.${NC}" >&2
    fi
    exit $exit_code
}

# Set up error handling
trap cleanup EXIT

# Logging functions
log_info() {
    echo -e "${CYAN}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}" >&2
}

log_step() {
    echo -e "\n${BOLD}${PURPLE}🚀 $1${NC}"
}

# ASCII Art Banner
show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
     ____                      ____  _             _    
    / ___| ___   ___  ___  ___/ ___|| |_ __ _  ___| | __
   | |  _ / _ \ / _ \/ __|/ _ \___ \| __/ _` |/ __| |/ /
   | |_| | (_) | (_) \__ \  __/___) | || (_| | (__|   < 
    \____|\___/ \___/|___/\___|____/ \__\__,_|\___|_|\_\
                                                        
    🦆 One-Command AI Agent Setup for macOS
    
EOF
    echo -e "${NC}"
}

# Check if running via pipe (curl | sh)
is_piped() {
    [[ ! -t 0 ]]
}

# Download source files
download_installer() {
    log_step "Downloading GooseStack installer..."
    
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 "$GOOSE_REPO" goosestack
    else
        log_info "Git not found, downloading archive..."
        mkdir -p goosestack
        curl -fsSL "$GOOSE_REPO/archive/main.tar.gz" | tar -xz --strip-components=1 -C goosestack
    fi
    
    INSTALL_DIR="$TEMP_DIR/goosestack"
    
    if [[ ! -d "$INSTALL_DIR/src" ]]; then
        log_error "Downloaded installer is missing required files"
        exit 1
    fi
    
    log_success "Downloaded GooseStack installer"
}

# Main installation flow
main() {
    show_banner
    
    log_info "Welcome to GooseStack! Setting up your AI agent environment..."
    log_info "This will install: Homebrew, Node.js, OpenClaw, and Ollama"
    log_info ""
    
    # Detect existing installation
    export GOOSE_REINSTALL="false"
    if [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
        GOOSE_REINSTALL="true"
        log_info "🔄 Existing GooseStack installation detected!"
        log_info "Your configuration and workspace files will be preserved."
        echo ""
    fi
    
    # If piped, download first
    if is_piped; then
        download_installer
        cd "$INSTALL_DIR"
    else
        # Running directly from repo
        INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        log_info "Running from local repository: $INSTALL_DIR"
    fi
    
    # Make scripts executable
    chmod +x src/*.sh
    
    # Source all installation scripts in order
    log_step "Phase 1: System Detection & Validation"
    # shellcheck source=src/detect.sh
    source "$INSTALL_DIR/src/detect.sh"
    
    log_step "Phase 2: Installing Dependencies"
    # shellcheck source=src/install-deps.sh
    source "$INSTALL_DIR/src/install-deps.sh"
    
    log_step "Phase 3: Installing OpenClaw"
    # shellcheck source=src/install-openclaw.sh
    source "$INSTALL_DIR/src/install-openclaw.sh"
    
    log_step "Phase 4: Security Suite (Optional)"
    # shellcheck source=src/install-security.sh
    source "$INSTALL_DIR/src/install-security.sh"
    
    log_step "Phase 5: Configuration Wizard"
    # shellcheck source=src/wizard.sh
    source "$INSTALL_DIR/src/wizard.sh"
    
    log_step "Phase 6: System Optimization"
    # shellcheck source=src/optimize.sh
    source "$INSTALL_DIR/src/optimize.sh"
    
    log_step "Phase 7: Auto-Start Setup"
    # shellcheck source=src/launchagent.sh
    source "$INSTALL_DIR/src/launchagent.sh"
    
    # Run openclaw doctor to auto-fix any remaining issues
    log_info "Running openclaw doctor..."
    if command -v openclaw >/dev/null 2>&1; then
        echo "y" | openclaw doctor 2>/dev/null || {
            log_warning "openclaw doctor had issues, but continuing installation"
            true
        }
    fi
    
    # Gateway start moved to Phase 8 (config now exists)
    log_step "Phase 8: Health Check & Verification"
    # shellcheck source=src/healthcheck.sh
    source "$INSTALL_DIR/src/healthcheck.sh"
    
    echo -e "\n${BOLD}${GREEN}🎉 GooseStack installation complete!${NC}\n"
    
    log_info "Your AI agent is running and ready to help."
    log_info "Check the dashboard URL above to start chatting!"
    
    echo -e "\n${CYAN}Need help? Visit: https://github.com/TheBigAndFamousGoose/goosestack${NC}"
}

# Run main function
main "$@"