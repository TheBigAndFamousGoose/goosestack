# AGENTS.md - Your AI Agent Workspace

Welcome to your personal AI agent! This is your workspace - treat it like home.

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

## Safety

Your agent is designed to:
- Never run destructive commands without asking
- Keep your private data secure
- Ask for permission before sending external messages
- Use `trash` instead of `rm` when possible

---

*This is your agent's home base. Make it yours!*