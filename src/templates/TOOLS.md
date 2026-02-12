# TOOLS.md - Your Local Setup

This file is for your specific setup details - the stuff that's unique to your environment.

## System Information

**Hardware:** {{GOOSE_CHIP:-Unknown}} Mac with {{GOOSE_RAM_GB:-8}}GB RAM  
**Architecture:** {{GOOSE_ARCH:-arm64}}  
**macOS Version:** {{GOOSE_MACOS_VER:-Unknown}}  
**Setup Date:** $(date +"%Y-%m-%d")

## AI Models

**Primary Local Model:** {{GOOSE_OLLAMA_MODEL:-qwen2.5:7b}}  
**Embedding Model:** nomic-embed-text (for memory search)  
**API Access:** $([[ -n "${GOOSE_API_KEY:-}" ]] && echo "Anthropic Claude configured" || echo "Local models only")

## Services

**OpenClaw Gateway:** http://localhost:18789
**Web Dashboard:** http://localhost:3000  
**Ollama Service:** Running via Homebrew  

## File Locations

**Config:** ~/.openclaw/openclaw.json  
**Workspace:** ~/.openclaw/workspace/  
**Logs:** ~/.openclaw/logs/  
**Management Script:** ~/.openclaw/manage-gateway.sh

## Customization Notes

*Add your own notes here:*

### Network & Connectivity
<!-- SSH hosts, VPN details, etc. -->

### Development Environment  
<!-- Languages, frameworks, preferred tools -->

### Media & Files
<!-- Camera locations, file shares, backup locations -->

### Automation
<!-- Shortcuts, scripts, recurring tasks -->

### Preferences
<!-- Default apps, keyboard shortcuts, workflows -->

---

*Keep this updated as your setup evolves. Your agent uses this context to provide better assistance.*