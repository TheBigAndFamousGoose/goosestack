# GooseStack 🪿

**One-command macOS installer for your personal AI agent.**

```bash
curl -fsSL https://goosestack.com/install.sh | bash
```

## What It Does

GooseStack detects your hardware and sets up a fully configured AI agent in minutes:

- 🧠 **AI Agent** — [OpenClaw](https://openclaw.ai)-powered, with memory, search, and personality
- 🏠 **Local Models** — Ollama with hardware-optimized model selection
- 🌐 **Web Dashboard** — Chat interface at `localhost:18789`
- 📱 **Telegram** — Optional bot integration
- 🔒 **Privacy First** — Everything runs on your Mac, your data stays local
- ⚡ **Auto-Start** — LaunchAgent runs on login, watchdog keeps it alive
- 🔍 **Local Memory** — Privacy-focused embeddings, zero API cost

## Requirements

- **macOS 13+** (Ventura or newer)
- **8GB+ RAM** (16GB+ recommended)
- **15GB free disk space**
- Apple Silicon (M1/M2/M3/M4) or Intel

## Quick Start

```bash
# 1. Install
curl -fsSL https://goosestack.com/install.sh | bash

# 2. Chat — dashboard opens automatically
open http://localhost:18789
```

The interactive wizard will ask you to:
- Name your agent and pick a personality
- Optionally add an API key (BYOK) or use local models
- Optionally connect Telegram

## GooseStack API (Optional)

Use cloud models through the GooseStack proxy — no key management needed:

| | Free | Pro ($10/mo) |
|---|---|---|
| Installer + local models | ✅ | ✅ |
| BYOK (bring your own keys) | ✅ | ✅ |
| GooseStack API (prepaid credits) | ✅ | ✅ |
| Token Router (smart model routing) | — | ✅ |
| Multi-provider proxy (Anthropic, OpenAI, Gemini) | — | ✅ |
| Priority support | — | ✅ |

**Token Router** analyzes request complexity and routes to the optimal model automatically. Simple tasks use cheap models, complex tasks use premium ones. You only pay for what you need.

→ [goosestack.com](https://goosestack.com) for pricing and dashboard

## Personalities

Choose during setup:

- **👔 Assistant** — Professional, task-focused
- **🤝 Partner** — Collaborative, casual
- **⚡ Coder** — Technical, direct
- **🎨 Creative** — Witty, expressive

## Management

```bash
# Status & health check
~/.openclaw/manage-gateway.sh status

# Restart / stop
~/.openclaw/manage-gateway.sh restart
~/.openclaw/manage-gateway.sh stop

# Logs
~/.openclaw/manage-gateway.sh logs

# Uninstall
goosestack uninstall
```

## File Locations

| File | Purpose |
|---|---|
| `~/.openclaw/openclaw.json` | Agent config |
| `~/.openclaw/workspace/SOUL.md` | Personality |
| `~/.openclaw/workspace/USER.md` | Your preferences |
| `~/.openclaw/workspace/MEMORY.md` | Agent's long-term memory |
| `~/.openclaw/logs/` | Gateway logs |

## Troubleshooting

**Gateway not responding:**
```bash
~/.openclaw/manage-gateway.sh restart
```

**Model errors:**
```bash
ollama list
ollama run qwen2.5:7b "test"
```

**Shell not finding commands:**
```bash
source ~/.zprofile
```

**More help:** [goosestack.com/docs](https://goosestack.com/docs) · [GitHub Issues](https://github.com/TheBigAndFamousGoose/goosestack/issues)

## License

MIT — see [LICENSE](LICENSE)

---

**Built with 🪿 by GooseStack**
