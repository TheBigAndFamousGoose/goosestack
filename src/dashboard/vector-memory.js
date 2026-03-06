/**
 * GooseStack Vector Memory — embeds and searches agent logs semantically
 *
 * Uses Ollama's nomic-embed-text for local embeddings.
 * Stores vectors in SQLite via sqlite-vec (db.js).
 *
 * Usage:
 *   node vector-memory.js index              — index all unindexed logs
 *   node vector-memory.js search "query"      — semantic search
 *   node vector-memory.js reindex             — reindex everything
 *   node vector-memory.js stats               — show index stats
 */

'use strict';

const fs = require('fs');
const path = require('path');
const http = require('http');

const DATA_DIR = path.join(__dirname, 'data');
const AGENT_LOGS_DIR = path.join(DATA_DIR, 'agent-logs');
const RUNS_DIR = path.join(DATA_DIR, 'runs');

const OLLAMA_URL = 'http://localhost:11434';
const EMBED_MODEL = 'nomic-embed-text';

const META_STATE_KEY = 'vector_index_meta';

// Lazy-loaded db reference
let _db = null;
function ensureDb() {
  if (!_db) {
    _db = require('./db');
    _db.init();
  }
  return _db;
}

// ── Embedding ─────────────────────────────────────────────────────────────────

async function getEmbedding(text) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ model: EMBED_MODEL, prompt: text });
    const url = new URL(OLLAMA_URL + '/api/embeddings');
    const req = http.request({
      hostname: url.hostname,
      port: url.port,
      path: url.pathname,
      method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
      timeout: 30000,
    }, (res) => {
      let data = '';
      res.on('data', c => data += c);
      res.on('end', () => {
        try {
          const parsed = JSON.parse(data);
          if (parsed.embedding) resolve(parsed.embedding);
          else reject(new Error('No embedding in response'));
        } catch (e) { reject(e); }
      });
    });
    req.on('error', reject);
    req.write(body);
    req.end();
  });
}

// ── Chunking ──────────────────────────────────────────────────────────────────

function chunkText(text, chunkChars = 2000, overlapChars = 200) {
  const chunks = [];
  let start = 0;
  while (start < text.length) {
    let end = start + chunkChars;
    if (end < text.length) {
      const newlinePos = text.lastIndexOf('\n', end);
      if (newlinePos > start + chunkChars * 0.5) end = newlinePos;
    }
    chunks.push(text.substring(start, end).trim());
    start = end - overlapChars;
    if (start < 0) start = 0;
    if (end >= text.length) break;
  }
  return chunks.filter(c => c.length > 50);
}

// ── Cosine Similarity (kept for backward compat) ─────────────────────────────

function cosineSimilarity(a, b) {
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB));
}

// ── Legacy Shims (backed by SQLite) ──────────────────────────────────────────

function readIndex() {
  const db = ensureDb();
  return db.getAllVectorMeta().map(row => ({
    docId:      row.doc_id,
    source:     row.source,
    agent:      row.agent || null,
    chunkCount: row.chunk_count,
    indexedAt:  row.indexed_at,
  }));
}

function readMeta() {
  const db = ensureDb();
  const raw = db.getPipelineState(META_STATE_KEY);
  if (!raw) return { indexed: {}, lastRun: null };
  try { return JSON.parse(raw); } catch { return { indexed: {}, lastRun: null }; }
}

// ── Log Sources ───────────────────────────────────────────────────────────────

function getAgentLogs() {
  if (!fs.existsSync(AGENT_LOGS_DIR)) return [];
  return fs.readdirSync(AGENT_LOGS_DIR)
    .filter(f => f.endsWith('.log'))
    .map(f => ({
      id: `agent-log:${f}`,
      source: 'agent-log',
      filename: f,
      path: path.join(AGENT_LOGS_DIR, f),
      content: fs.readFileSync(path.join(AGENT_LOGS_DIR, f), 'utf8'),
    }));
}

function getRunLogs() {
  const db = require('./db');
  db.init();
  const runs = db.getRuns({ limit: 10000 });
  const logs = [];

  for (const run of runs) {
    let content = `Agent: ${run.agent}\nType: ${run.type}\nStatus: ${run.status}\nPrompt: ${run.prompt || ''}`;
    if (run.result) content += `\nResult: ${run.result}`;

    const logPath = path.join(RUNS_DIR, `${run.id}.log`);
    if (fs.existsSync(logPath)) {
      content += '\n\nLog:\n' + fs.readFileSync(logPath, 'utf8');
    }

    if (content.length > 100) {
      logs.push({
        id: `run:${run.id}`,
        source: 'run',
        runId: run.id,
        agent: run.agent,
        type: run.type,
        content,
      });
    }
  }
  return logs;
}

function getMemoryFiles() {
  const memDir = path.join(process.env.HOME || '', '.openclaw', 'workspace', 'memory');
  if (!fs.existsSync(memDir)) return [];

  const files = [];
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.isDirectory()) walk(path.join(dir, entry.name));
      else if (entry.name.endsWith('.md')) {
        const fp = path.join(dir, entry.name);
        files.push({
          id: `memory:${path.relative(memDir, fp)}`,
          source: 'memory',
          filename: entry.name,
          path: fp,
          content: fs.readFileSync(fp, 'utf8'),
        });
      }
    }
  }
  walk(memDir);
  return files;
}

function extractAgent(filename) {
  const match = filename.match(/^(claude|codex|pi|opencode)/i);
  return match ? match[1] : 'unknown';
}

// ── Indexing ──────────────────────────────────────────────────────────────────

async function indexDocuments(forceReindex = false) {
  const db = ensureDb();

  // Load tracking state from pipeline_state
  const metaRaw = db.getPipelineState(META_STATE_KEY);
  let meta;
  try { meta = metaRaw ? JSON.parse(metaRaw) : { indexed: {}, lastRun: null }; }
  catch { meta = { indexed: {}, lastRun: null }; }

  const docs = [...getAgentLogs(), ...getRunLogs(), ...getMemoryFiles()];

  let newDocs = 0, newChunks = 0, skipped = 0;

  for (const doc of docs) {
    if (!forceReindex && meta.indexed[doc.id]) {
      skipped++;
      continue;
    }

    // Remove old chunks when reindexing
    if (forceReindex && meta.indexed[doc.id]) {
      db.deleteVectorDoc(doc.id);
    }

    const chunks = chunkText(doc.content);
    const agentName = doc.agent || extractAgent(doc.filename || '');
    const indexedAt = new Date().toISOString();
    const chunkItems = [];

    for (let i = 0; i < chunks.length; i++) {
      try {
        const embedding = await getEmbedding(chunks[i]);
        chunkItems.push({
          meta: {
            doc_id:       doc.id,
            source:       doc.source,
            agent:        agentName,
            run_id:       doc.runId || null,
            chunk_index:  i,
            total_chunks: chunks.length,
            text_preview: chunks[i].substring(0, 500),
            full_text:    chunks[i],
            indexed_at:   indexedAt,
          },
          embedding,
        });
        newChunks++;
      } catch (err) {
        console.error(`  Error embedding chunk ${i} of ${doc.id}: ${err.message}`);
      }
    }

    if (chunkItems.length > 0) {
      db.insertVectorChunks(chunkItems);
    }

    meta.indexed[doc.id] = { indexedAt, chunks: chunkItems.length, source: doc.source };
    newDocs++;

    if (newDocs % 5 === 0) {
      process.stdout.write(`  Indexed ${newDocs} docs (${newChunks} chunks)...\r`);
    }
  }

  meta.lastRun = new Date().toISOString();
  db.setPipelineState(META_STATE_KEY, JSON.stringify(meta));

  const totalDocs = Object.keys(meta.indexed).length;
  const totalChunks = db.countVectorChunks();

  return { newDocs, newChunks, skipped, totalDocs, totalChunks };
}

// ── Search ────────────────────────────────────────────────────────────────────

async function search(query, topK = 5, minScore = 0.01) {
  const db = ensureDb();
  if (db.countVectorChunks() === 0) return [];

  const queryEmbedding = await getEmbedding(query);

  // Overfetch for dedup headroom
  const rawResults = db.searchVectors(queryEmbedding, topK * 3);

  // Deduplicate by doc_id, keep lowest distance (highest score) per doc
  // Convert L2 distance → score: 1/(1+distance) — higher is better, 0–1 range
  const bestByDoc = new Map();
  for (const row of rawResults) {
    const score = 1 / (1 + row.distance);
    if (score < minScore) continue;
    const existing = bestByDoc.get(row.doc_id);
    if (!existing || score > existing.score) {
      bestByDoc.set(row.doc_id, {
        docId:       row.doc_id,
        source:      row.source,
        agent:       row.agent || null,
        score:       Math.round(score * 1000) / 1000,
        chunkIndex:  row.chunk_index,
        totalChunks: row.total_chunks,
        text:        row.text_preview || row.full_text || '',
      });
    }
  }

  return Array.from(bestByDoc.values())
    .sort((a, b) => b.score - a.score)
    .slice(0, topK);
}

// ── Stats ─────────────────────────────────────────────────────────────────────

function stats() {
  const db = ensureDb();
  const totalChunks = db.countVectorChunks();
  const allMeta = db.getAllVectorMeta();

  const metaRaw = db.getPipelineState(META_STATE_KEY);
  let lastIndexed = null;
  try { lastIndexed = metaRaw ? JSON.parse(metaRaw).lastRun : null; } catch {}

  const bySource = {};
  for (const row of allMeta) {
    bySource[row.source || 'unknown'] = (bySource[row.source || 'unknown'] || 0) + 1;
  }

  return { totalChunks, totalDocuments: allMeta.length, lastIndexed, bySource };
}

// ── CLI ───────────────────────────────────────────────────────────────────────

async function main() {
  const cmd = process.argv[2] || 'stats';

  switch (cmd) {
    case 'index': {
      console.log('Indexing new documents...');
      const result = await indexDocuments(false);
      console.log(`Done: ${result.newDocs} new docs, ${result.newChunks} new chunks, ${result.skipped} skipped`);
      console.log(`Total: ${result.totalDocs} docs, ${result.totalChunks} chunks`);
      break;
    }
    case 'reindex': {
      console.log('Reindexing all documents...');
      const result = await indexDocuments(true);
      console.log(`Done: ${result.newDocs} docs, ${result.newChunks} chunks indexed`);
      break;
    }
    case 'search': {
      const query = process.argv.slice(3).join(' ');
      if (!query) { console.error('Usage: node vector-memory.js search "your query"'); process.exit(1); }
      console.log(`Searching for: "${query}"`);
      const results = await search(query);
      if (results.length === 0) console.log('No results found.');
      else {
        for (const r of results) {
          console.log(`\n[${r.score}] ${r.source} | ${r.agent || 'N/A'} | chunk ${r.chunkIndex + 1}/${r.totalChunks}`);
          console.log(`  Doc: ${r.docId}`);
          console.log(`  ${r.text.substring(0, 200)}...`);
        }
      }
      break;
    }
    case 'stats': {
      const s = stats();
      console.log('Vector Memory Stats:');
      console.log(`  Last run:    ${s.lastIndexed || 'never'}`);
      console.log(`  Total docs:  ${s.totalDocuments}`);
      console.log(`  Total chunks: ${s.totalChunks}`);
      console.log('  By source:', s.bySource);
      break;
    }
    default:
      console.log('Usage: node vector-memory.js [index|reindex|search|stats]');
  }
}

// ── Exports ───────────────────────────────────────────────────────────────────

module.exports = { search, indexDocuments, indexAllLogs: indexDocuments, readIndex, readMeta, getEmbedding, chunkText, cosineSimilarity, stats };

if (require.main === module) main().catch(console.error);
