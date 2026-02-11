/**
 * db.js — SQLite storage layer for GooseStack API
 *
 * Single-file database. No migrations framework needed — we create tables
 * on first run and they persist. All money is tracked in cents (integers)
 * to avoid floating-point issues.
 */

const Database = require('better-sqlite3');
const path = require('path');
const crypto = require('crypto');

const DB_PATH = process.env.DB_PATH || path.join(__dirname, 'goosestack.db');

const db = new Database(DB_PATH, { verbose: process.env.DB_VERBOSE ? console.log : null });

// ----- Pragmas for performance + safety -----
db.pragma('journal_mode = WAL');       // concurrent reads while writing
db.pragma('synchronous = NORMAL');     // safe with WAL
db.pragma('foreign_keys = ON');
db.pragma('busy_timeout = 5000');      // wait up to 5s on lock

// ----- Schema -----
db.exec(`
  CREATE TABLE IF NOT EXISTS users (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    email         TEXT UNIQUE NOT NULL,
    stripe_customer_id TEXT UNIQUE,
    pro_until     TEXT,                -- ISO 8601 datetime, NULL if not pro
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS api_keys (
    key_hash      TEXT PRIMARY KEY,    -- SHA-256 of the raw key
    key_prefix    TEXT NOT NULL,       -- first 12 chars for display (gsk_xxxx...)
    user_id       INTEGER NOT NULL REFERENCES users(id),
    name          TEXT NOT NULL DEFAULT 'default',
    created_at    TEXT NOT NULL DEFAULT (datetime('now')),
    revoked       INTEGER NOT NULL DEFAULT 0
  );

  CREATE TABLE IF NOT EXISTS credits (
    user_id       INTEGER PRIMARY KEY REFERENCES users(id),
    balance_cents INTEGER NOT NULL DEFAULT 0,
    updated_at    TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE TABLE IF NOT EXISTS usage_log (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id       INTEGER NOT NULL REFERENCES users(id),
    provider      TEXT NOT NULL,       -- 'openai' | 'anthropic'
    model         TEXT NOT NULL,
    input_tokens  INTEGER NOT NULL DEFAULT 0,
    output_tokens INTEGER NOT NULL DEFAULT 0,
    cost_cents    INTEGER NOT NULL DEFAULT 0,
    created_at    TEXT NOT NULL DEFAULT (datetime('now'))
  );

  CREATE INDEX IF NOT EXISTS idx_usage_user    ON usage_log(user_id);
  CREATE INDEX IF NOT EXISTS idx_usage_created ON usage_log(created_at);
  CREATE INDEX IF NOT EXISTS idx_keys_user     ON api_keys(user_id);
`);

// ============================================================
// User helpers
// ============================================================

/**
 * Find or create a user by email. Returns the user row.
 */
const findOrCreateUser = db.transaction((email) => {
  let user = db.prepare('SELECT * FROM users WHERE email = ?').get(email);
  if (!user) {
    const info = db.prepare('INSERT INTO users (email) VALUES (?)').run(email);
    user = db.prepare('SELECT * FROM users WHERE id = ?').get(info.lastInsertRowid);
    // Initialize credit balance
    db.prepare('INSERT INTO credits (user_id, balance_cents) VALUES (?, 0)').run(user.id);
  }
  return user;
});

function getUserById(id) {
  return db.prepare('SELECT * FROM users WHERE id = ?').get(id);
}

function getUserByStripeCustomer(stripeCustomerId) {
  return db.prepare('SELECT * FROM users WHERE stripe_customer_id = ?').get(stripeCustomerId);
}

function setStripeCustomerId(userId, stripeCustomerId) {
  db.prepare('UPDATE users SET stripe_customer_id = ? WHERE id = ?').run(stripeCustomerId, userId);
}

function setProUntil(userId, isoDate) {
  db.prepare('UPDATE users SET pro_until = ? WHERE id = ?').run(isoDate, userId);
}

/**
 * Check if user currently has an active Pro subscription.
 */
function isProActive(user) {
  if (!user.pro_until) return false;
  return new Date(user.pro_until) > new Date();
}

// ============================================================
// API key helpers
// ============================================================

/**
 * Hash a raw API key for storage. We never store the raw key.
 */
function hashKey(rawKey) {
  return crypto.createHash('sha256').update(rawKey).digest('hex');
}

/**
 * Generate a new API key for a user. Returns the RAW key (only time it's visible).
 */
function createApiKey(userId, name = 'default') {
  const rawKey = 'gsk_' + crypto.randomBytes(24).toString('hex'); // 48 hex chars
  const keyHash = hashKey(rawKey);
  const keyPrefix = rawKey.slice(0, 12) + '...';

  db.prepare(
    'INSERT INTO api_keys (key_hash, key_prefix, user_id, name) VALUES (?, ?, ?, ?)'
  ).run(keyHash, keyPrefix, userId, name);

  return { raw_key: rawKey, prefix: keyPrefix, name };
}

/**
 * Look up user by raw API key. Returns user row or undefined.
 */
function getUserByApiKey(rawKey) {
  const keyHash = hashKey(rawKey);
  const row = db.prepare(`
    SELECT u.* FROM users u
    JOIN api_keys ak ON ak.user_id = u.id
    WHERE ak.key_hash = ? AND ak.revoked = 0
  `).get(keyHash);
  return row;
}

function listApiKeys(userId) {
  return db.prepare(
    'SELECT key_prefix, name, created_at, revoked FROM api_keys WHERE user_id = ? ORDER BY created_at DESC'
  ).all(userId);
}

function revokeApiKey(userId, keyPrefix) {
  return db.prepare(
    'UPDATE api_keys SET revoked = 1 WHERE user_id = ? AND key_prefix = ?'
  ).run(userId, keyPrefix);
}

// ============================================================
// Credit helpers
// ============================================================

function getBalance(userId) {
  const row = db.prepare('SELECT balance_cents FROM credits WHERE user_id = ?').get(userId);
  return row ? row.balance_cents : 0;
}

/**
 * Add credits (positive amount). Used after Stripe payment confirmation.
 */
function addCredits(userId, amountCents) {
  if (amountCents <= 0) throw new Error('Amount must be positive');
  db.prepare(`
    INSERT INTO credits (user_id, balance_cents, updated_at)
    VALUES (?, ?, datetime('now'))
    ON CONFLICT(user_id) DO UPDATE SET
      balance_cents = balance_cents + excluded.balance_cents,
      updated_at = datetime('now')
  `).run(userId, amountCents);
}

/**
 * Deduct credits atomically. Returns true if successful, false if insufficient.
 * This is the critical path — NEVER allow negative balance.
 */
const deductCredits = db.transaction((userId, costCents) => {
  if (costCents <= 0) return true; // free request, sure
  const row = db.prepare('SELECT balance_cents FROM credits WHERE user_id = ?').get(userId);
  if (!row || row.balance_cents < costCents) return false;

  db.prepare(`
    UPDATE credits SET balance_cents = balance_cents - ?, updated_at = datetime('now')
    WHERE user_id = ?
  `).run(costCents, userId);
  return true;
});

// ============================================================
// Usage log helpers
// ============================================================

function logUsage(userId, provider, model, inputTokens, outputTokens, costCents) {
  db.prepare(`
    INSERT INTO usage_log (user_id, provider, model, input_tokens, output_tokens, cost_cents)
    VALUES (?, ?, ?, ?, ?, ?)
  `).run(userId, provider, model, inputTokens, outputTokens, costCents);
}

/**
 * Get usage summary for a user. Optionally filtered by date range.
 */
function getUsageSummary(userId, sinceIso = null) {
  const since = sinceIso || new Date(Date.now() - 30 * 86400000).toISOString();
  return db.prepare(`
    SELECT
      provider,
      model,
      COUNT(*) as requests,
      SUM(input_tokens) as total_input_tokens,
      SUM(output_tokens) as total_output_tokens,
      SUM(cost_cents) as total_cost_cents
    FROM usage_log
    WHERE user_id = ? AND created_at >= ?
    GROUP BY provider, model
    ORDER BY total_cost_cents DESC
  `).all(userId, since);
}

function getRecentUsage(userId, limit = 20) {
  return db.prepare(`
    SELECT provider, model, input_tokens, output_tokens, cost_cents, created_at
    FROM usage_log WHERE user_id = ?
    ORDER BY created_at DESC LIMIT ?
  `).all(userId, limit);
}

// ============================================================
// Exports
// ============================================================

module.exports = {
  db,
  // Users
  findOrCreateUser,
  getUserById,
  getUserByStripeCustomer,
  setStripeCustomerId,
  setProUntil,
  isProActive,
  // API keys
  hashKey,
  createApiKey,
  getUserByApiKey,
  listApiKeys,
  revokeApiKey,
  // Credits
  getBalance,
  addCredits,
  deductCredits,
  // Usage
  logUsage,
  getUsageSummary,
  getRecentUsage,
};
