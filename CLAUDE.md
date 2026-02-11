# CLAUDE.md — GooseStack

GooseStack is a one-command macOS installer for AI agent environments.

## Install
```bash
curl -fsSL https://goosestack.dev/install.sh | sh
```

## What It Installs
1. Homebrew (package manager)
2. Node.js (runtime)
3. OpenClaw (AI agent platform)
4. Ollama (local LLM server)
5. Optimal local model (auto-selected for hardware)

## Key Features
- Hardware auto-detection and optimization (Apple Silicon + Intel)
- BYOK or GooseStack Proxy API (prepaid credits, 40% markup)
- Local embeddings and memory search (private, no cloud)
- ClawSec security suite (file integrity, automated audits)
- Always-on watchdog with auto-restart
- Web dashboard with chat, config, logs, security tabs

## Architecture
Pure bash installer (~5K lines), no dependencies needed to run.
Interactive wizard: name, persona, API key, integrations.
Supports macOS 13+ with 8GB+ RAM.

## Links
- GitHub: https://github.com/TheBigAndFamousGoose/goosestack
- Website: https://goosestack.dev
- License: MIT
