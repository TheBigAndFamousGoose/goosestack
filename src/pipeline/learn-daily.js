#!/usr/bin/env node
'use strict';

/**
 * learn-daily.js — Daily Learning Pipeline Orchestrator
 *
 * Chains the full pipeline for new sessions:
 *   1. Parse new session JSONL files (incremental)
 *   2. Extract signals + score moments
 *   3. Classify moments → extract lessons (BAD via learn-extract-all, GOOD via learn-extract-good)
 *   4. Run validation pipeline P1→P2→P3→P4
 *   5. Stage candidates for Opus review (NOT auto-promote)
 *
 * Safety: headless pipeline NEVER writes SOUL.md/MEMORY.md.
 *         Lessons are staged, not promoted — Opus reviews in active session.
 *
 * Usage:
 *   node learn-daily.js                 # Process new sessions
 *   node learn-daily.js --all           # Reprocess all sessions
 *   node learn-daily.js --dry-run       # Parse + signal only, no extraction
 *   node learn-daily.js --stats         # Show pipeline statistics
 *
 * Designed to run from heartbeat cron or manually.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');

const { parseNewSessions, markProcessed } = require('./learn-parse');
const { extractSignalsScored } = require('./learn-signals');

// ── Config ──────────────────────────────────────────────────────────────────

const AUTH_FILE = path.join(process.env.HOME, '.openclaw', 'auth-profiles-v2.json');
const RESULTS_DIR = path.join(__dirname, 'data', 'daily-results');
const LOG_DIR = path.join(__dirname, 'data', 'daily-logs');
const GEMINI_MODEL = 'gemini-2.5-flash';
const API_BASE = 'generativelanguage.googleapis.com';

const MIN_MOMENT_SCORE = 0.3;  // minimum score to consider extraction
const BAD_EXTRACTION_BATCH_SIZE = 10;
const GOOD_EXTRACTION_BATCH_SIZE = 10;

// ── Helpers ─────────────────────────────────────────────────────────────────

function getGeminiApiKey() {
  const data = JSON.parse(fs.readFileSync(AUTH_FILE, 'utf8'));
  const gemini = data.profiles?.['gemini:default'] || data.profiles?.['google:default'];
  if (!gemini?.api_key) throw new Error('No Gemini API key in auth-profiles-v2.json');
  return gemini.api_key;
}

function callGemini(apiKey, prompt) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      generationConfig: { temperature: 0.2, maxOutputTokens: 8192, responseMimeType: 'application/json' },
    });
    const req = https.request({
      hostname: API_BASE,
      path: '/v1beta/models/' + GEMINI_MODEL + ':generateContent',
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'x-goog-api-key': apiKey },
    }, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode !== 200) { reject(new Error('Gemini ' + res.statusCode + ': ' + data.slice(0, 200))); return; }
        try {
          const parsed = JSON.parse(data);
          const text = parsed.candidates?.[0]?.content?.parts?.[0]?.text;
          if (!text) reject(new Error('No text in Gemini response'));
          else resolve(text);
        } catch (e) { reject(new Error('JSON parse: ' + e.message)); }
      });
    });
    req.on('error', reject);
    req.setTimeout(60000, () => { req.destroy(); reject(new Error('timeout')); });
    req.write(body);
    req.end();
  });
}

function extractJson(text) {
  try { return JSON.parse(text.trim()); } catch {}
  const m = text.match(/```(?:json)?\s*\n?([\s\S]*?)```/);
  if (m) { try { return JSON.parse(m[1].trim()); } catch {} }
  return null;
}

function ensureDir(dir) {
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
}

function log(msg) {
  const ts = new Date().toISOString().slice(11, 19);
  console.log('[' + ts + '] ' + msg);
}

// ── Extraction Prompts ──────────────────────────────────────────────────────

function buildBadPrompt(moments) {
  // Reuse the prompt from learn-extract-all.js (simplified for daily use)
  const { buildQualityReviewPrompt } = require('./learn-validate-prompts');
  return 'You are AgentAnalyst extracting lessons from BAD AI agent moments.\n\n' +
    'For each moment: extract 0-2 specific, actionable IF/THEN lessons.\n' +
    'Quality gates: must have verbatim evidence quote (30+ chars), specific IF/THEN, no banned phrases.\n' +
    'Banned: "be careful", "double-check", "think step-by-step", "plan better"\n' +
    'Categories: tool_use | prompting | planning | safety | reliability | user_prefs\n\n' +
    'Return JSON: {"results": [{"moment_id":"...", "performance":"BAD", "lessons":[{"title":"...", "if_then_guideline":"IF ... THEN ...", "lesson_type":"...", "evidence":"...", "rationale":"...", "confidence":0.0-1.0, "tags":[]}]}]}\n\n' +
    'MOMENTS:\n\n' + moments;
}

function buildGoodPrompt(moments) {
  return 'You are AgentAnalyst extracting positive techniques from GOOD AI agent moments.\n\n' +
    'For each moment: extract 0-1 specific, replicable techniques.\n' +
    'Quality gates: must name a concrete object (tool, API, pattern), must have anti-pattern it prevents.\n' +
    'Banned: "be helpful", "be thorough", "be clear", "do a good job"\n' +
    'Categories: tool_use | prompting | planning | safety | reliability | user_prefs\n\n' +
    'Return JSON: {"results": [{"moment_id":"...", "performance":"GOOD", "lessons":[{"title":"...", "if_then_guideline":"IF ... THEN ...", "lesson_type":"...", "evidence":"...", "rationale":"...", "confidence":0.0-1.0, "tags":[]}]}]}\n\n' +
    'MOMENTS:\n\n' + moments;
}

// ── Main Pipeline ───────────────────────────────────────────────────────────

function acquireLock(db) {
  const raw = db._db();
  raw.exec("CREATE TABLE IF NOT EXISTS pipeline_locks (name TEXT PRIMARY KEY, pid INTEGER, acquired_at TEXT)");
  // Check for stale lock (older than 30 min)
  const existing = raw.prepare("SELECT pid, acquired_at FROM pipeline_locks WHERE name = 'learn-daily'").get();
  if (existing) {
    const age = Date.now() - new Date(existing.acquired_at).getTime();
    if (age < 30 * 60 * 1000) {
      return false; // Lock held by recent process
    }
    // Stale lock, take over
  }
  raw.prepare("INSERT OR REPLACE INTO pipeline_locks (name, pid, acquired_at) VALUES ('learn-daily', ?, ?)").run(process.pid, new Date().toISOString());
  return true;
}

function releaseLock(db) {
  try { db._db().prepare("DELETE FROM pipeline_locks WHERE name = 'learn-daily' AND pid = ?").run(process.pid); } catch {}
}

async function runDaily(options) {
  const dryRun = options.dryRun || false;
  const dateStr = new Date().toISOString().slice(0, 10);
  
  ensureDir(RESULTS_DIR);
  ensureDir(LOG_DIR);

  log('=== Daily Learning Pipeline ' + dateStr + (dryRun ? ' [DRY RUN]' : '') + ' ===');

  // ── Step 1: Parse new sessions ──
  log('Step 1: Parsing new sessions...');
  let sessions;
  try {
    sessions = await parseNewSessions();
  } catch (e) {
    log('ERROR parsing sessions: ' + e.message);
    return { error: e.message };
  }

  if (!sessions || sessions.length === 0) {
    log('No new sessions to process.');
    return { sessions: 0, moments: 0, lessons: 0 };
  }
  log('Found ' + sessions.length + ' new session(s)');

  // ── Step 2: Extract signals + score ──
  log('Step 2: Extracting signals and scoring...');
  let allMoments = [];
  
  for (const session of sessions) {
    try {
      const moments = extractSignalsScored(session);
      const scored = moments.filter(m => (m.score || m.finalScore || 0) >= MIN_MOMENT_SCORE);
      if (scored.length > 0) {
        log('  ' + session.sessionId?.slice(0, 8) + ': ' + scored.length + ' moments (of ' + moments.length + ' detected)');
      }
      allMoments = allMoments.concat(scored.map(m => ({ ...m, sessionId: session.sessionId })));
    } catch (e) {
      log('  ERROR on session ' + (session.sessionId?.slice(0, 8) || '?') + ': ' + e.message);
    }
  }

  log('Total scored moments: ' + allMoments.length);

  if (allMoments.length === 0) {
    log('No significant moments found. Marking sessions as processed.');
    if (!dryRun) {
      for (const s of sessions) {
        try { markProcessed(s.filePath || s.sessionId); } catch {}
      }
    }
    return { sessions: sessions.length, moments: 0, lessons: 0 };
  }

  // ── Step 3: Classify and prepare for extraction ──
  // Heuristics that indicate problems → BAD; others → send to BOTH prompts (let Gemini classify)
  const BAD_HEURISTICS = ['user_correction', 'user_comparative_clarification', 'tool_error_recovery', 'tool_loop_break'];
  const badMoments = allMoments.filter(m => BAD_HEURISTICS.includes(m.heuristic) || m.classification === 'BAD');
  // All non-bad moments go to GOOD extraction (Gemini will skip if not actually good)
  const goodMoments = allMoments.filter(m => !BAD_HEURISTICS.includes(m.heuristic) && m.classification !== 'BAD');
  const neutralMoments = allMoments.filter(m => m.classification === 'NEUTRAL');

  log('Classification: BAD=' + badMoments.length + ' GOOD=' + goodMoments.length + ' NEUTRAL=' + neutralMoments.length);

  if (dryRun) {
    log('DRY RUN — skipping extraction, validation, and DB writes.');
    log('Moments preview:');
    allMoments.slice(0, 10).forEach(m => {
      log('  [' + (m.classification || '?') + '] ' + (m.heuristic || '?') + ': ' + (m.triggerContent || '').slice(0, 80));
    });
    return { sessions: sessions.length, moments: allMoments.length, lessons: 0, dryRun: true };
  }

  // ── Step 4: Extract lessons via Gemini Flash ──
  log('Step 3: Extracting lessons via Gemini Flash...');
  const apiKey = getGeminiApiKey();
  let allLessons = [];
  const db = require('./db');
  db.init();

  // Acquire concurrency lock
  if (!dryRun && !acquireLock(db)) {
    log('Another learn-daily.js is already running. Exiting.');
    return { sessions: sessions.length, moments: allMoments.length, lessons: 0, skipped: 'locked' };
  }

  try { // try/finally to ensure lock release on any exception

  // BAD moments extraction
  if (badMoments.length > 0) {
    log('  Extracting from ' + badMoments.length + ' BAD moments...');
    const batches = [];
    for (let i = 0; i < badMoments.length; i += BAD_EXTRACTION_BATCH_SIZE) {
      batches.push(badMoments.slice(i, i + BAD_EXTRACTION_BATCH_SIZE));
    }
    
    for (let bi = 0; bi < batches.length; bi++) {
      const batch = batches[bi];
      const momentsText = batch.map(m =>
        '--- MOMENT ' + m.momentId + ' ---\n' +
        'Heuristic: ' + (m.heuristic || '?') + '\n' +
        'Score: ' + (m.score || m.finalScore || 0) + '\n' +
        (m.contextBefore ? 'Context before: ' + m.contextBefore.slice(0, 500) + '\n' : '') +
        'Trigger: ' + (m.triggerContent || '').slice(0, 1000) + '\n' +
        (m.contextAfter ? 'Context after: ' + m.contextAfter.slice(0, 500) + '\n' : '')
      ).join('\n');

      try {
        const resp = await callGemini(apiKey, buildBadPrompt(momentsText));
        const parsed = extractJson(resp);
        if (parsed?.results) {
          for (const r of parsed.results) {
            for (const lesson of (r.lessons || [])) {
              if (lesson.confidence >= 0.3) {
                allLessons.push({ ...lesson, source: 'BAD', momentId: r.moment_id });
              }
            }
          }
        }
        log('  Batch ' + (bi + 1) + '/' + batches.length + ': ' + ((parsed?.results || []).flatMap(r => r.lessons || []).filter(l => l.confidence >= 0.3).length) + ' lessons');
      } catch (e) {
        log('  ERROR batch ' + (bi + 1) + ': ' + e.message);
      }
    }
  }

  // GOOD moments extraction
  if (goodMoments.length > 0) {
    log('  Extracting from ' + goodMoments.length + ' GOOD moments...');
    const batches = [];
    for (let i = 0; i < goodMoments.length; i += GOOD_EXTRACTION_BATCH_SIZE) {
      batches.push(goodMoments.slice(i, i + GOOD_EXTRACTION_BATCH_SIZE));
    }

    for (let bi = 0; bi < batches.length; bi++) {
      const batch = batches[bi];
      const momentsText = batch.map(m =>
        '--- MOMENT ' + m.momentId + ' ---\n' +
        'Heuristic: ' + (m.heuristic || '?') + '\n' +
        'Score: ' + (m.score || m.finalScore || 0) + '\n' +
        (m.contextBefore ? 'Context before: ' + m.contextBefore.slice(0, 500) + '\n' : '') +
        'Trigger: ' + (m.triggerContent || '').slice(0, 1000) + '\n' +
        (m.contextAfter ? 'Context after: ' + m.contextAfter.slice(0, 500) + '\n' : '')
      ).join('\n');

      try {
        const resp = await callGemini(apiKey, buildGoodPrompt(momentsText));
        const parsed = extractJson(resp);
        if (parsed?.results) {
          for (const r of parsed.results) {
            for (const lesson of (r.lessons || [])) {
              if (lesson.confidence >= 0.3) {
                allLessons.push({ ...lesson, source: 'GOOD', momentId: r.moment_id });
              }
            }
          }
        }
        log('  Batch ' + (bi + 1) + '/' + batches.length + ': ' + ((parsed?.results || []).flatMap(r => r.lessons || []).filter(l => l.confidence >= 0.3).length) + ' lessons');
      } catch (e) {
        log('  ERROR batch ' + (bi + 1) + ': ' + e.message);
      }
    }
  }

  log('Total extracted: ' + allLessons.length + ' lessons');

  // ── Step 5: Store as candidates (with confirmation dedup) ──
  log('Step 4: Storing candidates in DB (confirmation dedup enabled)...');
  let stored = 0;
  let confirmations = 0;

  // Load ALL non-archived lessons for confirmation matching (no limit truncation)
  const existingLessons = db.getLessons({ limit: 10000 });
  // Build embeddings for existing lessons (in-memory cosine, no Ollama needed —
  // embeddings are stored as BLOBs; decode only the ones that have them)
  function blobToEmbedding(blob) {
    if (!blob) return null;
    try {
      const buf = Buffer.isBuffer(blob) ? blob : Buffer.from(blob);
      const f32 = new Float32Array(buf.buffer, buf.byteOffset, buf.byteLength / 4);
      return Array.from(f32);
    } catch { return null; }
  }
  function cosineSim(a, b) {
    if (!a || !b || a.length !== b.length) return 0;
    let dot = 0, na = 0, nb = 0;
    for (let i = 0; i < a.length; i++) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i]; }
    const d = Math.sqrt(na) * Math.sqrt(nb);
    return d === 0 ? 0 : dot / d;
  }

  const CONFIRMATION_SIM_THRESHOLD = 0.85;

  // Helper: get Ollama embedding for a lesson text
  async function lessonEmbedding(lesson) {
    const text = (lesson.title || '') + ' ' + (lesson.if_then_guideline || lesson.rule || '');
    try {
      const resp = await fetch('http://localhost:11434/api/embeddings', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ model: 'nomic-embed-text', prompt: text }),
        signal: AbortSignal.timeout(10000),
      });
      if (!resp.ok) { log('  ⚠️ Ollama embedding failed: HTTP ' + resp.status); return null; }
      const data = await resp.json();
      return data.embedding || null;
    } catch (e) { log('  ⚠️ Ollama embedding unavailable: ' + e.message + ' (confirmation dedup disabled for this lesson)'); return null; }
  }

  for (const lesson of allLessons) {
    try {
      // Get embedding for this extracted lesson
      const candidateEmb = await lessonEmbedding(lesson);
      
      // Check against existing lessons for confirmation
      let bestSim = 0, bestLesson = null;
      if (candidateEmb) {
        for (const existing of existingLessons) {
          const existingEmb = blobToEmbedding(existing.embedding);
          if (!existingEmb) continue;
          const sim = cosineSim(candidateEmb, existingEmb);
          if (sim > bestSim) { bestSim = sim; bestLesson = existing; }
        }
      }

      if (bestSim >= CONFIRMATION_SIM_THRESHOLD && bestLesson) {
        // This is a confirmation of an existing lesson, not a new candidate
        const sessionId = lesson.momentId?.split(':')[0] || 'unknown';
        db.addConfirmation(bestLesson.id, sessionId, lesson.momentId || null, bestSim);
        confirmations++;
        log('  📌 CONFIRMATION [' + bestSim.toFixed(3) + '] → "' + bestLesson.title + '"');

        // Promotion rule: move from 'probationary' to 'confirmed' if confirmation_count >= 1
        const updated = db._db().prepare("SELECT * FROM lessons WHERE id = ?").get(bestLesson.id);
        if (updated && updated.status === 'probationary' && (updated.confirmation_count || 0) >= 1) {
          db._db().prepare("UPDATE lessons SET status = 'confirmed' WHERE id = ?").run(bestLesson.id);
          log('  🎓 PROMOTED to confirmed: "' + bestLesson.title + '"');
        }
        continue;
      }

      // Not similar enough — store as new candidate
      const id = crypto.randomUUID();
      db.createLessonCandidate({
        id,
        session_id: lesson.momentId?.split(':')[0] || 'unknown',
        moment_id: lesson.momentId || 'unknown',
        title: lesson.title,
        rule: lesson.if_then_guideline,
        lesson_type: lesson.lesson_type,
        evidence: lesson.evidence,
        rationale: (lesson.rationale || '') + ' [SOURCE: ' + lesson.source + ' moment]',
        confidence: lesson.confidence,
        tags: JSON.stringify(lesson.tags || []),
        status: 'pending',
        extraction_model: GEMINI_MODEL,
        created_at: new Date().toISOString(),
      });
      stored++;
    } catch (e) {
      if (!e.message.includes('UNIQUE')) {
        log('  Store error: ' + e.message);
      }
    }
  }
  log('Stored ' + stored + ' new candidates, ' + confirmations + ' confirmations');

  // ── Step 6: Run validation pipeline (stage, NOT promote) ──
  log('Step 5: Running validation pipeline...');
  
  try {
    const { runFullPipeline } = require('./learn-validate-pipeline');
    const stats = await runFullPipeline({ dryRun: false, headless: true });
    if (stats) {
      log('Validation: P3 approved=' + (stats.p3_approved || 0) + ' P4 approved=' + (stats.p4_approved || 0) + ' Promoted=' + (stats.promoted || 0));
    }
  } catch (e) {
    log('Validation error: ' + e.message);
    log('(Candidates stored — can run validation manually)');
  }

  // ── Step 6b: Decay stale lessons ──
  log('Step 5b: Running lesson decay...');
  try {
    const decayed = db.decayLessons();
    if (decayed > 0) log('  📉 Decayed confidence for ' + decayed + ' lessons (not triggered in 30d)');
  } catch (e) {
    log('  Decay error (non-fatal): ' + e.message);
  }

  // ── Step 7: Mark sessions processed ──
  log('Step 6: Marking sessions processed...');
  for (const s of sessions) {
    try { markProcessed(s.filePath || s.sessionId); } catch {}
  }

  // ── Save daily log ──
  const logFile = path.join(LOG_DIR, dateStr + '.json');
  const result = {
    date: dateStr,
    sessions: sessions.length,
    moments: allMoments.length,
    bad: badMoments.length,
    good: goodMoments.length,
    neutral: neutralMoments.length,
    lessonsExtracted: allLessons.length,
    candidatesStored: stored,
    timestamp: new Date().toISOString(),
  };
  fs.writeFileSync(logFile, JSON.stringify(result, null, 2));

  log('=== Pipeline complete. Log: ' + logFile + ' ===');
  return result;

  } finally {
    // Always release lock, even on exception
    if (!dryRun) releaseLock(db);
  }
}

// ── Stats ───────────────────────────────────────────────────────────────────

function showStats() {
  const db = require('./db');
  db.init();
  const raw = db._db();

  const lessons = raw.prepare("SELECT COUNT(*) as c FROM lessons WHERE status != 'archived'").get().c;
  const archived = raw.prepare("SELECT COUNT(*) as c FROM lessons WHERE status = 'archived'").get().c;
  const candidates = raw.prepare("SELECT COUNT(*) as c FROM lesson_candidates").get().c;
  const unvalidated = raw.prepare("SELECT COUNT(*) as c FROM lesson_candidates WHERE validation_status = 'unvalidated' OR validation_status IS NULL").get().c;

  console.log('\n=== Learning Pipeline Stats ===');
  console.log('Active lessons:      ' + lessons);
  console.log('Archived lessons:    ' + archived);
  console.log('Total candidates:    ' + candidates);
  console.log('Unvalidated:         ' + unvalidated);

  // Daily logs
  ensureDir(LOG_DIR);
  const logs = fs.readdirSync(LOG_DIR).filter(f => f.endsWith('.json')).sort().reverse();
  if (logs.length > 0) {
    console.log('\nRecent runs:');
    logs.slice(0, 7).forEach(f => {
      try {
        const d = JSON.parse(fs.readFileSync(path.join(LOG_DIR, f), 'utf8'));
        console.log('  ' + d.date + ': ' + d.sessions + ' sessions, ' + d.moments + ' moments, ' + d.lessonsExtracted + ' lessons');
      } catch {}
    });
  }
}

// ── CLI ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);

  if (args.includes('--stats')) {
    showStats();
    return;
  }

  const options = {
    dryRun: args.includes('--dry-run'),
    all: args.includes('--all'),
  };

  const result = await runDaily(options);
  if (result.error) {
    process.exit(1);
  }
}

module.exports = { runDaily, showStats };

if (require.main === module) main().catch(e => { console.error(e); process.exit(1); });
