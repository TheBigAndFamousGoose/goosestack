#!/bin/bash

# GooseStack Uninstall Script
# Removes all GooseStack components and optionally OpenClaw/Ollama

set -e

# Colors for output (matching GooseStack style)
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default values
FORCE=false
KEEP_WORKSPACE=false

# Track what was removed for summary
REMOVED_ITEMS=()

# Print colored output
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_action() {
    echo -e "${CYAN}[ACTION]${NC} $1"
}

# Print usage
usage() {
    echo "Usage: $0 [OPTIONS]"
    echo "Options:"
    echo "  --force           Skip confirmation prompts"
    echo "  --keep-workspace  Preserve ~/.openclaw/workspace/ directory"
    echo "  -h, --help        Show this help message"
    exit 0
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            FORCE=true
            shift
            ;;
        --keep-workspace)
            KEEP_WORKSPACE=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            print_error "Unknown option: $1"
            usage
            ;;
    esac
done

# Confirmation prompt
confirm_uninstall() {
    if [[ "$FORCE" == "true" ]]; then
        return 0
    fi
    
    echo
    print_warning "⚠️  This will completely remove GooseStack from your system:"
    echo "   • Stop and remove LaunchAgents (ai.openclaw.gateway, ai.openclaw.watchdog)"
    echo "   • Kill caffeinate process"
    if [[ "$KEEP_WORKSPACE" == "true" ]]; then
        echo "   • Remove ~/.openclaw/ directory (EXCEPT workspace/)"
    else
        echo "   • Remove ~/.openclaw/ directory (including workspace, config, logs, sessions)"
    fi
    echo "   • Remove Ollama models (qwen3:4b, qwen3:8b, qwen3:14b, nomic-embed-text)"
    echo "   • Remove goosestack CLI symlink"
    echo "   • Restore default sleep settings"
    echo "   • Optionally remove OpenClaw and/or Ollama"
    echo
    
    read -p "Are you sure you want to continue? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_status "Uninstall cancelled."
        exit 0
    fi
}

# Stop and unload LaunchAgents
remove_launch_agents() {
    print_action "Stopping and removing LaunchAgents..."
    
    local agents=("ai.openclaw.gateway" "ai.openclaw.watchdog")
    local launch_agents_dir="$HOME/Library/LaunchAgents"
    
    for agent in "${agents[@]}"; do
        local plist_file="${launch_agents_dir}/${agent}.plist"
        
        if [[ -f "$plist_file" ]]; then
            print_status "Found $agent.plist, attempting to unload and remove..."
            
            # Try to unload the agent (ignore errors if not loaded)
            if launchctl unload "$plist_file" 2>/dev/null; then
                print_status "✓ Unloaded $agent"
            else
                print_warning "Could not unload $agent (may not be loaded)"
            fi
            
            # Remove the plist file
            rm -f "$plist_file"
            print_status "✓ Removed $agent.plist"
            REMOVED_ITEMS+=("LaunchAgent: $agent")
        else
            print_status "✓ $agent.plist not found (already removed)"
        fi
    done
}

# Kill caffeinate process
kill_caffeinate() {
    print_action "Checking for caffeinate process..."
    
    local pid_file="$HOME/.openclaw/caffeinate.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid=$(cat "$pid_file" 2>/dev/null || echo "")
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            print_status "Found caffeinate process (PID: $pid), terminating..."
            kill "$pid" 2>/dev/null || true
            print_status "✓ Terminated caffeinate process"
            REMOVED_ITEMS+=("Caffeinate process (PID: $pid)")
        else
            print_status "✓ No running caffeinate process found"
        fi
        rm -f "$pid_file"
    else
        print_status "✓ No caffeinate PID file found"
    fi
}

# Remove ~/.openclaw/ directory
remove_openclaw_dir() {
    print_action "Removing ~/.openclaw/ directory..."
    
    local openclaw_dir="$HOME/.openclaw"
    
    if [[ ! -d "$openclaw_dir" ]]; then
        print_status "✓ ~/.openclaw/ directory not found (already removed)"
        return 0
    fi
    
    if [[ "$KEEP_WORKSPACE" == "true" ]]; then
        local workspace_dir="${openclaw_dir}/workspace"
        local backup_dir="${HOME}/goosestack-workspace-backup-$(date +%Y%m%d-%H%M%S)"
        
        if [[ -d "$workspace_dir" ]]; then
            print_status "Backing up workspace to: $backup_dir"
            cp -R "$workspace_dir" "$backup_dir"
            print_status "✓ Workspace backed up"
            REMOVED_ITEMS+=("Workspace backed up to: $backup_dir")
        fi
    fi
    
    rm -rf "$openclaw_dir"
    print_status "✓ Removed ~/.openclaw/ directory"
    REMOVED_ITEMS+=("~/.openclaw/ directory")
}

# Remove Ollama models
remove_ollama_models() {
    print_action "Removing GooseStack Ollama models..."
    
    # Check if ollama command exists
    if ! command -v ollama &> /dev/null; then
        print_warning "Ollama command not found, skipping model removal"
        return 0
    fi
    
    local models=("qwen3:4b" "qwen3:8b" "qwen3:14b" "nomic-embed-text")
    
    for model in "${models[@]}"; do
        if ollama list | grep -q "^$model"; then
            print_status "Removing model: $model"
            if ollama rm "$model" 2>/dev/null; then
                print_status "✓ Removed $model"
                REMOVED_ITEMS+=("Ollama model: $model")
            else
                print_error "Failed to remove $model"
            fi
        else
            print_status "✓ Model $model not found (already removed)"
        fi
    done
}

# Remove goosestack CLI symlink
remove_cli_symlink() {
    print_action "Removing goosestack CLI symlink..."
    
    local symlink_path="/opt/homebrew/bin/goosestack"
    
    if [[ -L "$symlink_path" ]]; then
        rm -f "$symlink_path"
        print_status "✓ Removed goosestack CLI symlink"
        REMOVED_ITEMS+=("GooseStack CLI symlink")
    else
        print_status "✓ goosestack CLI symlink not found (already removed)"
    fi
}

# Restore sleep settings
restore_sleep_settings() {
    print_action "Restoring default sleep settings..."
    
    print_status "Setting sleep=1, displaysleep=10, disksleep=10..."
    if sudo pmset -a sleep 1 displaysleep 10 disksleep 10; then
        print_status "✓ Sleep settings restored to defaults"
        REMOVED_ITEMS+=("Custom sleep settings (restored to defaults)")
    else
        print_error "Failed to restore sleep settings"
    fi
}

# Optional: Remove OpenClaw
remove_openclaw() {
    if [[ "$FORCE" == "true" ]]; then
        return 0  # Skip optional removals in force mode
    fi
    
    print_action "Optional: Remove OpenClaw globally?"
    echo "This will run: npm uninstall -g openclaw"
    read -p "Remove OpenClaw? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if command -v npm &> /dev/null; then
            print_status "Removing OpenClaw..."
            if npm uninstall -g openclaw; then
                print_status "✓ OpenClaw removed"
                REMOVED_ITEMS+=("OpenClaw (npm package)")
            else
                print_error "Failed to remove OpenClaw"
            fi
        else
            print_error "npm not found, cannot remove OpenClaw"
        fi
    else
        print_status "Skipping OpenClaw removal"
    fi
}

# Optional: Remove Ollama entirely
remove_ollama() {
    if [[ "$FORCE" == "true" ]]; then
        return 0  # Skip optional removals in force mode
    fi
    
    print_action "Optional: Remove Ollama entirely?"
    echo "This will run: brew uninstall ollama"
    read -p "Remove Ollama? (y/N): " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if command -v brew &> /dev/null; then
            print_status "Removing Ollama..."
            if brew uninstall ollama; then
                print_status "✓ Ollama removed"
                REMOVED_ITEMS+=("Ollama (Homebrew package)")
            else
                print_error "Failed to remove Ollama"
            fi
        else
            print_error "Homebrew not found, cannot remove Ollama"
        fi
    else
        print_status "Skipping Ollama removal"
    fi
}

# Show summary
show_summary() {
    echo
    print_status "🎉 GooseStack uninstall completed!"
    echo
    
    if [[ ${#REMOVED_ITEMS[@]} -gt 0 ]]; then
        print_status "Summary of removed components:"
        for item in "${REMOVED_ITEMS[@]}"; do
            echo "  ✓ $item"
        done
    else
        print_status "No components needed to be removed (already clean)"
    fi
    
    echo
    print_status "GooseStack has been successfully removed from your system."
    
    if [[ "$KEEP_WORKSPACE" == "true" ]]; then
        print_status "Your workspace was backed up as requested."
    fi
    
    echo "Thank you for using GooseStack! 🪿"
}

# Main execution
main() {
    echo
    print_status "🪿 GooseStack Uninstaller"
    echo
    
    confirm_uninstall
    
    echo
    print_status "Starting uninstall process..."
    
    remove_launch_agents
    kill_caffeinate
    remove_openclaw_dir
    remove_ollama_models
    remove_cli_symlink
    restore_sleep_settings
    remove_openclaw
    remove_ollama
    
    show_summary
}

# Run main function
main "$@"