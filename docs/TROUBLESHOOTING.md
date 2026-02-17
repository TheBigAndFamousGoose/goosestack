# GooseStack Troubleshooting Guide

Things not working? You're in the right place. This guide covers the real issues people actually hit — and how to fix them fast.

**Quick context:** GooseStack automatically optimizes your AI costs behind the scenes — you don't need to do anything. Just use your agent normally.

---

## 🔧 Installation Issues

### Installer hangs or prompts don't work

**What happens:** You ran `curl -fsSL ... | sh` and the installer freezes at a prompt or behaves weirdly.

**Why:** When you pipe curl into sh, stdin is the download stream — so the script can't read your keyboard input.

**Fix:** Use process substitution instead:
```bash
bash <(curl -fsSL https://...)
```
Or download first, then run:
```bash
curl -fsSL https://... -o install.sh && bash install.sh
```

### Installer seems outdated after a fresh push

GitHub's raw CDN caches files aggressively. If we just pushed an update, you might get the old version for up to 5 minutes. Wait a bit and retry, or download the file directly from the GitHub repo page (not the raw URL).

### "Reset workspace files?" on reinstall

If GooseStack detects an existing installation, it'll ask whether to reset workspace files. **Say NO** unless you want a clean slate. Saying yes wipes your agent's personality (SOUL.md), memory, and customizations. Your agent literally forgets who it is.

### ClawSec suite fails to install

`npx clawhub@latest install clawsec-suite` can be flaky. Don't worry — this is **completely non-blocking**. Your agent works fine without it. Just retry later:
```bash
npx clawhub@latest install clawsec-suite
```

### Homebrew takes forever

First-time Homebrew installation on a fresh Mac genuinely takes 10–15 minutes. It's downloading Xcode Command Line Tools, cloning the tap repos, etc. Go make coffee. This is normal.

---

## 🌐 Proxy & API Issues

### "No API provider registered for api: undefined"

Your config is missing a required field. Open `~/.openclaw/openclaw.json` and make sure the provider section includes all three fields:

```json
{
  "api": "anthropic-messages",
  "baseUrl": "https://your-proxy-url",
  "apiKey": "your-key"
}
```

The `"api": "anthropic-messages"` part is what people usually forget.

### Blocked by region (403 errors, connection refused)

Anthropic geo-blocks certain regions (Russia, others). If you're in an affected area, **use GooseStack's proxy mode** (Pro plan) — it routes through our NL server automatically. BYOK (bring-your-own-key) mode connects directly to Anthropic, so it'll get blocked.

### Agent responds but has no personality

The provider in your config **must** be registered with the name `"anthropic"` — not a custom name like `"my-claude"` or `"proxy"`. OpenClaw only injects workspace files (SOUL.md, AGENTS.md, etc.) when it sees the provider named `"anthropic"`. If your agent sounds generic and robotic, this is almost certainly why.

### Thinking-related errors

If you see errors about thinking/extended thinking, your proxy version may be outdated. Update to the latest GooseStack release — the proxy handles thinking compatibility automatically.

---

## 🤖 Agent Behavior

### Bootstrap / hatching doesn't trigger on first run

Your agent should read `BOOTSTRAP.md` automatically on its first conversation. If it doesn't:

1. Check that `SOUL.md` contains the `⚠️ FIRST RUN` trigger section
2. Make sure `BOOTSTRAP.md` exists in the workspace
3. Send **"hi"** as your first message — this kicks off the bootstrap flow

### Agent seems expensive

GooseStack automatically optimizes which model handles each message to keep costs down. If costs still seem high, you're probably doing a lot of complex work — which genuinely needs the best model. That's working as intended.

### Agent can't search the web

- **Proxy users:** Brave Search works out of the box. Nothing to configure.
- **BYOK users:** You need to add your own Brave Search API key:

```json
{
  "services": {
    "braveSearch": {
      "apiKey": "your-brave-api-key"
    }
  }
}
```

### Sub-agents not spawning

- **Proxy users:** Sub-agents route through Sonnet automatically. Should just work.
- **BYOK users:** You need `subagentModel` configured in your `openclaw.json`. Without it, the agent can't spawn helpers.

---

## 🖥️ System Issues

### Gateway won't start or crashes

First, check status:
```bash
openclaw gateway status
```

Look at the logs for clues:
```bash
ls ~/.openclaw/logs/
# then read the latest log file
```

Usually a restart fixes it:
```bash
openclaw gateway restart
```

### Agent goes offline / macOS puts machine to sleep

GooseStack configures your Mac to stay awake during install (via `caffeinate` and `pmset`). If your agent is going offline randomly, check that sleep is actually disabled:

```bash
pmset -g
```

Look for `displaysleep` and `sleep` — both should be `0`. If not, the sleep prevention didn't stick. Re-run the sleep settings or set manually:
```bash
sudo pmset -a displaysleep 0 sleep 0
```

### Watchdog not running (gateway doesn't auto-restart)

The watchdog is a LaunchAgent that monitors and restarts the gateway. Check if it's loaded:

```bash
launchctl list | grep goosestack
```

If nothing shows up, reload it:
```bash
launchctl load ~/Library/LaunchAgents/com.goosestack.watchdog.plist
```

---

## Still stuck?

If none of the above helps, grab your logs (`~/.openclaw/logs/`) and config (`~/.openclaw/openclaw.json` — redact your API key!) and reach out. The more context you share, the faster we can help.
