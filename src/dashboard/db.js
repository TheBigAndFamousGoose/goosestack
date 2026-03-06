'use strict';

/**
 * db.js — SQLite database layer for GooseStack
 *
 * Replaces all JSON file persistence. Uses better-sqlite3 for
 * synchronous, high-performance SQLite access.
 *
 * Tables: runs, tasks, cards, events, office_status, office_log, api_keys
 */

const Database = require('better-sqlite3');
const path = require('path');
const fs = require('fs');
const { v4: uuidv4 } = require('uuid');

const DATA_DIR = path.join(__dirname, 'data');
const DB_PATH = path.join(DATA_DIR, 'goosestack.db');

// Ensure data directory exists
fs.mkdirSync(DATA_DIR, { recursive: true });

// LOG_DIR_MAP — maps model/agent aliases to run log subdirectory names
// Copied from server.js ~line 1007
const LOG_DIR_MAP = {
  'claude-opus-4-6': 'opus',
  'sonnet': 'sonnet',
  'gemini-25-pro': 'gemini-pro',
  'flash-25': 'flash',
  'o4': 'o4',
  'gpt5': 'gpt-5',
  'scout': 'scout',
  'grok-fast': 'grok',
  'mini': 'mini',
  'haiku': 'haiku',
  'Claude Code': 'claude-code',
  'Codex': 'codex',
};

// ── Module-level DB instance ──────────────────────────────────────────────────

let db = null;

// ── Prepared statement cache (populated by init()) ───────────────────────────

const stmts = {};

// ── Schema ────────────────────────────────────────────────────────────────────

const SCHEMA_SQL = `
  CREATE TABLE IF NOT EXISTS runs (
    id          TEXT PRIMARY KEY,
    parent_id   TEXT,
    task_id     TEXT,
    agent       TEXT,
    type        TEXT,
    status      TEXT CHECK(status IN ('running','completed','failed','timed_out','cancelled')),
    prompt      TEXT,
    result      TEXT,
    model       TEXT,
    exit_code   INTEGER,
    log_file    TEXT,
    metadata    TEXT,
    started_at  TEXT,
    finished_at TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_runs_status       ON runs(status);
  CREATE INDEX IF NOT EXISTS idx_runs_agent        ON runs(agent);
  CREATE INDEX IF NOT EXISTS idx_runs_parent_id    ON runs(parent_id);
  CREATE INDEX IF NOT EXISTS idx_runs_task_id      ON runs(task_id);
  CREATE INDEX IF NOT EXISTS idx_runs_started_at   ON runs(started_at DESC);
  CREATE INDEX IF NOT EXISTS idx_runs_agent_status ON runs(agent, status);
  CREATE INDEX IF NOT EXISTS idx_runs_status_start ON runs(status, started_at);

  CREATE TABLE IF NOT EXISTS tasks (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    description TEXT,
    assignee    TEXT,
    priority    TEXT CHECK(priority IN ('low','medium','high','critical')),
    stage       TEXT CHECK(stage IN ('backlog','todo','in_progress','review','done')),
    tags        TEXT,
    due_date    TEXT,
    notes       TEXT,
    archived_at TEXT,
    created_at  TEXT,
    updated_at  TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_tasks_active_stage ON tasks(stage) WHERE archived_at IS NULL;
  CREATE INDEX IF NOT EXISTS idx_tasks_priority     ON tasks(priority);
  CREATE INDEX IF NOT EXISTS idx_tasks_assignee     ON tasks(assignee);
  CREATE INDEX IF NOT EXISTS idx_tasks_archived_at  ON tasks(archived_at);

  CREATE TABLE IF NOT EXISTS cards (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    description TEXT,
    column_name TEXT NOT NULL,
    image_url   TEXT,
    created_at  TEXT,
    updated_at  TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_cards_column ON cards(column_name);

  CREATE TABLE IF NOT EXISTS events (
    id          TEXT PRIMARY KEY,
    title       TEXT NOT NULL,
    event_date  TEXT NOT NULL,
    type        TEXT,
    agent       TEXT,
    created_at  TEXT,
    description TEXT DEFAULT '',
    time        TEXT DEFAULT '',
    recurrence  TEXT DEFAULT 'none',
    assignee    TEXT DEFAULT '',
    status      TEXT DEFAULT 'scheduled',
    notes       TEXT DEFAULT '',
    updated_at  TEXT
  );

  CREATE INDEX IF NOT EXISTS idx_events_date  ON events(event_date);
  CREATE INDEX IF NOT EXISTS idx_events_agent ON events(agent);
  CREATE INDEX IF NOT EXISTS idx_events_type  ON events(type);

  CREATE TABLE IF NOT EXISTS office_status (
    agent_name   TEXT PRIMARY KEY,
    status       TEXT DEFAULT 'idle' CHECK(status IN ('idle','working','error')),
    task         TEXT,
    details      TEXT,
    model        TEXT,
    last_updated TEXT,
    role         TEXT DEFAULT '',
    color        TEXT DEFAULT '#6366f1',
    emoji        TEXT DEFAULT '🪿'
  );

  CREATE TABLE IF NOT EXISTS office_log (
    id        INTEGER PRIMARY KEY AUTOINCREMENT,
    agent     TEXT NOT NULL,
    action    TEXT NOT NULL,
    details   TEXT,
    status    TEXT,
    timestamp TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_office_log_timestamp ON office_log(timestamp DESC);
  CREATE INDEX IF NOT EXISTS idx_office_log_agent     ON office_log(agent);

  CREATE TABLE IF NOT EXISTS api_keys (
    provider   TEXT PRIMARY KEY,
    key_value  TEXT NOT NULL,
    label      TEXT,
    is_active  INTEGER DEFAULT 1,
    created_at TEXT,
    updated_at TEXT
  );

  CREATE TABLE IF NOT EXISTS chunk_meta (
    rowid        INTEGER PRIMARY KEY,
    doc_id       TEXT NOT NULL,
    source       TEXT NOT NULL,
    agent        TEXT,
    run_id       TEXT,
    chunk_index  INTEGER DEFAULT 0,
    total_chunks INTEGER DEFAULT 1,
    text_preview TEXT NOT NULL,
    full_text    TEXT NOT NULL,
    indexed_at   TEXT NOT NULL
  );

  CREATE INDEX IF NOT EXISTS idx_cm_doc ON chunk_meta(doc_id);
  CREATE INDEX IF NOT EXISTS idx_cm_source ON chunk_meta(source);

  CREATE TABLE IF NOT EXISTS pipeline_state (
    key        TEXT PRIMARY KEY,
    value      TEXT NOT NULL,
    updated_at TEXT NOT NULL
  );

  CREATE TABLE IF NOT EXISTS lesson_candidates (
    id              TEXT PRIMARY KEY,
    session_id      TEXT NOT NULL,
    moment_id       TEXT NOT NULL,
    title           TEXT NOT NULL,
    rule            TEXT NOT NULL,
    lesson_type     TEXT,
    evidence        TEXT,
    rationale       TEXT,
    confidence      REAL DEFAULT 0.5,
    tags            TEXT,
    status          TEXT DEFAULT 'pending',
    promoted_to     TEXT,
    extraction_model TEXT,
    created_at      TEXT NOT NULL,
    reviewed_at     TEXT
  );

  CREATE TABLE IF NOT EXISTS lessons (
    id              TEXT PRIMARY KEY,
    title           TEXT NOT NULL,
    rule            TEXT NOT NULL,
    lesson_type     TEXT,
    evidence        TEXT,
    rationale       TEXT,
    tags            TEXT,
    source_sessions TEXT,
    confidence      REAL,
    status          TEXT DEFAULT 'active',
    embedding       BLOB,
    created_at      TEXT NOT NULL,
    reviewed_by     TEXT,
    confirmation_count  INTEGER DEFAULT 0,
    last_confirmed_at   TEXT,
    last_triggered_at   TEXT,
    trigger_count       INTEGER DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS lesson_confirmations (
    id          TEXT PRIMARY KEY,
    lesson_id   TEXT NOT NULL,
    session_id  TEXT NOT NULL,
    moment_id   TEXT,
    similarity  REAL,
    confirmed_at TEXT,
    cluster_id  TEXT,
    FOREIGN KEY (lesson_id) REFERENCES lessons(id)
  );
`;

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Parse JSON safely, returning fallback on error */
function jsonParse(str, fallback = null) {
  if (str === null || str === undefined) return fallback;
  try { return JSON.parse(str); } catch { return fallback; }
}

/** Convert snake_case row from DB to camelCase JS object */
function camelRun(row) {
  if (!row) return null;
  return {
    id:         row.id,
    parentId:   row.parent_id,
    taskId:     row.task_id,
    agent:      row.agent,
    type:       row.type,
    status:     row.status,
    prompt:     row.prompt,
    result:     row.result,
    model:      row.model,
    exitCode:   row.exit_code,
    logFile:    row.log_file,
    metadata:   jsonParse(row.metadata, {}),
    startedAt:  row.started_at,
    finishedAt: row.finished_at,
    children:   [],  // populated by tree builders
  };
}

function camelTask(row) {
  if (!row) return null;
  return {
    id:          row.id,
    title:       row.title,
    description: row.description,
    assignee:    row.assignee,
    priority:    row.priority,
    stage:       row.stage,
    tags:        jsonParse(row.tags, []),
    dueDate:     row.due_date || '',
    notes:       jsonParse(row.notes, []),  // stored as JSON array
    archivedAt:  row.archived_at,
    createdAt:   row.created_at,
    updatedAt:   row.updated_at,
  };
}

function camelCard(row) {
  if (!row) return null;
  return {
    id:          row.id,
    title:       row.title,
    description: row.description,
    columnName:  row.column_name,
    imageUrl:    row.image_url,
    createdAt:   row.created_at,
    updatedAt:   row.updated_at,
  };
}

function camelEvent(row) {
  if (!row) return null;
  return {
    id:          row.id,
    title:       row.title,
    date:        row.event_date,        // Frontend expects .date
    eventDate:   row.event_date,        // Also include for consistency
    type:        row.type,
    agent:       row.agent,
    description: row.description || '',
    time:        row.time || '',
    recurrence:  row.recurrence || 'none',
    assignee:    row.assignee || '',
    status:      row.status || 'scheduled',
    notes:       row.notes || '',
    createdAt:   row.created_at,
    updatedAt:   row.updated_at,
  };
}

function camelOfficeLog(row) {
  if (!row) return null;
  return {
    id:        row.id,
    agent:     row.agent,
    action:    row.action,
    details:   row.details,
    status:    row.status,
    timestamp: row.timestamp,
  };
}

/** Generate logFile path for a new run */
function generateLogFile(run) {
  const modelDir = LOG_DIR_MAP[run.model] || LOG_DIR_MAP[run.agent] ||
    (run.model || run.agent || 'unknown').replace(/[^a-zA-Z0-9-]/g, '-').toLowerCase();
  const d = new Date(run.startedAt);
  const yy  = String(d.getFullYear()).slice(-2);
  const mm  = String(d.getMonth() + 1).padStart(2, '0');
  const dd  = String(d.getDate()).padStart(2, '0');
  const datePrefix = `${yy}-${mm}-${dd}`;
  const shortId = run.id.slice(0, 8);
  return `runs/${modelDir}/${datePrefix}_${shortId}.log`;
}

// ── Init / Close ──────────────────────────────────────────────────────────────

/**
 * Initialize the database: create tables, indexes, set pragmas,
 * and prepare all statements.
 */
function init() {
  if (db) return db;  // already initialised

  db = new Database(DB_PATH);

  // Performance & safety pragmas
  db.pragma('journal_mode = WAL');
  db.pragma('foreign_keys = ON');
  db.pragma('temp_store = MEMORY');
  db.pragma('synchronous = NORMAL');

  // Load sqlite-vec extension for vector search
  try {
    const sqliteVec = require('sqlite-vec');
    sqliteVec.load(db);
    db.exec(`CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(embedding float[768])`);
  } catch (e) {
    console.warn('[db] sqlite-vec not available, vector search disabled:', e.message);
  }

  // Create tables & indexes
  db.exec(SCHEMA_SQL);

  // ── Migrations: add columns to existing tables if missing ─────────────────
  // This handles databases created before Sprint 4.
  {
    const lessonCols = db.prepare("PRAGMA table_info(lessons)").all().map(r => r.name);
    const addIfMissing = (col, colDef) => {
      if (!lessonCols.includes(col)) {
        try {
          db.exec(`ALTER TABLE lessons ADD COLUMN ${col} ${colDef}`);
        } catch (e) {
          // Ignore "duplicate column" errors from concurrent inits
          if (!e.message.includes('duplicate')) console.warn('[db] migration error:', e.message);
        }
      }
    };
    addIfMissing('confirmation_count', 'INTEGER DEFAULT 0');
    addIfMissing('last_confirmed_at',  'TEXT');
    addIfMissing('last_triggered_at',  'TEXT');
    addIfMissing('trigger_count',      'INTEGER DEFAULT 0');
  }

  // ── Prepare statements ────────────────────────────────────────────────────

  // runs
  stmts.insertRun = db.prepare(`
    INSERT INTO runs (id, parent_id, task_id, agent, type, status, prompt, result,
                      model, exit_code, log_file, metadata, started_at, finished_at)
    VALUES (@id, @parent_id, @task_id, @agent, @type, @status, @prompt, @result,
            @model, @exit_code, @log_file, @metadata, @started_at, @finished_at)
  `);
  stmts.getRun = db.prepare('SELECT * FROM runs WHERE id = ?');
  stmts.getRunChildren = db.prepare('SELECT * FROM runs WHERE parent_id = ? ORDER BY started_at ASC');
  stmts.updateRun = null;  // dynamic — built per call
  stmts.deleteRun = db.prepare('DELETE FROM runs WHERE id = ?');
  stmts.getRunLogFile = db.prepare('SELECT log_file FROM runs WHERE id = ?');
  stmts.cleanupStaleRuns = db.prepare(`
    UPDATE runs
    SET status = 'timed_out',
        finished_at = ?,
        result = 'Automatically timed out after period of inactivity'
    WHERE status = 'running'
      AND started_at < ?
    RETURNING agent
  `);
  stmts.getAllRunsByParent = db.prepare('SELECT * FROM runs WHERE parent_id = ? ORDER BY started_at ASC');
  stmts.getAllRuns = db.prepare('SELECT * FROM runs ORDER BY started_at DESC');

  // tasks
  stmts.insertTask = db.prepare(`
    INSERT INTO tasks (id, title, description, assignee, priority, stage, tags,
                       due_date, notes, archived_at, created_at, updated_at)
    VALUES (@id, @title, @description, @assignee, @priority, @stage, @tags,
            @due_date, @notes, @archived_at, @created_at, @updated_at)
  `);
  stmts.getTask = db.prepare('SELECT * FROM tasks WHERE id = ?');
  stmts.getTasks = db.prepare(`
    SELECT * FROM tasks
    WHERE archived_at IS NULL
    ORDER BY
      CASE stage
        WHEN 'backlog'      THEN 1
        WHEN 'todo'         THEN 2
        WHEN 'in_progress'  THEN 3
        WHEN 'review'       THEN 4
        WHEN 'done'         THEN 5
        ELSE 6
      END,
      CASE priority
        WHEN 'critical' THEN 1
        WHEN 'high'     THEN 2
        WHEN 'medium'   THEN 3
        WHEN 'low'      THEN 4
        ELSE 5
      END
  `);
  stmts.deleteTask = db.prepare('DELETE FROM tasks WHERE id = ?');
  stmts.archiveTask = db.prepare(`
    UPDATE tasks SET archived_at = ? WHERE id = ? AND archived_at IS NULL
  `);
  stmts.archiveAllDone = db.prepare(`
    UPDATE tasks SET archived_at = ?
    WHERE stage = 'done' AND archived_at IS NULL
  `);
  stmts.archiveAllDoneCount = db.prepare(`
    SELECT COUNT(*) as n FROM tasks WHERE stage = 'done' AND archived_at IS NULL
  `);
  stmts.restoreTask = db.prepare(`
    UPDATE tasks SET archived_at = NULL, stage = 'todo', updated_at = ?
    WHERE id = ? AND archived_at IS NOT NULL
  `);
  stmts.getArchivedTasks = db.prepare(`
    SELECT * FROM tasks WHERE archived_at IS NOT NULL ORDER BY archived_at DESC
  `);
  stmts.deleteArchivedTask = db.prepare(`
    DELETE FROM tasks WHERE id = ? AND archived_at IS NOT NULL
  `);

  // cards
  stmts.insertCard = db.prepare(`
    INSERT INTO cards (id, title, description, column_name, image_url, created_at, updated_at)
    VALUES (@id, @title, @description, @column_name, @image_url, @created_at, @updated_at)
  `);
  stmts.getCard = db.prepare('SELECT * FROM cards WHERE id = ?');
  stmts.getCards = db.prepare('SELECT * FROM cards ORDER BY created_at ASC');
  stmts.deleteCard = db.prepare('DELETE FROM cards WHERE id = ?');

  // events
  stmts.insertEvent = db.prepare(`
    INSERT INTO events (id, title, event_date, type, agent, created_at,
                        description, time, recurrence, assignee, status, notes, updated_at)
    VALUES (@id, @title, @event_date, @type, @agent, @created_at,
            @description, @time, @recurrence, @assignee, @status, @notes, @updated_at)
  `);
  stmts.getEvent = db.prepare('SELECT * FROM events WHERE id = ?');
  stmts.getEvents = db.prepare('SELECT * FROM events ORDER BY event_date ASC');
  stmts.deleteEvent = db.prepare('DELETE FROM events WHERE id = ?');

  // office_status
  stmts.upsertOfficeStatus = db.prepare(`
    INSERT INTO office_status (agent_name, status, task, details, model, last_updated,
                               role, color, emoji)
    VALUES (@agent_name, @status, @task, @details, @model, @last_updated,
            @role, @color, @emoji)
    ON CONFLICT(agent_name) DO UPDATE SET
      status       = excluded.status,
      task         = excluded.task,
      details      = excluded.details,
      model        = excluded.model,
      last_updated = excluded.last_updated,
      role         = excluded.role,
      color        = excluded.color,
      emoji        = excluded.emoji
  `);
  stmts.getAllOfficeStatus = db.prepare('SELECT * FROM office_status');

  // office_log
  stmts.insertOfficeLog = db.prepare(`
    INSERT INTO office_log (agent, action, details, status, timestamp)
    VALUES (@agent, @action, @details, @status, @timestamp)
  `);
  stmts.getOfficeLog = db.prepare(`
    SELECT * FROM office_log ORDER BY timestamp DESC LIMIT ?
  `);

  // api_keys
  stmts.upsertApiKey = db.prepare(`
    INSERT INTO api_keys (provider, key_value, label, is_active, created_at, updated_at)
    VALUES (@provider, @key_value, @label, @is_active, @created_at, @updated_at)
    ON CONFLICT(provider) DO UPDATE SET
      key_value  = excluded.key_value,
      label      = excluded.label,
      is_active  = excluded.is_active,
      updated_at = excluded.updated_at
  `);
  stmts.getApiKey = db.prepare('SELECT * FROM api_keys WHERE provider = ?');
  stmts.getAllApiKeys = db.prepare('SELECT * FROM api_keys');
  stmts.deleteApiKey = db.prepare('DELETE FROM api_keys WHERE provider = ?');

  return db;
}

/** Close the database connection */
function close() {
  if (db) {
    db.close();
    db = null;
  }
}

// ── Internal dynamic update builder ──────────────────────────────────────────

/**
 * Build and execute a partial UPDATE statement.
 * Only columns present in `patch` (mapped via `colMap`) will be SET.
 * `whereClause` must use named param @id.
 */
function partialUpdate(table, colMap, patch, id, extraWhere = '') {
  const sets = [];
  const params = { id };

  for (const [jsKey, colName] of Object.entries(colMap)) {
    if (Object.prototype.hasOwnProperty.call(patch, jsKey)) {
      sets.push(`${colName} = @${colName}`);
      params[colName] = patch[jsKey];
    }
  }

  if (sets.length === 0) return null; // nothing to update

  const sql = `UPDATE ${table} SET ${sets.join(', ')} WHERE id = @id${extraWhere}`;
  return db.prepare(sql).run(params);
}

// ── Runs ──────────────────────────────────────────────────────────────────────

const RUN_COL_MAP = {
  parentId:   'parent_id',
  taskId:     'task_id',
  agent:      'agent',
  type:       'type',
  status:     'status',
  prompt:     'prompt',
  result:     'result',
  model:      'model',
  exitCode:   'exit_code',
  logFile:    'log_file',
  metadata:   'metadata',
  startedAt:  'started_at',
  finishedAt: 'finished_at',
};

/**
 * List runs with optional filters.
 * filters: { status, agent, type, parentId, taskId, limit, offset, sort }
 */
function getRuns(filters = {}) {
  const { status, agent, type, parentId, taskId, limit = 100, offset = 0, sort = 'desc' } = filters;

  const conditions = [];
  const params = {};

  if (status) {
    conditions.push('status = @status');
    params.status = status;
  }
  if (agent) {
    conditions.push('LOWER(agent) LIKE @agent');
    params.agent = `%${agent.toLowerCase()}%`;
  }
  if (type) {
    conditions.push('type = @type');
    params.type = type;
  }
  if (parentId !== undefined) {
    conditions.push('parent_id = @parent_id');
    params.parent_id = parentId;
  }
  if (taskId) {
    conditions.push('task_id = @task_id');
    params.task_id = taskId;
  }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  const order = sort === 'asc' ? 'ASC' : 'DESC';
  const sql = `SELECT * FROM runs ${where} ORDER BY started_at ${order} LIMIT @limit OFFSET @offset`;
  params.limit = limit;
  params.offset = offset;

  return db.prepare(sql).all(params).map(camelRun);
}

/**
 * Get a single run with children populated via parent_id.
 */
function getRun(id) {
  const row = stmts.getRun.get(id);
  if (!row) return null;
  const run = camelRun(row);
  run.children = _buildChildren(id);
  return run;
}

/** Recursively build children array for a given parentId */
function _buildChildren(parentId, visited = new Set()) {
  if (visited.has(parentId)) return [];
  visited.add(parentId);
  const rows = stmts.getRunChildren.all(parentId);
  return rows.map(r => {
    const child = camelRun(r);
    child.children = _buildChildren(r.id, new Set(visited));
    return child;
  });
}

/**
 * Create a new run. Auto-generates logFile path.
 * Returns the created run object.
 */
function createRun(data) {
  const now = new Date().toISOString();
  const id = data.id || uuidv4();
  const startedAt = data.startedAt || now;

  const run = {
    id,
    parentId:   data.parentId || null,
    taskId:     data.taskId || null,
    agent:      data.agent || 'Unknown',
    type:       data.type || 'task',
    status:     data.status || 'running',
    prompt:     data.prompt || '',
    result:     data.result || '',
    model:      data.model || '',
    exitCode:   data.exitCode ?? null,
    logFile:    data.logFile || null,
    metadata:   data.metadata || {},
    startedAt,
    finishedAt: data.finishedAt || null,
  };

  // Auto-generate logFile if not provided
  if (!run.logFile) {
    run.logFile = generateLogFile(run);
  }

  stmts.insertRun.run({
    id:          run.id,
    parent_id:   run.parentId,
    task_id:     run.taskId,
    agent:       run.agent,
    type:        run.type,
    status:      run.status,
    prompt:      run.prompt,
    result:      run.result,
    model:       run.model,
    exit_code:   run.exitCode,
    log_file:    run.logFile,
    metadata:    JSON.stringify(run.metadata),
    started_at:  run.startedAt,
    finished_at: run.finishedAt,
  });

  return run;
}

/**
 * Update specific fields of a run. Only provided fields are updated.
 * Returns the updated run object.
 */
function updateRun(id, patch) {
  // Serialize metadata if provided
  const normalizedPatch = { ...patch };
  if (normalizedPatch.metadata !== undefined && typeof normalizedPatch.metadata === 'object') {
    normalizedPatch.metadata = JSON.stringify(normalizedPatch.metadata);
  }
  // Auto-set finishedAt when status transitions to terminal
  if ((patch.status === 'completed' || patch.status === 'failed' || patch.status === 'error') &&
      patch.finishedAt === undefined) {
    const existing = stmts.getRun.get(id);
    if (existing && !existing.finished_at) {
      normalizedPatch.finishedAt = new Date().toISOString();
    }
  }

  partialUpdate('runs', RUN_COL_MAP, normalizedPatch, id);
  return getRun(id);
}

/**
 * Get all runs linked to a task, with full tree structure.
 */
function getRunsByTask(taskId) {
  const allRuns = db.prepare('SELECT * FROM runs WHERE task_id = ? OR id IN (SELECT id FROM runs WHERE task_id = ?)').all(taskId, taskId);

  // Build full flat list for this task context
  const taskRunIds = new Set(allRuns.map(r => r.id));
  const roots = allRuns.filter(r => !r.parent_id || !taskRunIds.has(r.parent_id));

  function buildTree(parentId, visited = new Set()) {
    if (visited.has(parentId)) return [];
    visited.add(parentId);
    // Include children from anywhere (not just task runs) to capture sub-agents
    const children = stmts.getAllRunsByParent.all(parentId);
    return children.map(c => {
      const child = camelRun(c);
      child.children = buildTree(c.id, new Set(visited));
      return child;
    });
  }

  return roots.map(r => {
    const run = camelRun(r);
    run.children = buildTree(r.id);
    return run;
  });
}

/**
 * Get a single run plus all its descendants (recursive tree).
 */
function getRunTree(id) {
  const row = stmts.getRun.get(id);
  if (!row) return null;

  // Use recursive CTE to fetch entire subtree efficiently
  const subtree = db.prepare(`
    WITH RECURSIVE tree AS (
      SELECT * FROM runs WHERE id = ?
      UNION ALL
      SELECT r.* FROM runs r INNER JOIN tree t ON r.parent_id = t.id
    )
    SELECT * FROM tree
  `).all(id);

  const byId = {};
  for (const r of subtree) {
    const run = camelRun(r);
    run.children = [];
    byId[r.id] = run;
  }
  // Wire up children
  for (const r of subtree) {
    if (r.parent_id && byId[r.parent_id]) {
      byId[r.parent_id].children.push(byId[r.id]);
    }
  }
  return byId[id] || null;
}

/**
 * Get just the log_file path for a run (lightweight — avoids fetching full run).
 */
function getRunLogPath(id) {
  const row = stmts.getRunLogFile.get(id);
  return row ? row.log_file : null;
}

/**
 * Mark running runs as timed_out if older than ttlMs.
 * Returns { cleaned: N, timedOutAgents: [...] }
 */
function cleanupStaleRuns(ttlMs = 30 * 60 * 1000) {
  const now = new Date();
  const cutoff = new Date(now.getTime() - ttlMs).toISOString();
  const finishedAt = now.toISOString();

  const rows = stmts.cleanupStaleRuns.all(finishedAt, cutoff);
  const timedOutAgents = [...new Set(rows.map(r => r.agent).filter(Boolean))];

  return { cleaned: rows.length, timedOutAgents };
}

/**
 * Delete a run by id.
 */
function deleteRun(id) {
  return stmts.deleteRun.run(id).changes > 0;
}

// ── Tasks ─────────────────────────────────────────────────────────────────────

const TASK_COL_MAP = {
  title:       'title',
  description: 'description',
  assignee:    'assignee',
  priority:    'priority',
  stage:       'stage',
  tags:        'tags',
  dueDate:     'due_date',
  notes:       'notes',
  archivedAt:  'archived_at',
  createdAt:   'created_at',
  updatedAt:   'updated_at',
};

/** Return all active (non-archived) tasks ordered by stage + priority. */
function getTasks() {
  return stmts.getTasks.all().map(camelTask);
}

/** Get a single task by id. */
function getTask(id) {
  return camelTask(stmts.getTask.get(id));
}

/** Create a new task. Returns the created task. */
function createTask(data) {
  const now = new Date().toISOString();
  const task = {
    id:          data.id || uuidv4(),
    title:       data.title || 'Untitled',
    description: data.description || '',
    assignee:    data.assignee || '',
    priority:    data.priority || 'medium',
    stage:       data.stage || 'todo',
    tags:        data.tags || [],
    dueDate:     data.dueDate || data.due_date || '',
    notes:       data.notes || [],
    archivedAt:  data.archivedAt || null,
    createdAt:   data.createdAt || now,
    updatedAt:   data.updatedAt || now,
  };

  stmts.insertTask.run({
    id:          task.id,
    title:       task.title,
    description: task.description,
    assignee:    task.assignee,
    priority:    task.priority,
    stage:       task.stage,
    tags:        JSON.stringify(task.tags),
    due_date:    task.dueDate,
    notes:       JSON.stringify(task.notes),
    archived_at: task.archivedAt,
    created_at:  task.createdAt,
    updated_at:  task.updatedAt,
  });

  return task;
}

/** Update specific fields of a task. Returns the updated task. */
function updateTask(id, patch) {
  const normalizedPatch = { ...patch };
  if (normalizedPatch.tags !== undefined && Array.isArray(normalizedPatch.tags)) {
    normalizedPatch.tags = JSON.stringify(normalizedPatch.tags);
  }
  if (!normalizedPatch.updatedAt) {
    normalizedPatch.updatedAt = new Date().toISOString();
  }
  partialUpdate('tasks', TASK_COL_MAP, normalizedPatch, id);
  return getTask(id);
}

/** Delete a task by id. */
function deleteTask(id) {
  return stmts.deleteTask.run(id).changes > 0;
}

/** Archive a task (set archived_at = now). */
function archiveTask(id) {
  stmts.archiveTask.run(new Date().toISOString(), id);
  return getTask(id);
}

/**
 * Archive all tasks in stage 'done'.
 * Returns count of tasks archived.
 */
function archiveAllDone() {
  const count = stmts.archiveAllDoneCount.get().n;
  if (count > 0) {
    stmts.archiveAllDone.run(new Date().toISOString());
  }
  return count;
}

/** Restore an archived task back to active (stage = 'to-do'). */
function restoreTask(id) {
  stmts.restoreTask.run(new Date().toISOString(), id);
  return getTask(id);
}

/**
 * Get archived tasks with optional filters.
 * filters: { search, assignee, tag, from, to }
 */
function getArchivedTasks(filters = {}) {
  const { search, assignee, tag, from, to } = filters;

  const conditions = ['archived_at IS NOT NULL'];
  const params = {};

  if (assignee) {
    conditions.push('assignee = @assignee');
    params.assignee = assignee;
  }
  if (from) {
    conditions.push("SUBSTR(archived_at, 1, 10) >= @from");
    params.from = from;
  }
  if (to) {
    conditions.push("SUBSTR(archived_at, 1, 10) <= @to");
    params.to = to;
  }

  const sql = `SELECT * FROM tasks WHERE ${conditions.join(' AND ')} ORDER BY archived_at DESC`;
  let rows = db.prepare(sql).all(params).map(camelTask);

  // In-memory filters for search and tag (these need LIKE or JSON logic)
  if (search) {
    const q = search.toLowerCase();
    rows = rows.filter(t => {
      const hay = `${t.title} ${t.description} ${(t.tags || []).join(' ')}`.toLowerCase();
      return hay.includes(q);
    });
  }
  if (tag) {
    rows = rows.filter(t => (t.tags || []).includes(tag));
  }

  return rows;
}

/** Permanently delete an archived task. */
function deleteArchivedTask(id) {
  return stmts.deleteArchivedTask.run(id).changes > 0;
}

// ── Cards ─────────────────────────────────────────────────────────────────────

const CARD_COL_MAP = {
  title:       'title',
  description: 'description',
  columnName:  'column_name',
  imageUrl:    'image_url',
  createdAt:   'created_at',
  updatedAt:   'updated_at',
};

/** Return all cards ordered by created_at. */
function getCards() {
  return stmts.getCards.all().map(camelCard);
}

/** Get a single card by id. */
function getCard(id) {
  return camelCard(stmts.getCard.get(id));
}

/** Create a new card. Returns the created card. */
function createCard(data) {
  const now = new Date().toISOString();
  const card = {
    id:          data.id || uuidv4(),
    title:       data.title || 'Untitled',
    description: data.description || '',
    columnName:  data.columnName || data.column_name || '',
    imageUrl:    data.imageUrl || data.image_url || '',
    createdAt:   data.createdAt || now,
    updatedAt:   data.updatedAt || now,
  };

  stmts.insertCard.run({
    id:          card.id,
    title:       card.title,
    description: card.description,
    column_name: card.columnName,
    image_url:   card.imageUrl,
    created_at:  card.createdAt,
    updated_at:  card.updatedAt,
  });

  return card;
}

/** Update specific fields of a card. Returns the updated card. */
function updateCard(id, patch) {
  const normalizedPatch = { ...patch };
  if (!normalizedPatch.updatedAt) {
    normalizedPatch.updatedAt = new Date().toISOString();
  }
  partialUpdate('cards', CARD_COL_MAP, normalizedPatch, id);
  return getCard(id);
}

/** Delete a card by id. */
function deleteCard(id) {
  return stmts.deleteCard.run(id).changes > 0;
}

// ── Events ────────────────────────────────────────────────────────────────────

const EVENT_COL_MAP = {
  title:       'title',
  eventDate:   'event_date',
  date:        'event_date',
  type:        'type',
  agent:       'agent',
  description: 'description',
  time:        'time',
  recurrence:  'recurrence',
  assignee:    'assignee',
  status:      'status',
  notes:       'notes',
  createdAt:   'created_at',
  updatedAt:   'updated_at',
};

/**
 * Get events with optional filters.
 * filters: { month, year, agent, type }
 * month/year filter against event_date (YYYY-MM-DD prefix match).
 */
function getEvents(filters = {}) {
  const { month, year, agent, type } = filters;

  const conditions = [];
  const params = {};

  if (year && month) {
    const mm = String(month).padStart(2, '0');
    conditions.push("SUBSTR(event_date, 1, 7) = @yearMonth");
    params.yearMonth = `${year}-${mm}`;
  } else if (year) {
    conditions.push("SUBSTR(event_date, 1, 4) = @year");
    params.year = String(year);
  }
  if (agent) {
    conditions.push('agent = @agent');
    params.agent = agent;
  }
  if (type) {
    conditions.push('type = @type');
    params.type = type;
  }

  const where = conditions.length ? `WHERE ${conditions.join(' AND ')}` : '';
  const sql = `SELECT * FROM events ${where} ORDER BY event_date ASC`;
  return db.prepare(sql).all(params).map(camelEvent);
}

/** Get a single event by id. */
function getEvent(id) {
  return camelEvent(stmts.getEvent.get(id));
}

/** Create a new event. Returns the created event. */
function createEvent(data) {
  const now = new Date().toISOString();
  const event = {
    id:          data.id || uuidv4(),
    title:       data.title || 'Untitled',
    eventDate:   data.eventDate || data.event_date || data.date || now.slice(0, 10),
    type:        data.type || 'task',
    agent:       data.agent || '',
    description: data.description || '',
    time:        data.time || '',
    recurrence:  data.recurrence || 'none',
    assignee:    data.assignee || '',
    status:      data.status || 'scheduled',
    notes:       data.notes || '',
    createdAt:   data.createdAt || now,
    updatedAt:   data.updatedAt || now,
  };

  stmts.insertEvent.run({
    id:          event.id,
    title:       event.title,
    event_date:  event.eventDate,
    type:        event.type,
    agent:       event.agent,
    created_at:  event.createdAt,
    description: event.description,
    time:        event.time,
    recurrence:  event.recurrence,
    assignee:    event.assignee,
    status:      event.status,
    notes:       event.notes,
    updated_at:  event.updatedAt,
  });

  return camelEvent({
    id:          event.id,
    title:       event.title,
    event_date:  event.eventDate,
    type:        event.type,
    agent:       event.agent,
    description: event.description,
    time:        event.time,
    recurrence:  event.recurrence,
    assignee:    event.assignee,
    status:      event.status,
    notes:       event.notes,
    created_at:  event.createdAt,
    updated_at:  event.updatedAt,
  });
}

/** Update specific fields of an event. Returns the updated event. */
function updateEvent(id, patch) {
  const normalizedPatch = { ...patch };
  if (!normalizedPatch.updatedAt) {
    normalizedPatch.updatedAt = new Date().toISOString();
  }
  partialUpdate('events', EVENT_COL_MAP, normalizedPatch, id);
  return getEvent(id);
}

/** Delete an event by id. */
function deleteEvent(id) {
  return stmts.deleteEvent.run(id).changes > 0;
}

// ── Office Status ─────────────────────────────────────────────────────────────

/**
 * Get all agent statuses as an object keyed by agent name.
 * Shape: { agentName: { status, task, details, model, lastUpdated } }
 */
function getOfficeStatus() {
  const rows = stmts.getAllOfficeStatus.all();
  const result = {};
  for (const row of rows) {
    result[row.agent_name] = {
      agent:       row.agent_name,        // Frontend expects .agent
      status:      row.status,
      task:        row.task || '',
      details:     row.details || '',
      model:       row.model || '',
      role:        row.role || '',
      color:       row.color || '#6366f1',
      emoji:       row.emoji || '🪿',
      lastActive:  row.last_updated,      // Frontend expects .lastActive
      lastUpdated: row.last_updated,      // Also include for consistency
    };
  }
  return result;
}

/**
 * Insert or replace an agent's status row.
 * data: { status, task, details, model, lastUpdated }
 */
function updateAgentStatus(agentName, data) {
  stmts.upsertOfficeStatus.run({
    agent_name:   agentName,
    status:       data.status || 'idle',
    task:         data.task || '',
    details:      data.details || '',
    model:        data.model || '',
    last_updated: data.lastUpdated || new Date().toISOString(),
    role:         data.role || '',
    color:        data.color || '#6366f1',
    emoji:        data.emoji || '🪿',
  });
}

// ── Office Log ────────────────────────────────────────────────────────────────

/**
 * Return office log entries ordered newest-first.
 * limit defaults to 200.
 */
function getOfficeLog(limit = 200) {
  return stmts.getOfficeLog.all(limit).map(camelOfficeLog);
}

/**
 * Append an entry to the office log.
 * entry: { agent, action, details, status, timestamp }
 */
function appendOfficeLog(entry) {
  stmts.insertOfficeLog.run({
    agent:     entry.agent || 'Unknown',
    action:    entry.action || '',
    details:   entry.details || null,
    status:    entry.status || '',
    timestamp: entry.timestamp || new Date().toISOString(),
  });
}

// ── API Keys ──────────────────────────────────────────────────────────────────

/**
 * Get all API keys as an object keyed by provider.
 * Shape: { provider: { keyValue, label, isActive, createdAt, updatedAt } }
 */
function getApiKeys() {
  const rows = stmts.getAllApiKeys.all();
  const result = {};
  for (const row of rows) {
    result[row.provider] = {
      keyValue:  row.key_value,
      label:     row.label,
      isActive:  row.is_active === 1,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
    };
  }
  return result;
}

/**
 * Get a single API key by provider.
 */
function getApiKey(provider) {
  const row = stmts.getApiKey.get(provider);
  if (!row) return null;
  return {
    provider:  row.provider,
    keyValue:  row.key_value,
    label:     row.label,
    isActive:  row.is_active === 1,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

/**
 * Insert or replace an API key.
 * data: { keyValue, label, isActive }
 */
function upsertApiKey(provider, data) {
  const now = new Date().toISOString();
  const existing = stmts.getApiKey.get(provider);
  stmts.upsertApiKey.run({
    provider:   provider,
    key_value:  data.keyValue !== undefined ? data.keyValue : (existing ? existing.key_value : ''),
    label:      data.label !== undefined ? data.label : (existing ? existing.label : null),
    is_active:  data.isActive !== undefined ? (data.isActive ? 1 : 0) : (existing ? existing.is_active : 1),
    created_at: existing ? existing.created_at : now,
    updated_at: now,
  });
  return getApiKey(provider);
}

/**
 * Delete an API key by provider.
 */
function deleteApiKey(provider) {
  return stmts.deleteApiKey.run(provider).changes > 0;
}

// ── Transactions ──────────────────────────────────────────────────────────────

/**
 * Wrap a function in a SQLite transaction.
 * Usage: transaction(() => { createRun(...); updateTask(...); })
 */
function transaction(fn) {
  if (!db) throw new Error('Database not initialized — call init() first');
  return db.transaction(fn)();
}

// ── Pipeline State ────────────────────────────────────────────────────────────

function getPipelineState(key) {
  if (!db) throw new Error('Database not initialized');
  const row = db.prepare('SELECT value FROM pipeline_state WHERE key = ?').get(key);
  return row ? row.value : null;
}

function setPipelineState(key, value) {
  if (!db) throw new Error('Database not initialized');
  db.prepare(`INSERT OR REPLACE INTO pipeline_state (key, value, updated_at) VALUES (?, ?, ?)`).run(key, value, new Date().toISOString());
}

// ── Vector Chunks ─────────────────────────────────────────────────────────────

function insertVectorChunk(meta, embedding) {
  if (!db) throw new Error('Database not initialized');
  const result = db.prepare(`INSERT INTO chunk_meta (doc_id, source, agent, run_id, chunk_index, total_chunks, text_preview, full_text, indexed_at)
    VALUES (@doc_id, @source, @agent, @run_id, @chunk_index, @total_chunks, @text_preview, @full_text, @indexed_at)`).run(meta);
  const rowid = result.lastInsertRowid;
  try {
    db.prepare('INSERT INTO vec_chunks (rowid, embedding) VALUES (?, ?)').run(BigInt(rowid), new Float32Array(embedding));
  } catch (e) {
    console.warn('[db] Failed to insert vector:', e.message);
  }
  return rowid;
}

function insertVectorChunks(chunks) {
  if (!db) throw new Error('Database not initialized');
  const insertMeta = db.prepare(`INSERT INTO chunk_meta (doc_id, source, agent, run_id, chunk_index, total_chunks, text_preview, full_text, indexed_at)
    VALUES (@doc_id, @source, @agent, @run_id, @chunk_index, @total_chunks, @text_preview, @full_text, @indexed_at)`);
  const insertVec = db.prepare('INSERT INTO vec_chunks (rowid, embedding) VALUES (?, ?)');

  const tx = db.transaction((items) => {
    const rowids = [];
    for (const { meta, embedding } of items) {
      const result = insertMeta.run(meta);
      const rowid = result.lastInsertRowid;
      try {
        insertVec.run(BigInt(rowid), new Float32Array(embedding));
      } catch (e) {
        console.warn('[db] Failed to insert vector for', meta.doc_id, ':', e.message);
      }
      rowids.push(rowid);
    }
    return rowids;
  });

  return tx(chunks);
}

function deleteVectorDoc(docId) {
  if (!db) throw new Error('Database not initialized');
  const rows = db.prepare('SELECT rowid FROM chunk_meta WHERE doc_id = ?').all(docId);
  if (rows.length === 0) return 0;

  const tx = db.transaction(() => {
    const delVec = db.prepare('DELETE FROM vec_chunks WHERE rowid = ?');
    for (const row of rows) {
      try { delVec.run(BigInt(row.rowid)); } catch (e) { /* vec may not exist */ }
    }
    db.prepare('DELETE FROM chunk_meta WHERE doc_id = ?').run(docId);
  });
  tx();
  return rows.length;
}

function searchVectors(embedding, topK = 10, filters = {}) {
  if (!db) throw new Error('Database not initialized');
  try {
    const vec = new Float32Array(embedding);
    // Overfetch if filtering, then apply filter via JOIN
    const fetchLimit = filters.source ? topK * 5 : topK;

    let sql = `SELECT knn.rowid, knn.distance, m.*
      FROM (SELECT rowid, distance FROM vec_chunks WHERE embedding MATCH ? ORDER BY distance LIMIT ?) knn
      JOIN chunk_meta m ON m.rowid = knn.rowid`;
    const params = [vec, fetchLimit];

    if (filters.source) {
      sql += ' WHERE m.source = ?';
      params.push(filters.source);
    }
    sql += ' ORDER BY knn.distance LIMIT ?';
    params.push(topK);

    return db.prepare(sql).all(...params);
  } catch (e) {
    console.warn('[db] Vector search failed:', e.message);
    return [];
  }
}

function getVectorMeta(docId) {
  if (!db) throw new Error('Database not initialized');
  return db.prepare('SELECT * FROM chunk_meta WHERE doc_id = ?').all(docId);
}

function getAllVectorMeta() {
  if (!db) throw new Error('Database not initialized');
  return db.prepare('SELECT doc_id, source, agent, COUNT(*) as chunk_count, MIN(indexed_at) as indexed_at FROM chunk_meta GROUP BY doc_id').all();
}

function countVectorChunks() {
  if (!db) throw new Error('Database not initialized');
  const row = db.prepare('SELECT COUNT(*) as count FROM chunk_meta').get();
  return row ? row.count : 0;
}

// ── Lesson Candidates ─────────────────────────────────────────────────────────

function createLessonCandidate(data) {
  if (!db) throw new Error('Database not initialized');
  return db.prepare(`INSERT INTO lesson_candidates (id, session_id, moment_id, title, rule, lesson_type, evidence, rationale, confidence, tags, status, extraction_model, created_at)
    VALUES (@id, @session_id, @moment_id, @title, @rule, @lesson_type, @evidence, @rationale, @confidence, @tags, @status, @extraction_model, @created_at)`).run(data);
}

function getLessonCandidates(filters = {}) {
  if (!db) throw new Error('Database not initialized');
  const { status, limit = 100 } = filters;
  if (status) {
    return db.prepare('SELECT * FROM lesson_candidates WHERE status = ? ORDER BY created_at DESC LIMIT ?').all(status, limit);
  }
  return db.prepare('SELECT * FROM lesson_candidates ORDER BY created_at DESC LIMIT ?').all(limit);
}

function getLessonCandidateByMomentAndRule(momentId, rule) {
  if (!db) throw new Error('Database not initialized');
  return db.prepare('SELECT * FROM lesson_candidates WHERE moment_id = ? AND rule = ? LIMIT 1').get(momentId, rule);
}

function updateLessonCandidate(id, data) {
  if (!db) throw new Error('Database not initialized');
  // Build dynamic SET clause from provided fields
  const allowed = ['validation_status', 'validated_at', 'dedup_similarity', 'cqs_score', 'validation_result', 'dedup_matched_id', 'promoted_to'];
  const sets = [];
  const params = { id };
  for (const key of allowed) {
    if (data[key] !== undefined) {
      sets.push(`${key} = @${key}`);
      params[key] = data[key] ?? null;
    }
  }
  if (sets.length === 0) return;
  return db.prepare(`UPDATE lesson_candidates SET ${sets.join(', ')} WHERE id = @id`).run(params);
}

// ── Lessons ───────────────────────────────────────────────────────────────────

function createLesson(data) {
  if (!db) throw new Error('Database not initialized');
  return db.prepare(`INSERT INTO lessons (id, title, rule, lesson_type, evidence, rationale, tags, source_sessions, confidence, status, embedding, created_at, reviewed_by)
    VALUES (@id, @title, @rule, @lesson_type, @evidence, @rationale, @tags, @source_sessions, @confidence, @status, @embedding, @created_at, @reviewed_by)`).run(data);
}

function getLessons(filters = {}) {
  if (!db) throw new Error('Database not initialized');
  const { status, limit = 100 } = filters;
  if (status) {
    return db.prepare('SELECT * FROM lessons WHERE status = ? ORDER BY created_at DESC LIMIT ?').all(status, limit);
  }
  return db.prepare('SELECT * FROM lessons ORDER BY created_at DESC LIMIT ?').all(limit);
}

// ── Confirmations ──────────────────────────────────────────────────────────

/**
 * Add a confirmation record: called when an extracted lesson is semantically
 * similar to an existing lesson instead of creating a duplicate.
 * Also increments confirmation_count and last_confirmed_at on the lesson.
 * @param {string} lessonId
 * @param {string} sessionId
 * @param {string|null} momentId
 * @param {number|null} similarity
 * @returns {string} confirmation id
 */
function addConfirmation(lessonId, sessionId, momentId = null, similarity = null) {
  if (!db) throw new Error('Database not initialized');
  const id = uuidv4();
  const now = new Date().toISOString();

  db.prepare(`
    INSERT INTO lesson_confirmations (id, lesson_id, session_id, moment_id, similarity, confirmed_at)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(id, lessonId, sessionId, momentId, similarity, now);

  // Increment confirmation_count and update last_confirmed_at
  db.prepare(`
    UPDATE lessons
    SET confirmation_count = COALESCE(confirmation_count, 0) + 1,
        last_confirmed_at = ?
    WHERE id = ?
  `).run(now, lessonId);

  return id;
}

/**
 * Get all confirmations for a lesson.
 * @param {string} lessonId
 * @returns {Array}
 */
function getConfirmations(lessonId) {
  if (!db) throw new Error('Database not initialized');
  return db.prepare(
    'SELECT * FROM lesson_confirmations WHERE lesson_id = ? ORDER BY confirmed_at DESC'
  ).all(lessonId);
}

/**
 * Get lessons that have at least minCount confirmations.
 * @param {number} minCount
 * @returns {Array}
 */
function getLessonsByConfirmations(minCount = 1) {
  if (!db) throw new Error('Database not initialized');
  return db.prepare(
    'SELECT * FROM lessons WHERE COALESCE(confirmation_count, 0) >= ? ORDER BY confirmation_count DESC'
  ).all(minCount);
}

// ── Triggers / Decay / Reinforcement ──────────────────────────────────────

/**
 * Record that the lesson-recall plugin injected this lesson.
 * Increments trigger_count and updates last_triggered_at.
 * Also applies a small confidence boost (+0.02).
 * @param {string} lessonId
 */
function recordLessonTrigger(lessonId) {
  if (!db) throw new Error('Database not initialized');
  const now = new Date().toISOString();
  db.prepare(`
    UPDATE lessons
    SET trigger_count = COALESCE(trigger_count, 0) + 1,
        last_triggered_at = ?,
        confidence = MIN(1.0, COALESCE(confidence, 0.5) + 0.02)
    WHERE id = ?
  `).run(now, lessonId);
}

/**
 * Decay lessons that have not been triggered in 30 days.
 * Reduces confidence by 5% (multiply by 0.95) for each such lesson.
 * Only decays lessons with status != 'archived'.
 * @returns {number} number of lessons decayed
 */
function decayLessons() {
  if (!db) throw new Error('Database not initialized');
  const cutoff = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString();
  const result = db.prepare(`
    UPDATE lessons
    SET confidence = MAX(0.0, COALESCE(confidence, 0.5) * 0.95)
    WHERE status != 'archived'
      AND (last_triggered_at IS NULL OR last_triggered_at < ?)
      AND created_at < ?
  `).run(cutoff, cutoff);
  return result.changes;
}

/**
 * Reinforce or penalise a lesson based on user feedback.
 * @param {string} lessonId
 * @param {boolean} helped — true = +0.05, false = -0.02 (trigger already gave +0.02)
 */
function reinforceLesson(lessonId, helped) {
  if (!db) throw new Error('Database not initialized');
  const delta = helped ? 0.05 : -0.02;
  db.prepare(`
    UPDATE lessons
    SET confidence = MAX(0.0, MIN(1.0, COALESCE(confidence, 0.5) + ?))
    WHERE id = ?
  `).run(delta, lessonId);
}

// ── Exports ───────────────────────────────────────────────────────────────────

module.exports = {
  // Init / Close
  init,
  close,

  // Runs
  getRuns,
  getRun,
  createRun,
  updateRun,
  getRunsByTask,
  getRunTree,
  getRunLogPath,
  cleanupStaleRuns,
  deleteRun,

  // Tasks
  getTasks,
  getTask,
  createTask,
  updateTask,
  deleteTask,
  archiveTask,
  archiveAllDone,
  restoreTask,
  getArchivedTasks,
  deleteArchivedTask,

  // Cards
  getCards,
  getCard,
  createCard,
  updateCard,
  deleteCard,

  // Events
  getEvents,
  getEvent,
  createEvent,
  updateEvent,
  deleteEvent,

  // Office
  getOfficeStatus,
  updateAgentStatus,
  getOfficeLog,
  appendOfficeLog,

  // API Keys
  getApiKeys,
  getApiKey,
  upsertApiKey,
  deleteApiKey,

  // Transactions
  transaction,

  // Pipeline State
  getPipelineState,
  setPipelineState,

  // Vector Chunks
  insertVectorChunk,
  insertVectorChunks,
  deleteVectorDoc,
  searchVectors,
  getVectorMeta,
  getAllVectorMeta,
  countVectorChunks,

  // Lesson Candidates
  createLessonCandidate,
  getLessonCandidates,
  getLessonCandidateByMomentAndRule,
  updateLessonCandidate,

  // Lessons
  createLesson,
  getLessons,

  // Confirmations
  addConfirmation,
  getConfirmations,
  getLessonsByConfirmations,

  // Triggers / Decay / Reinforcement
  recordLessonTrigger,
  decayLessons,
  reinforceLesson,

  // Internals (exposed for testing / migration)
  _db: () => db,
  LOG_DIR_MAP,
};
