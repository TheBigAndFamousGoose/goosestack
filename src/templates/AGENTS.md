# AGENTS.md - Your AI Agent Workspace

Welcome to your personal AI agent! This is your workspace - treat it like home.

## First Run

If `BOOTSTRAP.md` exists, follow it completely before doing anything else. It's your one-time setup flow. Delete it when done.

## Getting Started

Your agent reads these files every session:

1. **SOUL.md** — Who your agent is (personality, style, behavior)
2. **USER.md** — Who you are (preferences, context, background)
3. **Today's memory** — `memory/YYYY-MM-DD.md` for recent context
4. **MEMORY.md** — Long-term memories (loaded in private chats only)

## Memory System

Your agent has two types of memory:

### Daily Memory: `memory/YYYY-MM-DD.md`
- Raw logs of conversations and events
- Automatically created each day
- Used for recent context and continuity

### Long-Term Memory: `MEMORY.md`
- Curated insights, lessons learned, important decisions
- Only loaded in direct chats with you (privacy protection)
- Updated by your agent during quiet moments

## Daily Logging Best Practices

Your agent should maintain detailed daily logs to preserve context across sessions:

### What to Log in `memory/YYYY-MM-DD.md`:

**Important decisions made:**
- Project choices, direction changes
- Tool preferences, workflow changes
- Problem-solving approaches that worked

**Key context and discoveries:**
- New information about you or your preferences
- Technical solutions and workarounds
- Useful resources or contacts discovered

**Significant events:**
- Major tasks completed or started
- Meetings, calls, or important conversations
- System changes or new tool setups

**Lessons learned:**
- What worked well, what didn't
- Mistakes to avoid next time
- Process improvements identified

### Session Startup Routine:

Every session, your agent should automatically:
1. Read today's log (`memory/YYYY-MM-DD.md`) for current context
2. Read yesterday's log for recent continuity
3. Check if any important items should move to long-term memory

### Conversation Storage:

**Note:** Full conversation transcripts are automatically stored in JSONL format by OpenClaw. Daily logs should focus on:
- Key insights and decisions from conversations
- Action items and follow-ups
- Context that will matter later
- Not verbatim chat logs (already preserved elsewhere)

## Sub-Agents

When you spawn a sub-agent, **wait for it to finish before responding.** Don't write a fallback response while it's working — it will return with results. Be patient. If a sub-agent takes more than 2 minutes, then you can mention it's still working.

## Key Behaviors

**Your agent will:**
- Read workspace files automatically each session
- Remember important things by writing them down
- Be proactive during heartbeat checks
- Respect your privacy in group settings
- Ask before taking actions that leave your computer

**In group chats, your agent:**
- Participates naturally, doesn't dominate
- Uses emoji reactions when appropriate
- Stays quiet when humans are just chatting
- Never shares your private information

## Customization

**SOUL.md** - Edit this to change your agent's personality
**USER.md** - Update with your preferences and context
**TOOLS.md** - Add notes about your specific setup
**HEARTBEAT.md** - Set up periodic tasks and reminders

## Data Safety

Your conversations and memories are stored locally:

### Storage Locations:
- **Conversations:** `~/.openclaw/agents/main/sessions/*.jsonl`
  - Full conversation transcripts in JSON Lines format
  - Automatically saved by OpenClaw for continuity
  
- **Memory Files:** Your workspace directory
  - Daily logs: `memory/YYYY-MM-DD.md`
  - Long-term memory: `MEMORY.md`
  - Configuration: `SOUL.md`, `USER.md`, etc.

### Backup Recommendations:
Create periodic backups to protect your data:

```bash
# Quick backup with timestamp
cp -R ~/.openclaw ~/.openclaw-backup-$(date +%Y%m%d)

# Or backup just the important parts
tar -czf ~/openclaw-backup-$(date +%Y%m%d).tar.gz ~/.openclaw/workspace ~/.openclaw/agents
```

### Privacy Notes:
- All data stays on your machine by default
- Conversation data is never sent to external services without explicit API calls
- Memory files are only loaded in appropriate contexts (MEMORY.md only in private chats)
- You control what gets shared when using external AI models

## Safety

Your agent is designed to:
- Never run destructive commands without asking
- Keep your private data secure
- Ask for permission before sending external messages
- Use `trash` instead of `rm` when possible

---

*This is your agent's home base. Make it yours!*