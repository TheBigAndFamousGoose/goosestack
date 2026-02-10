# MEMORY.md - Long-Term Memory

*This file contains your agent's curated long-term memories. It's only loaded in private chats with you.*

## Setup & Configuration

**Installation Date:** $(date +"%Y-%m-%d")  
**GooseStack Version:** v0.1 MVP  
**Initial Persona:** {{GOOSE_AGENT_PERSONA:-partner}}  

## Important Decisions

<!-- Record significant choices and the reasoning behind them -->

### System Preferences
- Chose {{GOOSE_AGENT_PERSONA:-partner}} persona for collaborative style
- $([[ -n "${GOOSE_API_KEY:-}" ]] && echo "Configured Anthropic API for premium models" || echo "Using local models only")
- $([[ "${GOOSE_TELEGRAM_ENABLED:-false}" == "true" ]] && echo "Telegram integration enabled" || echo "Telegram integration disabled")

## Lessons Learned

<!-- Mistakes to avoid, what works well, insights gained -->

### Technical Notes
- System runs {{GOOSE_OLLAMA_MODEL:-qwen2.5:7b}} model optimized for {{GOOSE_RAM_GB:-8}}GB RAM
- Local embeddings configured for privacy-focused memory search
- Auto-start configured via macOS LaunchAgent

## Key Context

<!-- Personal info, ongoing projects, important relationships -->

### Preferences
*To be filled in through conversations*

### Projects  
*Active and upcoming projects will be tracked here*

### Goals
*Short and long-term objectives*

## Recurring Themes

<!-- Patterns in conversations, frequently discussed topics -->

## Relationship Notes

<!-- How we work together, communication preferences -->

## Archive

<!-- Old information that might still be relevant -->

---

*This memory grows and evolves through our interactions. It helps maintain continuity and context across sessions.*