#!/bin/bash
# GooseStack Migration - Export and Import for backup/restore
set -euo pipefail

# Colors (matching GooseStack style)
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m' # No Color

# Globals
MODE=""
EXPORT_PATH=""
IMPORT_PATH=""
FULL_EXPORT=false
MINIMAL_EXPORT=false
TEMP_DIR=""

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

# Check if running in TTY (for prompts)
is_tty() {
    [[ -t 0 ]]
}

# Show help
show_help() {
    echo "GooseStack Migration Tool"
    echo ""
    echo "Usage:"
    echo "  $0 export [path] [--full|--minimal]"
    echo "  $0 import <path>"
    echo ""
    echo "Export modes:"
    echo "  --full      Include everything without prompting"
    echo "  --minimal   Just workspace + config (no sessions/credentials)"
    echo ""
    echo "Examples:"
    echo "  $0 export ~/my-backup.tar.gz"
    echo "  $0 export --full"
    echo "  $0 import ~/my-backup.tar.gz"
    exit 0
}

# Parse arguments
parse_args() {
    if [[ $# -eq 0 ]]; then
        show_help
    fi
    
    MODE="$1"
    shift
    
    case "$MODE" in
        export)
            parse_export_args "$@"
            ;;
        import)
            parse_import_args "$@"
            ;;
        -h|--help|help)
            show_help
            ;;
        *)
            log_error "Unknown mode: $MODE"
            show_help
            ;;
    esac
}

# Parse export arguments
parse_export_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --full)
                FULL_EXPORT=true
                shift
                ;;
            --minimal)
                MINIMAL_EXPORT=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                if [[ -z "$EXPORT_PATH" ]]; then
                    EXPORT_PATH="$1"
                else
                    log_error "Unknown export option: $1"
                    show_help
                fi
                shift
                ;;
        esac
    done
    
    # Default export path if not specified
    if [[ -z "$EXPORT_PATH" ]]; then
        local timestamp
        timestamp=$(date +%Y%m%d-%H%M%S)
        EXPORT_PATH="$HOME/goosestack-backup-$timestamp.tar.gz"
    fi
    
    # Expand ~ in path
    EXPORT_PATH="${EXPORT_PATH/#\~/$HOME}"
}

# Parse import arguments
parse_import_args() {
    if [[ $# -eq 0 ]]; then
        log_error "Import requires a path to the backup file"
        show_help
    fi
    
    IMPORT_PATH="$1"
    shift
    
    # Handle additional args
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown import option: $1"
                show_help
                ;;
        esac
    done
    
    # Expand ~ in path
    IMPORT_PATH="${IMPORT_PATH/#\~/$HOME}"
}

# Prompt user for yes/no
prompt_yn() {
    local message="$1"
    local default="${2:-N}"
    
    if ! is_tty; then
        # Not a TTY, use default
        log_info "$message (non-TTY, using default: $default)"
        [[ "$default" == "y" || "$default" == "Y" ]]
        return
    fi
    
    local prompt_suffix
    if [[ "$default" == "y" || "$default" == "Y" ]]; then
        prompt_suffix="(Y/n)"
    else
        prompt_suffix="(y/N)"
    fi
    
    while true; do
        read -p "$message $prompt_suffix: " -n 1 -r
        echo
        
        if [[ -z "$REPLY" ]]; then
            # Use default
            [[ "$default" == "y" || "$default" == "Y" ]]
            return
        elif [[ $REPLY =~ ^[Yy]$ ]]; then
            return 0
        elif [[ $REPLY =~ ^[Nn]$ ]]; then
            return 1
        else
            echo "Please answer y or n."
        fi
    done
}

# Collect files for export
collect_export_files() {
    log_step "Collecting files for export"
    
    TEMP_DIR=$(mktemp -d)
    local staging_dir="$TEMP_DIR/goosestack-backup"
    mkdir -p "$staging_dir"
    
    local openclaw_dir="$HOME/.openclaw"
    
    if [[ ! -d "$openclaw_dir" ]]; then
        log_error "OpenClaw directory not found: $openclaw_dir"
        exit 1
    fi
    
    # Always include core files
    log_info "Including core configuration files..."
    
    # Main config
    if [[ -f "$openclaw_dir/openclaw.json" ]]; then
        cp "$openclaw_dir/openclaw.json" "$staging_dir/"
        log_success "✅ openclaw.json"
    fi
    
    # Gateway token
    if [[ -f "$openclaw_dir/.gateway-token" ]]; then
        cp "$openclaw_dir/.gateway-token" "$staging_dir/"
        log_success "✅ .gateway-token"
    fi
    
    # Auth profiles
    if [[ -f "$openclaw_dir/agents/main/agent/auth-profiles.json" ]]; then
        mkdir -p "$staging_dir/agents/main/agent"
        cp "$openclaw_dir/agents/main/agent/auth-profiles.json" "$staging_dir/agents/main/agent/"
        log_success "✅ auth-profiles.json"
    fi
    
    # Workspace (entire directory)
    if [[ -d "$openclaw_dir/workspace" ]]; then
        cp -r "$openclaw_dir/workspace" "$staging_dir/"
        log_success "✅ workspace/ directory"
    fi
    
    # Dashboard config
    if [[ -f "$openclaw_dir/dashboard/config.json" ]]; then
        mkdir -p "$staging_dir/dashboard"
        cp "$openclaw_dir/dashboard/config.json" "$staging_dir/dashboard/"
        log_success "✅ dashboard/config.json"
    fi
    
    # Handle optional files based on mode
    if [[ "$FULL_EXPORT" == "true" ]]; then
        log_info "Full export - including all optional files..."
        include_sessions=true
        include_credentials=true
    elif [[ "$MINIMAL_EXPORT" == "true" ]]; then
        log_info "Minimal export - skipping optional files..."
        include_sessions=false
        include_credentials=false
    else
        # Interactive mode
        log_info "Optional files (can be large):"
        
        include_sessions=false
        if [[ -d "$openclaw_dir/agents/main/sessions" ]]; then
            local sessions_size
            sessions_size=$(du -sh "$openclaw_dir/agents/main/sessions" 2>/dev/null | cut -f1 || echo "unknown")
            if prompt_yn "Include session history? Size: $sessions_size" "N"; then
                include_sessions=true
            fi
        fi
        
        include_credentials=false
        if [[ -d "$openclaw_dir/credentials" ]]; then
            if prompt_yn "Include credentials directory?" "N"; then
                include_credentials=true
            fi
        fi
    fi
    
    # Include sessions if requested
    if [[ "$include_sessions" == "true" && -d "$openclaw_dir/agents/main/sessions" ]]; then
        mkdir -p "$staging_dir/agents/main"
        cp -r "$openclaw_dir/agents/main/sessions" "$staging_dir/agents/main/"
        log_success "✅ sessions/ directory"
    fi
    
    # Include credentials if requested
    if [[ "$include_credentials" == "true" && -d "$openclaw_dir/credentials" ]]; then
        cp -r "$openclaw_dir/credentials" "$staging_dir/"
        log_success "✅ credentials/ directory"
    fi
    
    echo "$staging_dir"
}

# Create tarball
create_tarball() {
    local staging_dir="$1"
    
    log_step "Creating backup archive"
    
    # Ensure parent directory exists
    local parent_dir
    parent_dir=$(dirname "$EXPORT_PATH")
    mkdir -p "$parent_dir"
    
    # Create tarball with relative paths
    log_info "Creating: $EXPORT_PATH"
    cd "$TEMP_DIR"
    if tar -czf "$EXPORT_PATH" goosestack-backup/; then
        log_success "Archive created successfully"
    else
        log_error "Failed to create archive"
        exit 1
    fi
    
    # Calculate size
    local size
    size=$(du -sh "$EXPORT_PATH" 2>/dev/null | cut -f1 || echo "unknown")
    
    log_success "Export complete!"
    log_info "File: $EXPORT_PATH"
    log_info "Size: $size"
    
    # List what's included
    echo
    log_info "Contents:"
    tar -tzf "$EXPORT_PATH" | sed 's|goosestack-backup/||' | grep -v '^$' | sort | while read -r file; do
        echo "  📄 $file"
    done
}

# Export mode main function
do_export() {
    echo -e "${CYAN}"
    cat << 'EOF'
    📦 GooseStack Export
    
EOF
    echo -e "${NC}"
    
    local staging_dir
    staging_dir=$(collect_export_files)
    create_tarball "$staging_dir"
}

# Verify import file
verify_import_file() {
    log_step "Verifying backup file"
    
    if [[ ! -f "$IMPORT_PATH" ]]; then
        log_error "Backup file not found: $IMPORT_PATH"
        exit 1
    fi
    
    # Check if it's a valid tar.gz
    if ! tar -tzf "$IMPORT_PATH" >/dev/null 2>&1; then
        log_error "File does not appear to be a valid tar.gz archive"
        exit 1
    fi
    
    # Check if it looks like a GooseStack export
    if ! tar -tzf "$IMPORT_PATH" | grep -q "goosestack-backup/openclaw.json"; then
        log_error "File does not appear to be a GooseStack export (missing openclaw.json)"
        exit 1
    fi
    
    log_success "Backup file verified"
    
    # Show contents
    local size
    size=$(du -sh "$IMPORT_PATH" 2>/dev/null | cut -f1 || echo "unknown")
    log_info "File: $IMPORT_PATH"
    log_info "Size: $size"
    
    echo
    log_info "Archive contents:"
    tar -tzf "$IMPORT_PATH" | sed 's|goosestack-backup/||' | grep -v '^$' | sort | while read -r file; do
        echo "  📄 $file"
    done
}

# Backup current installation
backup_current() {
    log_step "Backing up current installation"
    
    local openclaw_dir="$HOME/.openclaw"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_dir="$HOME/.openclaw-pre-import-$timestamp"
    
    if [[ -d "$openclaw_dir" ]]; then
        log_info "Backing up current ~/.openclaw/ to: $backup_dir"
        cp -r "$openclaw_dir" "$backup_dir"
        log_success "Current installation backed up"
        echo "  📁 $backup_dir"
    else
        log_info "No existing installation to back up"
    fi
}

# Extract and restore files
restore_files() {
    log_step "Restoring files from backup"
    
    TEMP_DIR=$(mktemp -d)
    cd "$TEMP_DIR"
    
    # Extract the archive
    log_info "Extracting archive..."
    tar -xzf "$IMPORT_PATH"
    
    local extracted_dir="$TEMP_DIR/goosestack-backup"
    if [[ ! -d "$extracted_dir" ]]; then
        log_error "Extracted archive missing expected directory structure"
        exit 1
    fi
    
    # Create target directory
    local openclaw_dir="$HOME/.openclaw"
    mkdir -p "$openclaw_dir"
    
    # Restore files
    log_info "Restoring files..."
    cp -r "$extracted_dir"/* "$openclaw_dir"/
    
    # Fix permissions
    log_info "Setting proper permissions..."
    find "$openclaw_dir" -type d -exec chmod 700 {} \;
    find "$openclaw_dir" -type f -exec chmod 600 {} \;
    
    # Make sure workspace is accessible
    if [[ -d "$openclaw_dir/workspace" ]]; then
        chmod 755 "$openclaw_dir/workspace"
        find "$openclaw_dir/workspace" -type d -exec chmod 755 {} \;
        find "$openclaw_dir/workspace" -type f -exec chmod 644 {} \;
    fi
    
    log_success "Files restored successfully"
}

# Import mode main function  
do_import() {
    echo -e "${CYAN}"
    cat << 'EOF'
    📥 GooseStack Import
    
EOF
    echo -e "${NC}"
    
    verify_import_file
    
    echo
    log_warning "⚠️  This will overwrite your current GooseStack configuration and workspace!"
    log_warning "Your current installation will be backed up first."
    
    if ! prompt_yn "Continue with import?" "N"; then
        log_info "Import cancelled."
        exit 0
    fi
    
    backup_current
    restore_files
    
    # Restart gateway if openclaw is available
    if command -v openclaw >/dev/null 2>&1; then
        log_step "Restarting gateway"
        if openclaw gateway restart 2>/dev/null; then
            log_success "Gateway restarted"
        else
            log_warning "Gateway restart had issues (may not be running)"
        fi
    fi
    
    log_success "🎉 Import complete!"
    log_info "Your GooseStack configuration has been restored from the backup."
}

# Main function
main() {
    parse_args "$@"
    
    case "$MODE" in
        export)
            do_export
            ;;
        import)
            do_import
            ;;
    esac
}

# Run main function
main "$@"