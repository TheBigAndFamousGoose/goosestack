# GooseStack Dashboard

A self-contained web UI that provides a control panel for your AI agent after GooseStack installation.

## Features

### 🚀 Status Overview
- Real-time agent status monitoring
- Uptime tracking
- Model information display  
- Memory search status
- Current session info
- Daily message and token usage stats

### 💬 Chat Interface  
- Direct chat with your AI agent
- Clean message bubbles (user right, agent left)
- Sends messages via OpenClaw gateway API
- Real-time responses

### ⚙️ Configuration Display
- Read-only view of current settings
- Model and thinking mode info
- Workspace path
- Connected channels (Telegram, etc.)

### 📝 Live Logs
- Recent gateway log entries
- Auto-refresh every 10 seconds
- Color-coded by level (error=red, warn=yellow, info=gray)

### 🔒 Security Status
- ClawSec installation status
- Soul guardian status
- Last audit results
- File integrity checker

## Design

- **Dark theme** matching the GooseStack landing page (#0a0a0a background, #FF4500 accent)
- **Mobile responsive** design
- **Self-contained** - all CSS/JS inline, no external dependencies
- **Real-time updates** via WebSocket when available
- **Graceful degradation** if gateway is down

## Usage

### Start the Dashboard Server

```bash
# From the dashboard directory
./server.sh

# Or from anywhere (after installation)
~/.openclaw/dashboard-start.sh
```

The dashboard will be available at: **http://localhost:3721**

### First Time Setup

1. Open http://localhost:3721 in your browser
2. Enter your OpenClaw gateway token when prompted
3. The token is stored in localStorage for future sessions

### Gateway Token

Your gateway token can be found in `~/.openclaw/.gateway-token` or by checking the OpenClaw configuration.

## Technical Details

- **Port**: 3721 (to avoid conflicts with other services)
- **Gateway API**: Connects to localhost:18789 
- **Real-time**: Uses WebSocket when available, falls back to polling
- **Authentication**: Uses OpenClaw gateway token stored in localStorage
- **Self-contained**: Single HTML file with embedded CSS/JavaScript

## File Structure

```
dashboard/
├── index.html     # Main dashboard (self-contained)
├── server.sh      # Simple HTTP server script
└── README.md      # This file
```

## API Endpoints Used

The dashboard connects to these OpenClaw gateway endpoints:

- `GET /api/status` - Agent status and stats
- `GET /api/config` - Configuration display  
- `GET /api/logs` - Recent log entries
- `GET /api/security` - Security status
- `POST /hooks/agent` - Send messages to agent
- `WS /ws` - Real-time updates (optional)

## Integration

The dashboard is automatically:
- Copied to `~/.openclaw/dashboard/` during GooseStack installation
- Mentioned in health checks
- Available via quick-start script

## Browser Compatibility

Works in all modern browsers. Tested with:
- Chrome/Chromium
- Firefox  
- Safari
- Edge

No Internet connection required - runs entirely locally.