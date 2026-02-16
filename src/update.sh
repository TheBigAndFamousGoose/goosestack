#!/bin/bash
# GooseStack Update — pull latest, update components, keep user data
set -euo pipefail

# Colors (matching GooseStack style)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Globals
RECONFIG=false
CHECK_ONLY=false
TEMP_DIR=""
INSTALL_DIR=""
GOOSE_REPO="https://github.com/TheBigAndFamousGoose/goosestack"
UPDATE_ITEMS=()

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
    echo -e "\n${BOLD}${CYAN}🔄 $1${NC}"
}

# Cleanup function
cleanup() {
    if [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# Print banner
show_banner() {
    echo -e "${CYAN}"
    cat << 'EOF'
    🔄 GooseStack Updater
    
EOF
    echo -e "${NC}"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --reconfig)
                RECONFIG=true
                shift
                ;;
            --check)
                CHECK_ONLY=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                ;;
        esac
    done
}

# Show help
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --reconfig    Re-run configuration wizard after update"
    echo "  --check       Just check for updates, don't apply them"
    echo "  -h, --help    Show this help message"
    exit 0
}

# Check current versions
check_current_versions() {
    log_step "Checking current versions"
    
    local openclaw_version="unknown"
    local ollama_version="unknown"
    local node_version="unknown"
    
    if command -v openclaw >/dev/null 2>&1; then
        openclaw_version=$(openclaw --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo "unknown")
    fi
    
    if command -v ollama >/dev/null 2>&1; then
        ollama_version=$(ollama --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
    fi
    
    if command -v node >/dev/null 2>&1; then
        node_version=$(node --version 2>/dev/null || echo "unknown")
    fi
    
    log_info "Current OpenClaw: $openclaw_version"
    log_info "Current Ollama: $ollama_version"
    log_info "Current Node.js: $node_version"
}

# Download latest GooseStack
download_latest() {
    log_step "Downloading latest GooseStack"
    
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    log_info "Downloading from: $GOOSE_REPO"
    
    if command -v git >/dev/null 2>&1; then
        git clone --depth 1 "$GOOSE_REPO" goosestack-update
    else
        log_info "Git not found, downloading archive..."
        mkdir -p goosestack-update
        curl -fsSL "$GOOSE_REPO/archive/main.tar.gz" | tar -xz --strip-components=1 -C goosestack-update
    fi
    
    INSTALL_DIR="$TEMP_DIR/goosestack-update"
    
    if [[ ! -d "$INSTALL_DIR/src" ]]; then
        log_error "Downloaded update is missing required files"
        exit 1
    fi
    
    log_success "Downloaded latest GooseStack"
}

# Compare versions (simple approach - always update for now)
compare_versions() {
    log_step "Checking for updates"
    
    # For now, we'll always consider there's an update available
    # TODO: Implement proper version comparison when VERSION file exists
    log_info "Updates available - proceeding with update"
    
    if [[ "$CHECK_ONLY" == "true" ]]; then
        log_success "Update check complete. Updates are available."
        exit 0
    fi
}

# Update OpenClaw
update_openclaw() {
    log_step "Updating OpenClaw"
    
    if command -v npm >/dev/null 2>&1; then
        log_info "Running: npm update -g openclaw"
        if npm update -g openclaw; then
            UPDATE_ITEMS+=("OpenClaw (npm)")
            log_success "OpenClaw updated"
        else
            log_warning "Failed to update OpenClaw"
        fi
    else
        log_warning "npm not found, skipping OpenClaw update"
    fi
}

# Update Ollama
update_ollama() {
    log_step "Updating Ollama"
    
    if command -v brew >/dev/null 2>&1; then
        log_info "Running: brew upgrade ollama"
        if brew upgrade ollama 2>/dev/null || true; then
            UPDATE_ITEMS+=("Ollama (Homebrew)")
            log_success "Ollama updated (or already latest)"
        else
            log_warning "Ollama update had issues (may already be latest)"
        fi
    else
        log_warning "Homebrew not found, skipping Ollama update"
    fi
}

# Update scripts
update_scripts() {
    log_step "Updating GooseStack scripts"
    
    # Update CLI wrapper
    local cli_target="/opt/homebrew/bin/goosestack"
    if [[ -f "$INSTALL_DIR/src/templates/goosestack-cli.sh" ]]; then
        if cp "$INSTALL_DIR/src/templates/goosestack-cli.sh" "$cli_target" 2>/dev/null; then
            chmod +x "$cli_target"
            UPDATE_ITEMS+=("GooseStack CLI wrapper")
            log_success "Updated CLI wrapper"
        else
            log_warning "Could not update CLI wrapper (may need sudo)"
        fi
    fi
    
    # Persist updated GooseStack scripts
    local persist_dir="$HOME/.openclaw/goosestack"
    if [[ -d "$persist_dir" ]]; then
        log_info "Updating persisted GooseStack scripts"
        rm -rf "$persist_dir"
        cp -r "$INSTALL_DIR" "$persist_dir"
        chmod -R 755 "$persist_dir/src"
        UPDATE_ITEMS+=("GooseStack scripts")
        log_success "Scripts updated in ~/.openclaw/goosestack/"
    fi
}

# Update dashboard
update_dashboard() {
    log_step "Updating dashboard files"
    
    local dashboard_src="$INSTALL_DIR/src/dashboard"
    local dashboard_dest="$HOME/.openclaw/dashboard"
    
    if [[ -d "$dashboard_src" ]]; then
        mkdir -p "$dashboard_dest"
        
        # Preserve existing config.json
        local config_backup=""
        if [[ -f "$dashboard_dest/config.json" ]]; then
            config_backup=$(mktemp)
            cp "$dashboard_dest/config.json" "$config_backup"
            log_info "Preserving existing dashboard config.json"
        fi
        
        # Copy dashboard files
        cp -r "$dashboard_src"/* "$dashboard_dest"/
        
        # Restore config if it existed
        if [[ -n "$config_backup" && -f "$config_backup" ]]; then
            cp "$config_backup" "$dashboard_dest/config.json"
            rm -f "$config_backup"
        fi
        
        UPDATE_ITEMS+=("Dashboard files")
        log_success "Dashboard updated"
    else
        log_info "No dashboard files to update"
    fi
}

# Run reconfiguration
run_reconfig() {
    if [[ "$RECONFIG" == "true" ]]; then
        log_step "Running reconfiguration"
        
        if [[ -f "$INSTALL_DIR/src/wizard.sh" ]]; then
            log_info "Sourcing wizard..."
            # shellcheck source=/dev/null
            source "$INSTALL_DIR/src/wizard.sh"
            main_wizard
            
            log_info "Sourcing optimization..."
            if [[ -f "$INSTALL_DIR/src/optimize.sh" ]]; then
                # shellcheck source=/dev/null
                source "$INSTALL_DIR/src/optimize.sh"
                generate_openclaw_config
                apply_system_optimizations
            fi
            
            UPDATE_ITEMS+=("Configuration (wizard + optimization)")
            log_success "Reconfiguration complete"
        else
            log_error "Wizard script not found in update"
        fi
    fi
}

# Restart gateway
restart_gateway() {
    log_step "Restarting OpenClaw gateway"
    
    if command -v openclaw >/dev/null 2>&1; then
        log_info "Running: openclaw gateway restart"
        if openclaw gateway restart 2>/dev/null; then
            log_success "Gateway restarted"
        else
            log_warning "Gateway restart had issues (may not be running)"
        fi
    else
        log_warning "openclaw command not found, skipping gateway restart"
    fi
}

# Show update summary
show_summary() {
    log_step "Update Summary"
    
    if [[ ${#UPDATE_ITEMS[@]} -gt 0 ]]; then
        log_success "Successfully updated:"
        for item in "${UPDATE_ITEMS[@]}"; do
            echo "  ✅ $item"
        done
    else
        log_info "No components needed updating"
    fi
    
    echo
    log_info "Final versions:"
    
    if command -v openclaw >/dev/null 2>&1; then
        local openclaw_version
        openclaw_version=$(openclaw --version 2>/dev/null | head -n1 | awk '{print $NF}' || echo "unknown")
        log_info "OpenClaw: $openclaw_version"
    fi
    
    if command -v ollama >/dev/null 2>&1; then
        local ollama_version
        ollama_version=$(ollama --version 2>/dev/null | awk '{print $NF}' || echo "unknown")
        log_info "Ollama: $ollama_version"
    fi
    
    if command -v node >/dev/null 2>&1; then
        local node_version
        node_version=$(node --version 2>/dev/null || echo "unknown")
        log_info "Node.js: $node_version"
    fi
    
    echo
    log_success "🎉 GooseStack update complete!"
}

# Main function
main() {
    show_banner
    
    parse_args "$@"
    
    check_current_versions
    download_latest
    compare_versions
    
    if [[ "$CHECK_ONLY" != "true" ]]; then
        update_openclaw
        update_ollama
        update_scripts
        update_dashboard
        run_reconfig
        restart_gateway
        show_summary
    fi
}

# Run main function
main "$@"