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
    read -r continue_root
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
        read -r continue_low_ram
        if [[ ! "$continue_low_ram" =~ ^[Yy]$ ]]; then
            log_error "Installation cancelled"
            exit 1
        fi
    else
        log_success "RAM requirement met"
    fi
}

# Check available disk space
check_disk_space() {
    # Get available space in 1GB blocks for root volume
    GOOSE_DISK_GB=$(df -g / | tail -1 | awk '{print $4}')
    local available_gb="$GOOSE_DISK_GB"
    
    log_info "Available disk space: ${available_gb}GB"
    
    # Check minimum space (15GB)
    if [[ $available_gb -lt 15 ]]; then
        log_error "At least 15GB of free disk space is required (found ${available_gb}GB)"
        log_error "Please free up some space before installing GooseStack"
        exit 1
    fi
    
    log_success "Disk space requirement met"
}

# Check for Xcode Command Line Tools
check_xcode_clt() {
    if ! xcode-select -p >/dev/null 2>&1; then
        log_info "Xcode Command Line Tools not found, installing..."
        xcode-select --install
        
        echo -e "${YELLOW}Please complete the Command Line Tools installation in the dialog,"
        echo -e "then press Enter to continue...${NC}"
        read -r
        
        # Verify installation
        if ! xcode-select -p >/dev/null 2>&1; then
            log_error "Xcode Command Line Tools installation failed or incomplete"
            exit 1
        fi
    fi
    
    log_success "Xcode Command Line Tools available"
}

# Main detection function
main_detect() {
    detect_macos_version
    detect_chip
    detect_ram
    check_disk_space
    check_xcode_clt
    
    # Export all variables for use in other scripts
    export GOOSE_CHIP GOOSE_RAM_GB GOOSE_MACOS_VER GOOSE_ARCH GOOSE_DISK_GB
    
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