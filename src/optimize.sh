#!/bin/bash
# GooseStack System Optimization
# Applies hardware-specific optimizations and template processing

# Exit on any error
set -euo pipefail

# Process templates and apply configuration
process_templates() {
    log_info "🎨 Processing configuration templates..."
    
    local template_dir="$INSTALL_DIR/src/templates"
    local workspace_dir="$GOOSE_WORKSPACE_DIR"
    local config_dir="$HOME/.openclaw"
    
    # Verify template directory exists
    if [[ ! -d "$template_dir" ]]; then
        log_error "Template directory not found: $template_dir"
        exit 1
    fi
    
    # Process openclaw.json template
    log_info "Updating OpenClaw configuration..."
    
    local config_template="$template_dir/openclaw.json.tmpl"
    local config_output="$config_dir/openclaw.json"
    
    if [[ -f "$config_template" ]]; then
        # Use envsubst to replace template variables
        envsubst < "$config_template" > "$config_output"
        log_success "OpenClaw configuration updated"
    else
        log_warning "OpenClaw config template not found, using base config"
    fi
    
    # Process workspace templates
    log_info "Setting up workspace files..."
    
    # Copy AGENTS.md
    if [[ -f "$template_dir/AGENTS.md" ]]; then
        cp "$template_dir/AGENTS.md" "$workspace_dir/AGENTS.md"
        log_success "AGENTS.md configured"
    fi
    
    # Process persona-specific SOUL.md
    local soul_template="$template_dir/SOUL-${GOOSE_AGENT_PERSONA}.md"
    if [[ -f "$soul_template" ]]; then
        cp "$soul_template" "$workspace_dir/SOUL.md"
        log_success "SOUL.md configured for $GOOSE_AGENT_PERSONA persona"
    else
        log_warning "Persona template not found: $soul_template"
    fi
    
    # Process USER.md template
    local user_template="$template_dir/USER.md.tmpl"
    if [[ -f "$user_template" ]]; then
        envsubst < "$user_template" > "$workspace_dir/USER.md"
        log_success "USER.md configured for $GOOSE_USER_NAME"
    fi
    
    # Update existing TOOLS.md with template if available
    if [[ -f "$template_dir/TOOLS.md" ]]; then
        cp "$template_dir/TOOLS.md" "$workspace_dir/TOOLS.md"
        log_success "TOOLS.md updated with template"
    fi
    
    # Update MEMORY.md if template exists
    if [[ -f "$template_dir/MEMORY.md" ]]; then
        # Don't overwrite existing MEMORY.md, just ensure it exists
        if [[ ! -f "$workspace_dir/MEMORY.md" ]]; then
            cp "$template_dir/MEMORY.md" "$workspace_dir/MEMORY.md"
            log_success "MEMORY.md initialized"
        else
            log_info "MEMORY.md already exists, keeping existing content"
        fi
    fi
    
    # Update HEARTBEAT.md if template exists
    if [[ -f "$template_dir/HEARTBEAT.md" ]]; then
        if [[ ! -f "$workspace_dir/HEARTBEAT.md" ]]; then
            cp "$template_dir/HEARTBEAT.md" "$workspace_dir/HEARTBEAT.md"
            log_success "HEARTBEAT.md initialized"
        else
            log_info "HEARTBEAT.md already exists, keeping existing content"
        fi
    fi
}

# Apply hardware-specific optimizations
apply_hardware_optimizations() {
    log_info "⚡ Applying hardware-specific optimizations..."
    
    local config_file="$HOME/.openclaw/openclaw.json"
    local temp_config=$(mktemp)
    
    # Read current config
    cp "$config_file" "$temp_config"
    
    # Apply RAM-based optimizations
    if [[ $GOOSE_RAM_GB -ge 32 ]]; then
        log_info "High RAM detected (${GOOSE_RAM_GB}GB) - enabling aggressive optimizations"
        # Increase max concurrent subagents and memory search results
        sed -i '' 's/"maxConcurrent": [0-9]*/"maxConcurrent": 5/' "$temp_config"
        sed -i '' 's/"maxResults": [0-9]*/"maxResults": 15/' "$temp_config"
    elif [[ $GOOSE_RAM_GB -ge 16 ]]; then
        log_info "Medium RAM detected (${GOOSE_RAM_GB}GB) - balanced optimizations"
        # Standard settings are already good
        sed -i '' 's/"maxConcurrent": [0-9]*/"maxConcurrent": 3/' "$temp_config"
        sed -i '' 's/"maxResults": [0-9]*/"maxResults": 10/' "$temp_config"
    else
        log_info "Lower RAM detected (${GOOSE_RAM_GB}GB) - conservative optimizations"
        # Reduce resource usage
        sed -i '' 's/"maxConcurrent": [0-9]*/"maxConcurrent": 2/' "$temp_config"
        sed -i '' 's/"maxResults": [0-9]*/"maxResults": 5/' "$temp_config"
        sed -i '' 's/"timeoutSeconds": [0-9]*/"timeoutSeconds": 300/' "$temp_config"
    fi
    
    # Apply chip-specific optimizations
    if [[ "$GOOSE_CHIP" == "M4" || "$GOOSE_CHIP" == "M3" ]]; then
        log_info "Latest Apple Silicon detected - enabling enhanced features"
        # Could add chip-specific settings here in the future
    elif [[ "$GOOSE_CHIP" == "Intel" ]]; then
        log_info "Intel processor detected - applying compatibility settings"
        # More conservative settings for Intel Macs
        sed -i '' 's/"timeoutSeconds": [0-9]*/"timeoutSeconds": 450/' "$temp_config"
    fi
    
    # Validate and apply the updated config
    if python3 -m json.tool "$temp_config" > /dev/null 2>&1; then
        cp "$temp_config" "$config_file"
        log_success "Hardware optimizations applied"
    else
        log_error "Configuration validation failed, keeping original"
        exit 1
    fi
    
    rm -f "$temp_config"
}

# Configure local embeddings
setup_local_embeddings() {
    log_info "🔍 Setting up local embeddings for memory search..."
    
    # Check if Ollama embedding model is available
    if ollama list | grep -q "nomic-embed-text"; then
        log_success "Embedding model already available"
    else
        log_info "Pulling embedding model for local memory search..."
        ollama pull nomic-embed-text
        
        if [[ $? -eq 0 ]]; then
            log_success "Embedding model downloaded successfully"
        else
            log_warning "Failed to download embedding model - memory search may be limited"
        fi
    fi
}

# Validate final configuration
validate_configuration() {
    log_info "✅ Validating final configuration..."
    
    local config_file="$HOME/.openclaw/openclaw.json"
    local workspace_dir="$GOOSE_WORKSPACE_DIR"
    
    # Validate JSON syntax
    if ! python3 -m json.tool "$config_file" > /dev/null 2>&1; then
        log_error "OpenClaw configuration has invalid JSON syntax"
        exit 1
    fi
    
    # Check essential workspace files
    local essential_files=("AGENTS.md" "SOUL.md" "USER.md" "TOOLS.md")
    for file in "${essential_files[@]}"; do
        if [[ ! -f "$workspace_dir/$file" ]]; then
            log_error "Essential workspace file missing: $file"
            exit 1
        fi
    done
    
    # Verify memory directory exists
    if [[ ! -d "$workspace_dir/memory" ]]; then
        mkdir -p "$workspace_dir/memory"
        log_info "Created memory directory"
    fi
    
    log_success "Configuration validation passed"
}

# Main optimization function
main_optimize() {
    log_info "🚀 Optimizing system configuration..."
    
    process_templates
    apply_hardware_optimizations
    setup_local_embeddings
    validate_configuration
    
    log_success "System optimization complete!"
    
    # Summary
    echo -e "\n${BOLD}${BLUE}⚡ Optimization Summary:${NC}"
    echo -e "  ✅ Templates processed and applied"
    echo -e "  ✅ Hardware-specific settings configured"
    echo -e "  ✅ Local embeddings ready for memory search"
    echo -e "  ✅ Configuration validated"
    echo -e "  ✅ Workspace files ready"
}

# Run optimization
main_optimize