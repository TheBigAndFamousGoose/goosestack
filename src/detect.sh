#!/bin/bash
# GooseStack System Detection
# Detects macOS version, hardware specs, and validates requirements

# Exit on any error
set -euo pipefail

log_info "🔍 Detecting system specifications..."

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    log_warning "Running as root is not recommended!"
    log_warning "GooseStack should be installed as a regular user."
    echo -e "${YELLOW}Continue anyway? (y/N): ${NC}"
    if [[ -e /dev/tty ]]; then read -r continue_root < /dev/tty || continue_root="y"; else continue_root="y"; fi
    if [[ ! "$continue_root" =~ ^[Yy]$ ]]; then
        log_error "Installation cancelled. Please run without sudo."
        exit 1
    fi
fi

# Detect macOS version
detect_macos_version() {
    local version_string
    version_string=$(sw_vers -productVersion)
    local major_version
    major_version=$(echo "$version_string" | cut -d. -f1)
    local minor_version
    minor_version=$(echo "$version_string" | cut -d. -f2)
    
    GOOSE_MACOS_VER="$version_string"
    
    log_info "macOS version: $GOOSE_MACOS_VER"
    
    # Check minimum version (macOS 13+)
    if [[ $major_version -lt 13 ]]; then
        log_error "macOS 13.0 or later is required (found $GOOSE_MACOS_VER)"
        log_error "Please update your system before installing GooseStack"
        exit 1
    fi
    
    log_success "macOS version requirement met"
}

# Detect chip architecture
detect_chip() {
    local machine_type
    machine_type=$(uname -m)
    
    if [[ "$machine_type" == "arm64" ]]; then
        # Apple Silicon - determine specific chip
        local cpu_brand
        cpu_brand=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "Unknown")
        
        if [[ "$cpu_brand" == *"M4"* ]]; then
            GOOSE_CHIP="M4"
        elif [[ "$cpu_brand" == *"M3"* ]]; then
            GOOSE_CHIP="M3"
        elif [[ "$cpu_brand" == *"M2"* ]]; then
            GOOSE_CHIP="M2"
        elif [[ "$cpu_brand" == *"M1"* ]]; then
            GOOSE_CHIP="M1"
        else
            GOOSE_CHIP="Apple Silicon"
        fi
        GOOSE_ARCH="arm64"
    elif [[ "$machine_type" == "x86_64" ]]; then
        GOOSE_CHIP="Intel"
        GOOSE_ARCH="x86_64"
    else
        log_error "Unsupported architecture: $machine_type"
        exit 1
    fi
    
    log_info "Processor: $GOOSE_CHIP ($GOOSE_ARCH)"
    log_success "Architecture detection complete"
}

# Detect RAM
detect_ram() {
    local ram_bytes
    ram_bytes=$(sysctl -n hw.memsize)
    GOOSE_RAM_GB=$(( ram_bytes / 1024 / 1024 / 1024 ))
    
    log_info "RAM: ${GOOSE_RAM_GB}GB"
    
    # Check minimum RAM (8GB)
    if [[ $GOOSE_RAM_GB -lt 8 ]]; then
        log_warning "GooseStack recommends 8GB+ RAM (found ${GOOSE_RAM_GB}GB)"
        log_warning "Performance may be limited with local models"
        echo -e "${YELLOW}Continue installation? (y/N): ${NC}"
        if [[ -e /dev/tty ]]; then read -r continue_low_ram < /dev/tty || continue_low_ram="y"; else continue_low_ram="y"; fi
        if [[ ! "$continue_low_ram" =~ ^[Yy]$ ]]; then
            log_error "Installation cancelled"
            exit 1
        fi
    else
        log_success "RAM requirement met"
    fi
}

# Check available disk space (dynamic based on RAM → model selection)
check_disk_space() {
    # Get available space in 1GB blocks for root volume
    GOOSE_DISK_GB=$(df -g / | tail -1 | awk '{print $4}')
    local available_gb="$GOOSE_DISK_GB"
    
    # Calculate required space based on which model will be installed
    # Base: ~3GB (Homebrew + Node + OpenClaw + Ollama binary + workspace)
    local base_gb=3
    local model_gb
    local model_name
    
    if [[ ${GOOSE_RAM_GB:-8} -ge 16 ]]; then
        model_gb=10   # qwen3:14b ≈ 9.3GB
        model_name="qwen3:14b"
    elif [[ ${GOOSE_RAM_GB:-8} -ge 8 ]]; then
        model_gb=5    # qwen3:8b ≈ 5GB
        model_name="qwen3:8b"
    else
        model_gb=3    # qwen3:4b ≈ 2.5GB
        model_name="qwen3:4b"
    fi
    
    # Skip model space if already downloaded
    if command -v ollama >/dev/null 2>&1 && ollama list 2>/dev/null | grep -q "$model_name"; then
        log_info "Model $model_name already downloaded, skipping from disk check"
        model_gb=0
    fi
    
    # Skip base space on reinstall (most deps already present)
    if [[ "${GOOSE_REINSTALL:-false}" == "true" ]]; then
        base_gb=1
    fi
    
    local required_gb=$(( base_gb + model_gb + 2 ))  # +2GB headroom
    
    log_info "Available disk space: ${available_gb}GB"
    if [[ $model_gb -gt 0 ]]; then
        log_info "Required: ~${required_gb}GB (base: ${base_gb}GB + model ${model_name}: ${model_gb}GB + 2GB headroom)"
    else
        log_info "Required: ~${required_gb}GB (model already present)"
    fi
    
    if [[ $available_gb -lt $required_gb ]]; then
        log_error "At least ${required_gb}GB of free disk space is required (found ${available_gb}GB)"
        if [[ $model_gb -gt 0 ]]; then
            log_error "Model ${model_name} needs ~${model_gb}GB alone"
        fi
        log_error "Please free up some space before installing GooseStack"
        exit 1
    fi
    
    log_success "Disk space requirement met (${available_gb}GB available, ${required_gb}GB needed)"
}

# Check for Xcode Command Line Tools
check_xcode_clt() {
    if ! xcode-select -p >/dev/null 2>&1; then
        log_info "Xcode Command Line Tools not found, installing..."
        xcode-select --install
        
        echo -e "${YELLOW}Please complete the Command Line Tools installation in the dialog,"
        echo -e "then press Enter to continue...${NC}"
        if [[ -e /dev/tty ]]; then read -r < /dev/tty || true; else true; fi
        
        # Verify installation
        if ! xcode-select -p >/dev/null 2>&1; then
            log_error "Xcode Command Line Tools installation failed or incomplete"
            exit 1
        fi
    fi
    
    log_success "Xcode Command Line Tools available"
}

# Check if user has admin rights (required for Homebrew)
check_admin_rights() {
    log_info "Checking user permissions..."
    if groups $(whoami) | grep -qw admin; then
        log_success "User has admin rights"
    else
        log_error "Your user account '$(whoami)' does not have administrator rights"
        echo -e ""
        echo -e "  Homebrew requires admin access to install. To fix this:"
        echo -e ""
        echo -e "  Option 1: Ask an admin to grant you admin rights:"
        echo -e "    System Settings → Users & Groups → Click your account → Enable 'Allow user to administer this computer'"
        echo -e ""
        echo -e "  Option 2: Run the installer from an admin account"
        echo -e ""
        echo -e "  Then re-run: curl -fsSL https://goosestack.com/install.sh | sh"
        exit 1
    fi
}

# Detect system language
detect_language() {
    local sys_lang
    sys_lang=$(defaults read NSGlobalDomain AppleLanguages 2>/dev/null | head -2 | tail -1 | tr -d ' ",' || echo "en")
    
    if [[ "$sys_lang" == ru* ]]; then
        export GOOSE_LANG="ru"
        log_info "Язык системы: Русский"
    else
        export GOOSE_LANG="en"
        log_info "System language: English"
    fi
}

# Main detection function
main_detect() {
    detect_macos_version
    detect_chip
    detect_ram
    check_disk_space
    check_xcode_clt
    check_admin_rights
    detect_language
    
    # Export all variables for use in other scripts
    export GOOSE_CHIP GOOSE_RAM_GB GOOSE_MACOS_VER GOOSE_ARCH GOOSE_DISK_GB GOOSE_LANG
    
    log_success "System detection complete"
    
    # Summary
    echo -e "\n${BOLD}${BLUE}📊 System Summary:${NC}"
    echo -e "  OS: macOS $GOOSE_MACOS_VER"
    echo -e "  Chip: $GOOSE_CHIP"
    echo -e "  RAM: ${GOOSE_RAM_GB}GB"
    echo -e "  Architecture: $GOOSE_ARCH"
    echo -e "  Disk Space: ${GOOSE_DISK_GB}GB available"
}

# Run detection
main_detect