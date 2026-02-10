# GooseStack 🦆

**One-command macOS installer for your personal AI agent environment.**

```bash
curl -fsSL https://goosestack.dev/install.sh | sh
```

<pre>
     ____                      ____  _             _    
    / ___| ___   ___  ___  ___/ ___|| |_ __ _  ___| | __
   | |  _ / _ \ / _ \/ __|/ _ \___ \| __/ _` |/ __| |/ /
   | |_| | (_) | (_) \__ \  __/___) | || (_| | (__|   < 
    \____|\___/ \___/|___/\___|____/ \__\__,_|\___|_|\_\
                                                        
    🦆 One-Command AI Agent Setup for macOS
</pre>

## What It Does

GooseStack automatically installs and configures:

- ✅ **Homebrew** - macOS package manager
- ✅ **Node.js** - JavaScript runtime  
- ✅ **OpenClaw** - AI agent framework
- ✅ **Ollama** - Local AI models
- ✅ **Optimized Models** - Selected based on your RAM
- ✅ **Auto-Start Service** - Runs on login via LaunchAgent
- ✅ **Web Dashboard** - Chat interface at http://localhost:3000
- ✅ **Local Memory Search** - Privacy-focused embeddings
- ✅ **Telegram Integration** - Optional bot connection

## Features

### 🎯 **Intelligent Setup**
- Detects your Mac's chip (M1/M2/M3/M4/Intel) and RAM
- Installs optimal AI model for your hardware
- Applies performance optimizations automatically

### 🧠 **Smart AI Agent** 
- Reads workspace files to understand you and your preferences
- Maintains conversation history and long-term memory
- Proactive heartbeat system for periodic check-ins
- Local embeddings for privacy-focused memory search

### ⚡ **Ready to Use**
- Web dashboard opens automatically after install
- Pre-configured with sensible defaults
- Management scripts for easy service control
- Comprehensive health checks

### 🔒 **Privacy First**
- All AI processing runs locally by default
- Optional API key for premium models
- Memory and embeddings stored on your machine
- No data sent to external services without your consent

## Requirements

- **macOS 13.0+** (Ventura or newer)
- **8GB+ RAM** (16GB+ recommended for best performance)
- **15GB free disk space** (for models and dependencies)
- **Internet connection** (for initial download)

## Quick Start

1. **Install GooseStack:**
   ```bash
   curl -fsSL https://goosestack.dev/install.sh | sh
   ```

2. **Chat with your agent:**
   - Dashboard opens automatically at http://localhost:3000
   - Or visit it manually in your browser

3. **Try these commands:**
   - "What can you help me with?"
   - "Show me my workspace files"
   - "What's my system information?"

## Configuration

### Personalities

Choose your agent's personality during setup:

- **👔 Assistant** - Professional, formal, task-focused
- **🤝 Partner** - Collaborative, casual, team-oriented  
- **⚡ Coder** - Technical, direct, development-focused
- **🎨 Creative** - Witty, expressive, imaginative

### API Keys

**Local-First:** Works great with local models only (no API key needed)

**Premium Models:** Add an Anthropic API key for Claude access:
- Get one at: https://console.anthropic.com/
- Edit: `~/.openclaw/openclaw.json` 
- Restart: `~/.openclaw/manage-gateway.sh restart`

### Telegram Integration

Enable during setup or add later:
1. Message @BotFather on Telegram
2. Send: `/newbot`
3. Copy your bot token
4. Add to `~/.openclaw/openclaw.json`

## Management

### Service Control
```bash
# Check status
~/.openclaw/manage-gateway.sh status

# Restart service  
~/.openclaw/manage-gateway.sh restart

# View logs
~/.openclaw/manage-gateway.sh logs

# Stop service
~/.openclaw/manage-gateway.sh stop
```

### File Locations
- **Config:** `~/.openclaw/openclaw.json`
- **Workspace:** `~/.openclaw/workspace/`
- **Logs:** `~/.openclaw/logs/`
- **LaunchAgent:** `~/Library/LaunchAgents/ai.openclaw.gateway.plist`

### Customization
Edit these files to customize your agent:

- **`SOUL.md`** - Agent personality and behavior
- **`USER.md`** - Your info and preferences  
- **`TOOLS.md`** - Your specific setup details
- **`HEARTBEAT.md`** - Periodic tasks and reminders

## Troubleshooting

### Installation Issues

**"Command not found" errors:**
```bash
# Reload your shell profile
source ~/.zprofile
```

**Permission denied:**
```bash
# Don't use sudo! Install as regular user
./install.sh
```

**Ollama won't start:**
```bash
# Check Homebrew services
brew services list | grep ollama
brew services restart ollama
```

### Service Issues  

**Gateway not responding:**
```bash
# Check status and restart
~/.openclaw/manage-gateway.sh status
~/.openclaw/manage-gateway.sh restart
```

**Dashboard won't load:**
```bash
# Verify ports are free
lsof -i :3000 -i :3721
```

**Model errors:**
```bash
# Verify model is available
ollama list
ollama run qwen2.5:7b "test"
```

### Getting Help

- **📖 Documentation:** Full guides at [goosestack.dev/docs](https://goosestack.dev/docs)
- **🐛 Bug Reports:** [GitHub Issues](https://github.com/openclaw-dev/goosestack/issues)
- **💬 Community:** [Discord Server](https://discord.gg/openclaw)
- **✉️  Email:** support@goosestack.dev

## Development

### Local Development
```bash
git clone https://github.com/openclaw-dev/goosestack.git
cd goosestack
./install.sh
```

### Testing
```bash
# Syntax check
bash -n install.sh

# Dry run (check but don't install)
GOOSE_DRY_RUN=1 ./install.sh
```

## License

MIT License - see [LICENSE](LICENSE) for details.

---

**Made with ❤️  by the OpenClaw community**

*Transform your Mac into an AI-powered productivity machine in just one command.*