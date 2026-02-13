#!/bin/bash
# GooseStack Dependencies Installation
# Installs Homebrew, Node.js, and Ollama with optimal model selection

# Exit on any error
set -euo pipefail

# Progress indicator
show_progress() {
    local current=$1
    local total=$2
    local task=$3
    local percent=$((current * 100 / total))
    echo -e "${CYAN}[$current/$total] ($percent%) $task${NC}"
}

# Install Xcode Command Line Tools if needed
install_xcode_clt() {
    show_progress 1 5 "Checking Xcode Command Line Tools..."
    
    # Check if CLT are already installed
    if xcode-select -p &>/dev/null; then
        log_success "Xcode Command Line Tools already installed"
        return
    fi
    
    log_info "Xcode Command Line Tools not found, installing..."
    log_info "This will open a system dialog - please click 'Install' when prompted"
    
    # Start the installation (this opens GUI dialog and returns immediately)
    xcode-select --install
    
    # Wait for installation to complete with polling loop
    log_info "Waiting for Xcode Command Line Tools installation... (click Install in the dialog)"
    
    local timeout=600  # 10 minutes in seconds
    local elapsed=0
    local check_interval=10
    
    while ! xcode-select -p &>/dev/null; do
        if [[ $elapsed -ge $timeout ]]; then
            log_error "Xcode Command Line Tools installation timed out. Please install manually: xcode-select --install"
            exit 1
        fi
        
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
        
        # Show progress every minute
        if [[ $((elapsed % 60)) -eq 0 ]]; then
            local minutes=$((elapsed / 60))
            log_info "Still waiting for installation... (${minutes}m elapsed)"
        fi
    done
    
    # Verify installation completed successfully
    if xcode-select -p &>/dev/null; then
        log_success "Xcode Command Line Tools installed successfully"
    else
        log_error "Xcode Command Line Tools installation verification failed"
        exit 1
    fi
}

# Check if Homebrew is installed
install_homebrew() {
    show_progress 2 5 "Checking Homebrew..."
    
    if command -v brew >/dev/null 2>&1; then
        log_success "Homebrew already installed"
    else
        log_info "Installing Homebrew..."
        
        # Pre-authenticate sudo before Homebrew install
        # Needed because curl|sh pipes stdin, so Homebrew can't prompt for password
        if ! sudo -n true 2>/dev/null; then
            echo -e "${YELLOW}Homebrew needs administrator access. Please enter your password:${NC}"
            sudo -v -S < /dev/tty
        fi
        
        # Download and install Homebrew
        NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        
        # Add Homebrew to PATH for current session
        if [[ "$GOOSE_ARCH" == "arm64" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
        else
            eval "$(/usr/local/bin/brew shellenv)"
            echo 'eval "$(/usr/local/bin/brew shellenv)"' >> ~/.zprofile
        fi
        
        # Verify installation
        if ! command -v brew >/dev/null 2>&1; then
            log_error "Homebrew installation failed"
            exit 1
        fi
        
        log_success "Homebrew installed successfully"
    fi
    
    # Update Homebrew
    log_info "Updating Homebrew..."
    brew update --quiet || {
        log_warning "Homebrew update had issues (continuing anyway)"
        true  # Ensure this doesn't fail the script
    }
}

# Install Node.js
install_nodejs() {
    show_progress 3 5 "Installing Node.js..."
    
    if command -v node >/dev/null 2>&1; then
        local node_version
        node_version=$(node --version)
        log_info "Node.js already installed: $node_version"
        
        # Check if version is recent enough (v18+)
        local major_version
        major_version=$(echo "$node_version" | sed 's/v\([0-9]*\).*/\1/')
        if [[ $major_version -lt 18 ]]; then
            log_warning "Node.js version $node_version is old, upgrading..."
            brew upgrade node
        else
            log_success "Node.js version is compatible"
            return
        fi
    else
        log_info "Installing Node.js via Homebrew..."
        brew install node
    fi
    
    # Verify installation
    if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
        log_error "Node.js installation failed"
        exit 1
    fi
    
    local final_version
    final_version=$(node --version)
    log_success "Node.js installed: $final_version"
}

# Install Ollama
install_ollama() {
    show_progress 4 5 "Installing Ollama..."
    
    if command -v ollama >/dev/null 2>&1; then
        log_success "Ollama already installed"
    else
        log_info "Installing Ollama via Homebrew..."
        brew install ollama
        
        # Verify installation
        if ! command -v ollama >/dev/null 2>&1; then
            log_error "Ollama installation failed"
            exit 1
        fi
        
        log_success "Ollama installed successfully"
    fi
    
    # Start Ollama service
    log_info "Starting Ollama service..."
    brew services start ollama || {
        log_warning "Failed to start Ollama service via brew, trying direct start..."
        ollama serve &
        sleep 3
    }
    
    # Wait for Ollama to be ready
    local max_attempts=30
    local attempt=0
    while ! ollama list >/dev/null 2>&1 && [[ $attempt -lt $max_attempts ]]; do
        sleep 1
        ((attempt++))
    done
    
    if [[ $attempt -eq $max_attempts ]]; then
        log_error "Ollama service failed to start"
        exit 1
    fi
    
    log_success "Ollama service is running"
}

# Pull optimal model based on RAM
pull_optimal_model() {
    show_progress 5 5 "Selecting and downloading optimal AI model..."
    
    # Determine best model based on RAM
    local model_name
    if [[ $GOOSE_RAM_GB -ge 16 ]]; then
        model_name="qwen3:14b"
        log_info "RAM: ${GOOSE_RAM_GB}GB → Using qwen3:14b (high performance)"
    elif [[ $GOOSE_RAM_GB -ge 8 ]]; then
        model_name="qwen3:8b"
        log_info "RAM: ${GOOSE_RAM_GB}GB → Using qwen3:8b (balanced)"
    else
        model_name="qwen3:4b"
        log_warning "RAM: ${GOOSE_RAM_GB}GB → Using qwen3:4b (performance may be limited)"
    fi
    
    # Check if model is already pulled
    if ollama list | grep -q "$model_name"; then
        log_success "Model $model_name already available"
    else
        log_info "Downloading $model_name (this may take several minutes)..."
        
        # Show download progress
        ollama pull "$model_name" &
        local pull_pid=$!
        
        # Simple progress indicator while downloading
        local spinner='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        while kill -0 $pull_pid 2>/dev/null; do
            for (( i=0; i<${#spinner}; i++ )); do
                printf "\r${CYAN}%s Downloading model... ${NC}" "${spinner:$i:1}"
                sleep 0.2
            done
        done
        printf "\r"
        
        wait $pull_pid
        if [[ $? -eq 0 ]]; then
            log_success "Model $model_name downloaded successfully"
        else
            log_error "Failed to download model $model_name"
            exit 1
        fi
    fi
    
    # Test the model quickly
    log_info "Testing model..."
    if echo "Hi" | ollama run "$model_name" --timeout 10s >/dev/null 2>&1; then
        log_success "Model $model_name is working correctly"
    else
        log_warning "Model test had issues (but continuing installation)"
    fi
    
    # Export model name for use in other scripts
    export GOOSE_OLLAMA_MODEL="$model_name"
}

# Main installation function
main_install_deps() {
    log_info "📦 Installing dependencies..."
    
    install_xcode_clt
    install_homebrew
    install_nodejs
    install_ollama
    pull_optimal_model
    
    log_success "All dependencies installed successfully!"
    
    # Summary
    echo -e "\n${BOLD}${BLUE}📋 Installed Components:${NC}"
    echo -e "  ✅ Homebrew: $(brew --version | head -1)"
    echo -e "  ✅ Node.js: $(node --version)"
    echo -e "  ✅ npm: v$(npm --version)"
    echo -e "  ✅ Ollama: $(ollama --version || echo 'installed')"
    echo -e "  ✅ AI Model: $GOOSE_OLLAMA_MODEL"
}

# Run installation
main_install_deps