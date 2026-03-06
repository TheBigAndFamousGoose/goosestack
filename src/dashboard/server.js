const express = require('express');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const multer = require('multer');
const { v4: uuidv4 } = require('uuid');
const db = require('./db');

const app = express();
const PORT = 3333;

const DATA_DIR = path.join(__dirname, 'data');
const TEAM_FILE = path.join(DATA_DIR, 'team.json');
const SETTINGS_FILE = path.join(DATA_DIR, 'settings.json');
const UPLOADS_DIR = path.join(__dirname, 'uploads');
const MEMORY_DIR = process.env.MEMORY_DIR || path.join(require('os').homedir(), '.openclaw', 'workspace', 'memory');
const WORKSPACE_DIR = path.join(require('os').homedir(), '.openclaw', 'workspace');
const OPENCLAW_CONFIG = path.join(process.env.HOME, '.openclaw', 'openclaw.json');
const AUTH_PROFILES_FILE = path.join(process.env.HOME, '.openclaw', 'agents', 'main', 'agent', 'auth-profiles.json');

// Ensure directories exist
fs.mkdirSync(DATA_DIR, { recursive: true });
fs.mkdirSync(UPLOADS_DIR, { recursive: true });

// Ensure settings.json exists
if (!fs.existsSync(SETTINGS_FILE)) {
  fs.writeFileSync(SETTINGS_FILE, JSON.stringify({ columnNames: {} }, null, 2), 'utf8');
}

// Initialize SQLite database
db.init();

// Simple encryption helpers for API key storage
const ENCRYPTION_KEY_FILE = path.join(DATA_DIR, '.keyfile');
function getEncryptionKey() {
  if (fs.existsSync(ENCRYPTION_KEY_FILE)) {
    return Buffer.from(fs.readFileSync(ENCRYPTION_KEY_FILE, 'utf8'), 'hex');
  }
  const key = crypto.randomBytes(32);
  fs.writeFileSync(ENCRYPTION_KEY_FILE, key.toString('hex'), 'utf8');
  return key;
}

function encryptValue(text) {
  if (!text) return '';
  const key = getEncryptionKey();
  const iv = crypto.randomBytes(16);
  const cipher = crypto.createCipheriv('aes-256-cbc', key, iv);
  let encrypted = cipher.update(text, 'utf8', 'hex');
  encrypted += cipher.final('hex');
  return iv.toString('hex') + ':' + encrypted;
}

function decryptValue(text) {
  if (!text) return text;
  // Encrypted values are hex IV (32 chars) + ':' + hex ciphertext
  const match = text.match(/^([0-9a-f]{32}):([0-9a-f]+)$/);
  if (!match) return text;
  try {
    const key = getEncryptionKey();
    const iv = Buffer.from(match[1], 'hex');
    const decipher = crypto.createDecipheriv('aes-256-cbc', key, iv);
    let decrypted = decipher.update(match[2], 'hex', 'utf8');
    decrypted += decipher.final('utf8');
    return decrypted;
  } catch {
    return text;
  }
}

function maskKey(key) {
  if (!key || key.length < 10) return key ? '••••••••' : '';
  return key.substring(0, 6) + '...' + key.substring(key.length - 4);
}

// OpenClaw config helpers
function readOpenClawConfig() {
  try {
    return JSON.parse(fs.readFileSync(OPENCLAW_CONFIG, 'utf8'));
  } catch {
    return {};
  }
}

function writeOpenClawConfig(config) {
  // Backup before writing
  if (fs.existsSync(OPENCLAW_CONFIG)) {
    fs.copyFileSync(OPENCLAW_CONFIG, OPENCLAW_CONFIG + '.bak');
  }
  fs.writeFileSync(OPENCLAW_CONFIG, JSON.stringify(config, null, 2), 'utf8');
}

// Mapping: provider name → OpenClaw auth profile key
const OPENCLAW_PROFILE_PROVIDERS = ['anthropic', 'openai', 'google', 'xai', 'groq'];

// Auth profiles helpers (separate file from openclaw.json)
function readAuthProfiles() {
  try {
    return JSON.parse(fs.readFileSync(AUTH_PROFILES_FILE, 'utf8'));
  } catch {
    return { version: 1, profiles: {} };
  }
}

function writeAuthProfiles(data) {
  if (fs.existsSync(AUTH_PROFILES_FILE)) {
    fs.copyFileSync(AUTH_PROFILES_FILE, AUTH_PROFILES_FILE + '.bak');
  }
  fs.writeFileSync(AUTH_PROFILES_FILE, JSON.stringify(data, null, 2), 'utf8');
}

function setKeyInOpenClawConfig(config, provider, key) {
  if (provider === 'brave') {
    if (!config.tools) config.tools = {};
    if (!config.tools.web) config.tools.web = {};
    if (!config.tools.web.search) config.tools.web.search = { provider: 'brave' };
    config.tools.web.search.apiKey = key;
  }
  return config;
}

// Track auto-reset timers for agent statuses
const agentResetTimers = {};

// Middleware
app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, 'public'), { etag: false, maxAge: 0 }));
app.use('/uploads', express.static(UPLOADS_DIR));

// Multer config for image uploads
const storage = multer.diskStorage({
  destination: (_req, _file, cb) => cb(null, UPLOADS_DIR),
  filename: (_req, file, cb) => {
    const ext = path.extname(file.originalname);
    const safeName = file.originalname
      .replace(ext, '')
      .replace(/[^a-zA-Z0-9_-]/g, '_')
      .substring(0, 50);
    cb(null, `${Date.now()}-${safeName}${ext}`);
  },
});

const upload = multer({
  storage,
  limits: { fileSize: 20 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const allowedExt = /\.(jpg|jpeg|png|gif|webp|bmp)$/i;
    const allowedMime = ['image/jpeg', 'image/png', 'image/gif', 'image/webp', 'image/bmp'];
    if (allowedExt.test(path.extname(file.originalname)) && allowedMime.includes(file.mimetype)) {
      cb(null, true);
    } else {
      cb(new Error('Only image files are allowed'));
    }
  },
});

// Helpers
function safeReadJSON(filePath, fallback) {
  try {
    const raw = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    console.error(`Error reading ${filePath}:`, err.message);
    return fallback;
  }
}

function expandEventsForMonth(events, year, month) {
  const results = [];
  const daysInMonth = new Date(year, month, 0).getDate();

  for (const event of events) {
    if (!event.recurrence || event.recurrence === 'none') {
      // Parse date string directly to avoid timezone shifts
      const parts = (event.date || event.eventDate || '').split('-').map(Number);
      if (parts.length === 3 && parts[0] === year && parts[1] === month) {
        results.push(event);
      }
    } else if (event.recurrence === 'daily') {
      // Show on every day of the requested month (regardless of start date)
      for (let day = 1; day <= daysInMonth; day++) {
        const dateStr = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
        results.push({ ...event, id: `${event.id}__${dateStr}`, parentId: event.id, date: dateStr });
      }
    } else if (event.recurrence === 'weekly') {
      // Parse the event date string directly to get day-of-week
      const [sy, sm, sd] = (event.date || event.eventDate || '').split('-').map(Number);
      const startDate = new Date(sy, sm - 1, sd);
      const dayOfWeek = startDate.getDay();
      for (let day = 1; day <= daysInMonth; day++) {
        const d = new Date(year, month - 1, day);
        if (d.getDay() === dayOfWeek) {
          const dateStr = `${year}-${String(month).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
          results.push({ ...event, id: `${event.id}__${dateStr}`, parentId: event.id, date: dateStr });
        }
      }
    } else if (event.recurrence === 'monthly') {
      // Parse the event date string directly to get day-of-month
      const [, , sd] = (event.date || event.eventDate || '').split('-').map(Number);
      if (sd && sd <= daysInMonth) {
        const dateStr = `${year}-${String(month).padStart(2, '0')}-${String(sd).padStart(2, '0')}`;
        results.push({ ...event, id: `${event.id}__${dateStr}`, parentId: event.id, date: dateStr });
      }
    }
  }
  return results;
}

// New cleanupStaleRuns using db
function cleanupStaleRuns() {
  const { cleaned, timedOutAgents } = db.cleanupStaleRuns(30 * 60 * 1000);
  for (const agent of timedOutAgents) {
    db.updateAgentStatus(agent, { status: 'idle', task: '', details: '', lastUpdated: new Date().toISOString() });
  }
  if (cleaned > 0) console.log(`[cleanup] Timed out ${cleaned} stale run(s)`);
  return cleaned;
}

// --- API Routes ---

// List all cards
app.get('/api/cards', (_req, res) => {
  try {
    res.json(db.getCards());
  } catch (err) {
    res.status(500).json({ error: 'Failed to read cards' });
  }
});

// Get single card
app.get('/api/cards/:id', (req, res) => {
  try {
    const card = db.getCard(req.params.id);
    if (!card) return res.status(404).json({ error: 'Card not found' });
    res.json(card);
  } catch (err) {
    res.status(500).json({ error: 'Failed to read card' });
  }
});

// Create card
app.post('/api/cards', (req, res) => {
  try {
    const card = db.createCard({ ...req.body, id: uuidv4() });
    res.status(201).json(card);
  } catch (err) {
    res.status(500).json({ error: 'Failed to create card' });
  }
});

// Update card
app.put('/api/cards/:id', (req, res) => {
  try {
    const card = db.updateCard(req.params.id, req.body);
    if (!card) return res.status(404).json({ error: 'Card not found' });
    res.json(card);
  } catch (err) {
    res.status(500).json({ error: 'Failed to update card' });
  }
});

// Delete card
app.delete('/api/cards/:id', (req, res) => {
  try {
    // Get card first to clean up images if any
    const card = db.getCard(req.params.id);
    if (!card) return res.status(404).json({ error: 'Card not found' });

    // Clean up uploaded images if present
    if (card.imageUrl) {
      const filePath = path.join(UPLOADS_DIR, path.basename(card.imageUrl));
      if (fs.existsSync(filePath)) {
        fs.unlinkSync(filePath);
      }
    }

    if (!db.deleteCard(req.params.id)) return res.status(404).json({ error: 'Card not found' });
    res.json({ deleted: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete card' });
  }
});

// Upload image to card
app.post('/api/cards/:id/upload', upload.single('image'), (req, res) => {
  if (!req.file) return res.status(400).json({ error: 'No file uploaded' });

  const card = db.getCard(req.params.id);
  if (!card) {
    // Remove orphaned upload
    fs.unlinkSync(req.file.path);
    return res.status(404).json({ error: 'Card not found' });
  }

  const imageUrl = `/uploads/${req.file.filename}`;
  const updatedCard = db.updateCard(req.params.id, { imageUrl });
  res.json({ url: imageUrl, card: updatedCard });
});

// --- Task API Routes ---

// List all tasks
app.get('/api/tasks', (_req, res) => {
  try {
    res.json(db.getTasks());
  } catch (err) {
    res.status(500).json({ error: 'Failed to read tasks' });
  }
});

// IMPORTANT: specific routes before parametric to avoid shadowing
// Bulk archive all done tasks
app.post('/api/tasks/archive-all-done', (_req, res) => {
  try {
    const count = db.archiveAllDone();
    res.json({ archived: count });
  } catch (err) {
    res.status(500).json({ error: 'Failed to archive done tasks' });
  }
});

// Archive a single done task
app.post('/api/tasks/:id/archive', (req, res) => {
  try {
    const task = db.archiveTask(req.params.id);
    if (!task) return res.status(404).json({ error: 'Task not found' });
    res.json(task);
  } catch (err) {
    res.status(500).json({ error: 'Failed to archive task' });
  }
});

// Get single task
app.get('/api/tasks/:id', (req, res) => {
  try {
    const task = db.getTask(req.params.id);
    if (!task) return res.status(404).json({ error: 'Task not found' });
    res.json(task);
  } catch (err) {
    res.status(500).json({ error: 'Failed to read task' });
  }
});

// Create task
app.post('/api/tasks', (req, res) => {
  try {
    const task = db.createTask({ ...req.body, id: uuidv4() });
    res.status(201).json(task);
  } catch (err) {
    res.status(500).json({ error: 'Failed to create task' });
  }
});

// Update task
app.put('/api/tasks/:id', (req, res) => {
  try {
    const task = db.updateTask(req.params.id, req.body);
    if (!task) return res.status(404).json({ error: 'Task not found' });
    res.json(task);
  } catch (err) {
    res.status(500).json({ error: 'Failed to update task' });
  }
});

// Delete task
app.delete('/api/tasks/:id', (req, res) => {
  try {
    if (!db.deleteTask(req.params.id)) return res.status(404).json({ error: 'Task not found' });
    res.json({ deleted: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete task' });
  }
});

// --- Archive API Routes ---

// Get archived tasks with optional filters
app.get('/api/archive', (req, res) => {
  try {
    res.json(db.getArchivedTasks(req.query));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read archive' });
  }
});

// Restore an archived task back to active
app.post('/api/archive/:id/restore', (req, res) => {
  try {
    const task = db.restoreTask(req.params.id);
    if (!task) return res.status(404).json({ error: 'Archived task not found' });
    res.json(task);
  } catch (err) {
    res.status(500).json({ error: 'Failed to restore task' });
  }
});

// Permanently delete an archived task
app.delete('/api/archive/:id', (req, res) => {
  try {
    if (!db.deleteArchivedTask(req.params.id)) return res.status(404).json({ error: 'Archived task not found' });
    res.json({ deleted: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete archived task' });
  }
});

// --- Event API Routes ---

// List events (with optional month filter)
app.get('/api/events', (req, res) => {
  try {
    if (req.query.month) {
      const [year, month] = req.query.month.split('-').map(Number);
      if (!year || !month) return res.status(400).json({ error: 'Invalid month format. Use YYYY-MM' });
      const events = db.getEvents({});
      return res.json(expandEventsForMonth(events, year, month));
    }
    // Pass through any filters: agent, type, year, month (from individual query params)
    const filters = {};
    if (req.query.agent) filters.agent = req.query.agent;
    if (req.query.type) filters.type = req.query.type;
    if (req.query.year) filters.year = req.query.year;
    res.json(db.getEvents(filters));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read events' });
  }
});

// Get single event
app.get('/api/events/:id', (req, res) => {
  try {
    const event = db.getEvent(req.params.id);
    if (!event) return res.status(404).json({ error: 'Event not found' });
    res.json(event);
  } catch (err) {
    res.status(500).json({ error: 'Failed to read event' });
  }
});

// Create event
app.post('/api/events', (req, res) => {
  try {
    const event = db.createEvent({ ...req.body, id: uuidv4() });
    res.status(201).json(event);
  } catch (err) {
    res.status(500).json({ error: 'Failed to create event' });
  }
});

// Update event
app.put('/api/events/:id', (req, res) => {
  try {
    const event = db.updateEvent(req.params.id, req.body);
    if (!event) return res.status(404).json({ error: 'Event not found' });
    res.json(event);
  } catch (err) {
    res.status(500).json({ error: 'Failed to update event' });
  }
});

// Delete event
app.delete('/api/events/:id', (req, res) => {
  try {
    if (!db.deleteEvent(req.params.id)) return res.status(404).json({ error: 'Event not found' });
    res.json({ deleted: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to delete event' });
  }
});

// --- Office API Routes ---

const officeClients = []; // SSE clients

// Get all agent statuses
app.get('/api/office/status', (_req, res) => {
  try {
    res.json(db.getOfficeStatus());
  } catch (err) {
    res.status(500).json({ error: 'Failed to read office status' });
  }
});

// Update an agent's status
app.post('/api/office/status', (req, res) => {
  try {
    const { agent, status, task, details, model } = req.body;
    if (!agent) return res.status(400).json({ error: 'agent is required' });

    const now = new Date().toISOString();

    // Build log action text
    const actionText = status === 'working'
      ? `${agent} started ${task || 'a task'}`
      : status === 'completed'
        ? `${agent} completed ${task || 'a task'}`
        : status === 'error'
          ? `${agent} encountered an error${task ? ': ' + task : ''}`
          : `${agent} is now ${status}`;

    const logEntry = {
      agent,
      action: actionText,
      timestamp: now,
      status: status || 'idle',
    };

    db.transaction(() => {
      db.updateAgentStatus(agent, {
        status: status || 'idle',
        task: task !== undefined ? task : '',
        details: details !== undefined ? details : '',
        model: model || '',
        lastUpdated: now,
      });
      db.appendOfficeLog(logEntry);
    });

    // Get updated agent status for response
    const allStatus = db.getOfficeStatus();
    const agentStatus = allStatus[agent];

    // Push to SSE clients
    const sseData = JSON.stringify({ type: 'status', agent: agentStatus, log: { ...logEntry, time: now } });
    officeClients.forEach(client => {
      try { client.res.write(`data: ${sseData}\n\n`); } catch (e) {}
    });

    // Auto-reset completed/error statuses back to idle
    const resetDelay = status === 'completed' ? 5000 : status === 'error' ? 10000 : 0;
    if (resetDelay) {
      if (agentResetTimers[agent]) clearTimeout(agentResetTimers[agent]);
      agentResetTimers[agent] = setTimeout(() => {
        delete agentResetTimers[agent];
        db.updateAgentStatus(agent, {
          status: 'idle',
          task: '',
          lastUpdated: new Date().toISOString(),
        });
        const current = db.getOfficeStatus();
        const resetData = JSON.stringify({ type: 'status', agent: current[agent] });
        officeClients.forEach(client => {
          try { client.res.write(`data: ${resetData}\n\n`); } catch (e) {}
        });
      }, resetDelay);
    }

    res.json(agentStatus || { agent, status, task, details });
  } catch (err) {
    res.status(500).json({ error: 'Failed to update office status' });
  }
});

// SSE stream for real-time updates
app.get('/api/office/stream', (req, res) => {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream',
    'Cache-Control': 'no-cache',
    Connection: 'keep-alive',
    'X-Accel-Buffering': 'no',
  });
  // Send initial SSE comment to establish connection
  res.write(':ok\n\n');

  const clientId = Date.now();
  // Heartbeat every 30s to keep connection alive
  const heartbeat = setInterval(() => {
    res.write(':ping\n\n');
  }, 30000);

  const client = { id: clientId, res };
  officeClients.push(client);

  req.on('close', () => {
    clearInterval(heartbeat);
    const idx = officeClients.findIndex(c => c.id === clientId);
    if (idx !== -1) officeClients.splice(idx, 1);
  });
});

// Get recent activity log
app.get('/api/office/log', (req, res) => {
  try {
    res.json(db.getOfficeLog(parseInt(req.query.limit) || 200));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read office log' });
  }
});

// Post to activity log
app.post('/api/office/log', (req, res) => {
  try {
    db.appendOfficeLog(req.body);
    res.json({ ok: true });
  } catch (err) {
    res.status(500).json({ error: 'Failed to append log' });
  }
});

// --- Agent Logs API Routes ---
const AGENT_LOGS_DIR = path.join(DATA_DIR, 'agent-logs');
if (!fs.existsSync(AGENT_LOGS_DIR)) fs.mkdirSync(AGENT_LOGS_DIR, { recursive: true });

// List agent logs (optionally filter by ?agent=claude&limit=20)
app.get('/api/agent-logs', (req, res) => {
  try {
    const files = fs.readdirSync(AGENT_LOGS_DIR)
      .filter(f => f.endsWith('.log'))
      .sort()
      .reverse();
    const agent = req.query.agent ? req.query.agent.toLowerCase() : null;
    const limit = parseInt(req.query.limit) || 50;
    // Parse all logs first, then filter by agent name (matches display name, CLI name, or filename)
    const allLogs = files.map(f => {
      const content = fs.readFileSync(path.join(AGENT_LOGS_DIR, f), 'utf8');
      const lines = content.split('\n');
      const agentLine = lines.find(l => l.startsWith('Agent:'));
      const promptLine = lines.find(l => l.startsWith('Prompt:'));
      const startedLine = lines.find(l => l.startsWith('Started:'));
      const finishedLine = lines.find(l => l.startsWith('Finished:'));
      const exitLine = lines.find(l => l.startsWith('Exit code:'));
      const agentName = agentLine ? agentLine.replace('Agent: ', '') : f.split('-')[0];
      return {
        filename: f,
        agent: agentName,
        cli: f.split('-')[0],
        prompt: promptLine ? promptLine.replace('Prompt: ', '') : '',
        started: startedLine ? startedLine.replace('Started: ', '') : '',
        finished: finishedLine ? finishedLine.replace('Finished: ', '') : '',
        exitCode: exitLine ? parseInt(exitLine.replace('Exit code: ', '')) : null,
        size: content.length,
        lines: lines.length,
      };
    });
    // Filter: match against agent display name, CLI name, or filename prefix (bidirectional)
    const filtered = agent
      ? allLogs.filter(l => {
          const a = l.agent.toLowerCase();
          const c = l.cli.toLowerCase();
          return a.includes(agent) || agent.includes(a) ||
                 c.includes(agent) || agent.includes(c) ||
                 l.filename.toLowerCase().startsWith(agent);
        })
      : allLogs;
    res.json(filtered.slice(0, limit));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read agent logs' });
  }
});

// Get a specific agent log file content
app.get('/api/agent-logs/:filename', (req, res) => {
  try {
    const safeName = path.basename(req.params.filename);
    const logPath = path.join(AGENT_LOGS_DIR, safeName);
    if (!fs.existsSync(logPath)) return res.status(404).json({ error: 'Log not found' });
    const content = fs.readFileSync(logPath, 'utf8');
    // Support ?tail=100 to get last N lines
    if (req.query.tail) {
      const n = parseInt(req.query.tail);
      const lines = content.split('\n');
      return res.json({ filename: safeName, content: lines.slice(-n).join('\n'), totalLines: lines.length });
    }
    res.json({ filename: safeName, content, totalLines: content.split('\n').length });
  } catch (err) {
    res.status(500).json({ error: 'Failed to read log' });
  }
});

// --- Runs API Routes (unified agent run tracking) ---
const RUNS_DIR = path.join(DATA_DIR, 'runs');
if (!fs.existsSync(RUNS_DIR)) fs.mkdirSync(RUNS_DIR, { recursive: true });

// Create a new run (orchestration session, agent task, tool call, etc.)
app.post('/api/runs', (req, res) => {
  try {
    const run = db.transaction(() => {
      const r = db.createRun({ ...req.body, id: uuidv4() });
      if (r.agent && r.status === 'running') {
        db.updateAgentStatus(r.agent, {
          status: 'working',
          task: (r.prompt || '').slice(0, 80),
          model: r.model,
          lastUpdated: new Date().toISOString(),
        });
      }
      return r;
    });
    res.status(201).json(run);
  } catch (err) {
    res.status(500).json({ error: 'Failed to create run', detail: err.message });
  }
});

// Update a run (status change, add result, etc.)
app.put('/api/runs/:id', (req, res) => {
  try {
    const run = db.transaction(() => {
      const updated = db.updateRun(req.params.id, req.body);
      if (!updated) return null;
      const agent = updated.agent;
      if (agent) {
        if (req.body.status === 'completed') {
          db.updateAgentStatus(agent, {
            status: 'completed',
            task: 'Done: ' + (updated.prompt || '').substring(0, 50),
            lastUpdated: new Date().toISOString(),
          });
        } else if (req.body.status === 'error' || req.body.status === 'failed') {
          db.updateAgentStatus(agent, {
            status: 'error',
            task: 'Failed: ' + (updated.prompt || '').substring(0, 50),
            lastUpdated: new Date().toISOString(),
          });
        }
      }
      return updated;
    });
    if (!run) return res.status(404).json({ error: 'Run not found' });
    res.json(run);
  } catch (err) {
    res.status(500).json({ error: 'Failed to update run', detail: err.message });
  }
});

// List runs (with filters)
app.get('/api/runs', (req, res) => {
  try {
    res.json(db.getRuns(req.query));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read runs' });
  }
});

// Manual cleanup endpoint — marks stale running runs as timed_out
app.post('/api/runs/cleanup', async (_req, res) => {
  try {
    const cleaned = cleanupStaleRuns();
    res.json({ cleaned });
  } catch (err) {
    res.status(500).json({ error: 'Cleanup failed', detail: err.message });
  }
});

// Get runs by task — IMPORTANT: specific routes before parametric to avoid shadowing
app.get('/api/runs/by-task/:taskId', (req, res) => {
  try {
    res.json(db.getRunsByTask(req.params.taskId));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read task runs' });
  }
});

// Get a single run with its full tree (children, grandchildren, etc.)
app.get('/api/runs/:id', (req, res) => {
  try {
    const run = db.getRunTree(req.params.id);
    if (!run) return res.status(404).json({ error: 'Run not found' });
    res.json(run);
  } catch (err) {
    res.status(500).json({ error: 'Failed to read run' });
  }
});

// Append output to a run's log
app.post('/api/runs/:id/log', (req, res) => {
  try {
    const logFile = db.getRunLogPath(req.params.id);
    if (!logFile) return res.status(404).json({ error: 'Run not found' });
    const logPath = path.resolve(DATA_DIR, logFile);
    // Security: ensure resolved path stays within DATA_DIR
    if (!logPath.startsWith(path.resolve(DATA_DIR) + path.sep)) {
      console.error(`[security] Path traversal blocked: ${logFile}`);
      return res.status(400).json({ error: 'Invalid log path' });
    }
    // Ensure parent directory exists (for model subdirs)
    const logDir = path.dirname(logPath);
    if (!fs.existsSync(logDir)) fs.mkdirSync(logDir, { recursive: true });
    const content = req.body.content || '';
    fs.appendFileSync(logPath, content + '\n');
    res.json({ ok: true, size: fs.statSync(logPath).size });
  } catch (err) {
    res.status(500).json({ error: 'Failed to append log' });
  }
});

// Get a run's log content
app.get('/api/runs/:id/log', (req, res) => {
  try {
    const logFile = db.getRunLogPath(req.params.id);
    if (!logFile) return res.json({ content: '', totalLines: 0 });
    const logPath = path.resolve(DATA_DIR, logFile);
    // Security: ensure resolved path stays within DATA_DIR
    if (!logPath.startsWith(path.resolve(DATA_DIR) + path.sep)) {
      console.error(`[security] Path traversal blocked: ${logFile}`);
      return res.status(400).json({ error: 'Invalid log path' });
    }
    if (!fs.existsSync(logPath)) return res.json({ content: '', totalLines: 0 });
    const content = fs.readFileSync(logPath, 'utf8');
    const tail = req.query.tail ? parseInt(req.query.tail) : null;
    if (tail) {
      const lines = content.split('\n');
      return res.json({ content: lines.slice(-tail).join('\n'), totalLines: lines.length });
    }
    res.json({ content, totalLines: content.split('\n').length });
  } catch (err) {
    res.status(500).json({ error: 'Failed to read log' });
  }
});

// --- Vector Memory API Routes ---
const vectorMemory = require('./vector-memory');

// Search agent logs semantically
app.get('/api/memory/search', async (req, res) => {
  try {
    const query = req.query.q;
    if (!query) return res.status(400).json({ error: 'Missing ?q= parameter' });
    const limit = parseInt(req.query.limit) || 5;
    const minScore = parseFloat(req.query.min_score) || 0.3;
    const results = await vectorMemory.search(query, limit, minScore);
    res.json(results);
  } catch (err) {
    res.status(500).json({ error: 'Search failed', detail: err.message });
  }
});

// Index all unindexed logs
app.post('/api/memory/index', async (req, res) => {
  try {
    const results = await vectorMemory.indexAllLogs();
    res.json({ indexed: results.filter(r => r.indexed).length, results });
  } catch (err) {
    res.status(500).json({ error: 'Indexing failed', detail: err.message });
  }
});

// Index a specific log file
app.post('/api/memory/index/:filename', async (req, res) => {
  res.status(501).json({ error: 'Single-file indexing not yet implemented. Use POST /api/memory/index to index all.' });
});

// Get index stats
app.get('/api/memory/stats', (req, res) => {
  res.json(vectorMemory.stats());
});

// --- Settings API Routes ---

app.get('/api/settings', (_req, res) => {
  try {
    res.json(safeReadJSON(SETTINGS_FILE, { columnNames: {} }));
  } catch (err) {
    res.status(500).json({ error: 'Failed to read settings' });
  }
});

app.put('/api/settings', (req, res) => {
  try {
    const current = safeReadJSON(SETTINGS_FILE, { columnNames: {} });
    const updated = { ...current, ...req.body };
    fs.writeFileSync(SETTINGS_FILE, JSON.stringify(updated, null, 2), 'utf8');
    res.json(updated);
  } catch (err) {
    res.status(500).json({ error: 'Failed to save settings' });
  }
});

// --- Team API Route ---

app.get('/api/team', (_req, res) => {
  try {
    const team = JSON.parse(fs.readFileSync(TEAM_FILE, 'utf8'));
    res.json(team);
  } catch (err) {
    res.status(500).json({ error: 'Failed to read team data' });
  }
});

// --- Memory API Routes ---

function getMemoryFiles() {
  const files = [];
  const WORKSPACE_FILES = ['MEMORY.md', 'SOUL.md', 'USER.md'];

  // Read workspace-level files
  for (const name of WORKSPACE_FILES) {
    const filePath = path.join(WORKSPACE_DIR, name);
    if (fs.existsSync(filePath)) {
      const stat = fs.statSync(filePath);
      const content = fs.readFileSync(filePath, 'utf8');
      files.push({
        filename: name,
        content,
        size: stat.size,
        modified: stat.mtime.toISOString(),
        source: 'workspace',
      });
    }
  }

  // Read memory directory files
  if (fs.existsSync(MEMORY_DIR)) {
    const entries = fs.readdirSync(MEMORY_DIR);
    for (const name of entries) {
      const filePath = path.join(MEMORY_DIR, name);
      const stat = fs.statSync(filePath);
      if (stat.isFile()) {
        const content = fs.readFileSync(filePath, 'utf8');
        files.push({
          filename: name,
          content,
          size: stat.size,
          modified: stat.mtime.toISOString(),
          source: 'memory',
        });
      }
    }
  }

  // Sort by most recently modified first
  files.sort((a, b) => new Date(b.modified) - new Date(a.modified));
  return files;
}

// List all memory files
app.get('/api/memories', (_req, res) => {
  try {
    res.json(getMemoryFiles());
  } catch (err) {
    res.json([]);
  }
});

// Get single memory file
app.get('/api/memories/:filename', (req, res) => {
  try {
    const files = getMemoryFiles();
    const file = files.find(f => f.filename === req.params.filename);
    if (!file) return res.status(404).json({ error: 'File not found' });
    res.json(file);
  } catch (err) {
    res.status(500).json({ error: 'Failed to read file' });
  }
});

// --- API Keys Routes ---

// GET /api/settings/keys — returns all keys (masked by default)
// Reads from OpenClaw config for provider keys; searxng/ollama from db
app.get('/api/settings/keys', (req, res) => {
  try {
    const dbKeys = db.getApiKeys();
    const authProfiles = readAuthProfiles();
    const ocConfig = readOpenClawConfig();
    const reveal = req.query.reveal === 'true';
    const result = {};

    // All known providers
    const allProviders = ['anthropic', 'openai', 'google', 'xai', 'groq', 'brave', 'searxng', 'ollama'];

    for (const provider of allProviders) {
      let rawKey = '';
      if (OPENCLAW_PROFILE_PROVIDERS.includes(provider)) {
        // Read from auth-profiles.json
        const profileKey = `${provider}:default`;
        rawKey = authProfiles?.profiles?.[profileKey]?.key || '';
      } else if (provider === 'brave') {
        // Read from openclaw.json
        rawKey = ocConfig?.tools?.web?.search?.apiKey || '';
      } else {
        // searxng, ollama — read from db
        const entry = dbKeys[provider];
        rawKey = entry ? decryptValue(entry.keyValue) : '';
      }
      result[provider] = {
        configured: !!rawKey,
        key: reveal ? rawKey : maskKey(rawKey),
        hasKey: !!rawKey,
      };
    }
    res.json(result);
  } catch (err) {
    res.status(500).json({ error: 'Failed to read API keys' });
  }
});

// PUT /api/settings/keys/:provider — update a key
// Writes to db AND to ~/.openclaw/openclaw.json (for supported providers)
app.put('/api/settings/keys/:provider', (req, res) => {
  try {
    const provider = req.params.provider;
    const rawKey = req.body.key || '';

    if (OPENCLAW_PROFILE_PROVIDERS.includes(provider)) {
      // Write to auth-profiles.json (with backup)
      const authProfiles = readAuthProfiles();
      if (!authProfiles.profiles) authProfiles.profiles = {};
      const profileKey = `${provider}:default`;
      if (!authProfiles.profiles[profileKey]) {
        authProfiles.profiles[profileKey] = { type: 'api_key', provider };
      }
      authProfiles.profiles[profileKey].key = rawKey;
      writeAuthProfiles(authProfiles);
    } else if (provider === 'brave') {
      // Write to openclaw.json (with backup)
      const ocConfig = readOpenClawConfig();
      setKeyInOpenClawConfig(ocConfig, provider, rawKey);
      writeOpenClawConfig(ocConfig);
    } else {
      // searxng, ollama — write to db
      db.upsertApiKey(provider, {
        keyValue: rawKey ? encryptValue(rawKey) : '',
        isActive: !!rawKey,
      });
    }

    res.json({ provider, configured: !!rawKey, key: maskKey(rawKey), hasKey: !!rawKey });
  } catch (err) {
    res.status(500).json({ error: 'Failed to update API key' });
  }
});

// POST /api/settings/keys/:provider/test — test if key is valid
app.post('/api/settings/keys/:provider/test', async (req, res) => {
  try {
    const provider = req.params.provider;
    const dbKey = db.getApiKey(provider);
    if (!dbKey) return res.status(404).json({ error: 'Provider not found' });

    const rawKey = decryptValue(dbKey.keyValue);
    let testUrl, testOptions;

    switch (provider) {
      case 'anthropic':
        testUrl = 'https://api.anthropic.com/v1/messages';
        testOptions = {
          method: 'POST',
          headers: {
            'x-api-key': rawKey,
            'anthropic-version': '2023-06-01',
            'content-type': 'application/json',
          },
          body: JSON.stringify({ model: 'claude-haiku-4-5-20251001', max_tokens: 1, messages: [{ role: 'user', content: 'hi' }] }),
        };
        break;
      case 'openai':
        testUrl = 'https://api.openai.com/v1/models';
        testOptions = { headers: { Authorization: `Bearer ${rawKey}` } };
        break;
      case 'google':
        testUrl = `https://generativelanguage.googleapis.com/v1beta/models?key=${rawKey}`;
        testOptions = {};
        break;
      case 'xai':
        testUrl = 'https://api.x.ai/v1/models';
        testOptions = { headers: { Authorization: `Bearer ${rawKey}` } };
        break;
      case 'groq':
        testUrl = 'https://api.groq.com/openai/v1/models';
        testOptions = { headers: { Authorization: `Bearer ${rawKey}` } };
        break;
      case 'brave':
        testUrl = 'https://api.search.brave.com/res/v1/web/search?q=test&count=1';
        testOptions = { headers: { 'X-Subscription-Token': rawKey } };
        break;
      case 'searxng': {
        const url = rawKey || 'http://localhost:8888';
        testUrl = `${url.replace(/\/$/, '')}/search?q=test&format=json`;
        testOptions = {};
        break;
      }
      case 'ollama': {
        const url = rawKey || 'http://localhost:11434';
        testUrl = `${url.replace(/\/$/, '')}/api/tags`;
        testOptions = {};
        break;
      }
      default:
        return res.status(400).json({ error: 'Unknown provider' });
    }

    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 10000);
    const response = await fetch(testUrl, { ...testOptions, signal: controller.signal });
    clearTimeout(timeout);

    if (response.ok) {
      res.json({ success: true, status: response.status });
    } else {
      const body = await response.text().catch(() => '');
      res.json({ success: false, status: response.status, message: body.substring(0, 200) });
    }
  } catch (err) {
    res.json({ success: false, status: 0, message: err.message });
  }
});

// GET /api/settings/ollama — check Ollama status
app.get('/api/settings/ollama', async (_req, res) => {
  try {
    const dbKey = db.getApiKey('ollama');
    const rawKey = dbKey ? decryptValue(dbKey.keyValue) : '';
    const url = rawKey || 'http://localhost:11434';
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 3000);
    const response = await fetch(`${url.replace(/\/$/, '')}/api/tags`, { signal: controller.signal });
    clearTimeout(timeout);
    if (response.ok) {
      const data = await response.json();
      res.json({ running: true, models: (data.models || []).map(m => m.name) });
    } else {
      res.json({ running: false, models: [] });
    }
  } catch {
    res.json({ running: false, models: [] });
  }
});

// Global error handler for multer and other errors
app.use((err, _req, res, _next) => {
  if (err instanceof multer.MulterError) {
    return res.status(400).json({ error: `Upload error: ${err.message}` });
  }
  if (err) {
    return res.status(400).json({ error: err.message || 'Unknown error' });
  }
});

// Graceful shutdown
function shutdown() {
  console.log('Shutting down...');
  db.close();
  process.exit(0);
}
process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);

// Start server
app.listen(PORT, '127.0.0.1', () => {
  console.log(`GooseStack running at http://127.0.0.1:${PORT}`);
  // Clean up any stale runs left over from before this restart
  const cleaned = cleanupStaleRuns();
  if (cleaned > 0) console.log(`[cleanup] Startup: timed out ${cleaned} stale run(s)`);
  // Periodically clean up stale runs every 5 minutes
  setInterval(cleanupStaleRuns, 5 * 60 * 1000);
});
