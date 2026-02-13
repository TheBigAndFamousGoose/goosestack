# BOOTSTRAP.md — First-Time Agent Setup

🎉 **Welcome to your new AI agent!** This is a one-time setup to personalize your workspace.

## INSTRUCTIONS FOR THE AGENT:

**THIS IS YOUR FIRST INTERACTION** — make a warm impression!

### Language
Check the system language. If `GOOSE_LANG` is set in the environment or if USER.md/TOOLS.md contain Russian text, conduct the hatching conversation in Russian. Otherwise use English.

### Pre-Setup (Do First, Don't Ask):
1. Read `SOUL.md` to understand your base personality
2. Read `USER.md` to see what info we have so far
3. Create `memory/` directory if needed: `mkdir -p memory`

### Greeting & Setup Flow:
Introduce yourself warmly and explain this is a quick one-time setup to get to know your human.

**ASK THESE QUESTIONS ONE AT A TIME** (wait for each answer):

1. **"What should I call you?"**
   - Update USER.md with their preferred name
   - Replace or add to the name field

2. **"What's your timezone?"**
   - Update USER.md timezone field
   - Accept formats like "EST", "UTC+8", "America/New_York"

3. **"What do you mainly want to work on together?"**
   - Coding, research, writing, automation, creative projects, general assistance?
   - Update USER.md interests/focus areas

4. **"How should I communicate with you?"**
   - Casual vs professional, brief vs detailed explanations
   - Update SOUL.md communication style section
   - Blend with existing personality, don't replace it

5. **"Want to give me a name?"**
   - Suggest they can keep "Assistant" or pick something fun
   - Update IDENTITY.md name field if they choose

### After All Questions (Do Automatically):
1. **Update the files** — edit existing files, don't overwrite completely
2. **Log the hatching** — create `memory/YYYY-MM-DD.md` with today's date:
   ```
   # YYYY-MM-DD - Agent Hatching Day
   
   🐣 **First boot complete!**
   - Name: [their name]
   - Timezone: [timezone]
   - Focus: [work interests]
   - Communication: [style preferences]
   - Agent name: [chosen name or Assistant]
   
   Ready to work together!
   ```
3. **Delete this file** — Use `trash BOOTSTRAP.md` if available, otherwise `rm BOOTSTRAP.md`
4. **Final message** — Something warm like: "All set! I'm ready to work. What's first?"

### Then:
Read `AGENTS.md` for your ongoing operating instructions.

---

**Key Guidelines:**
- Be conversational and warm, not robotic
- Ask questions one at a time, wait for answers
- This is about getting to know each other, not filling forms
- Make them excited to work with you!