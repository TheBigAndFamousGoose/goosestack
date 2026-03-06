#!/usr/bin/env node
'use strict';

/**
 * learn-extract-all.js — Standalone batch extraction script
 * 
 * Calls Gemini Flash directly via the Google AI API.
 * No Opus orchestration needed — runs as a cron job or manually.
 * 
 * Usage:
 *   node learn-extract-all.js                    # Extract all unprocessed batches
 *   node learn-extract-all.js --batch 5          # Extract specific batch
 *   node learn-extract-all.js --retry-failed     # Re-run failed batches
 *   node learn-extract-all.js --concurrency 3    # Parallel requests (default: 3)
 */

const fs = require('fs');
const path = require('path');
const https = require('https');
const crypto = require('crypto');

// ── Config ──────────────────────────────────────────────────────────────────

const AUTH_FILE = path.join(process.env.HOME, '.openclaw', 'auth-profiles-v2.json');
const RESULTS_DIR = path.join(__dirname, 'data', 'extraction-results');
const BATCH_DIR = path.join(__dirname, 'data', 'extraction-batches');
const STATE_FILE = path.join(__dirname, 'data', 'extraction-state.json');

const MODEL = 'gemini-2.5-flash';
const API_BASE = 'generativelanguage.googleapis.com';
const MAX_RETRIES = 2;
const RETRY_DELAY_MS = 3000;
const DEFAULT_CONCURRENCY = 3;

// ── Helpers ─────────────────────────────────────────────────────────────────

function getApiKey() {
  const data = JSON.parse(fs.readFileSync(AUTH_FILE, 'utf8'));
  const gemini = data.profiles?.['gemini:default'] || data.profiles?.['google:default'];
  if (!gemini?.api_key) throw new Error('No Gemini API key found in auth-profiles-v2.json');
  return gemini.api_key;
}

function loadState() {
  if (fs.existsSync(STATE_FILE)) return JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
  return { completed: {}, failed: {}, lastRun: null };
}

function saveState(state) {
  state.lastRun = new Date().toISOString();
  const tempFile = `${STATE_FILE}.tmp-${process.pid}-${Date.now()}`;
  fs.writeFileSync(tempFile, JSON.stringify(state, null, 2));
  fs.renameSync(tempFile, STATE_FILE);
}

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

// ── Gemini API ──────────────────────────────────────────────────────────────

function callGemini(apiKey, prompt) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({
      contents: [{ role: 'user', parts: [{ text: prompt }] }],
      generationConfig: {
        temperature: 0.3,
        maxOutputTokens: 8192,
        responseMimeType: 'application/json',
      },
    });

    const options = {
      hostname: API_BASE,
      path: `/v1beta/models/${MODEL}:generateContent`,
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(body),
        'x-goog-api-key': apiKey,
      },
    };

    const req = https.request(options, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        if (res.statusCode !== 200) {
          reject(new Error(`Gemini API ${res.statusCode}: ${data.slice(0, 200)}`));
          return;
        }
        try {
          const parsed = JSON.parse(data);
          const text = parsed.candidates?.[0]?.content?.parts?.[0]?.text;
          if (!text) reject(new Error('No text in Gemini response'));
          else resolve(text);
        } catch(e) { reject(new Error('JSON parse error: ' + e.message)); }
      });
    });

    req.on('error', reject);
    req.setTimeout(60000, () => { req.destroy(); reject(new Error('Timeout')); });
    req.write(body);
    req.end();
  });
}

// ── JSON Repair ─────────────────────────────────────────────────────────────

function repairJSON(text) {
  // Remove markdown fences
  const fenceMatch = text.match(/```json\s*([\s\S]*?)```/);
  if (fenceMatch) text = fenceMatch[1];
  
  const start = text.indexOf('{');
  if (start < 0) return null;
  text = text.slice(start);
  
  // Fix bad escapes
  text = text.replace(/\\{2,}'/g, "'");
  text = text.replace(/\\{2,}`/g, "`");
  text = text.replace(/\\([^"\\\/bfnrtu])/g, "$1");
  text = text.replace(/,\s*([}\]])/g, '$1');
  
  try { return JSON.parse(text); } catch(e) {}
  
  // Try closing unclosed brackets
  let attempt = text.replace(/,\s*$/, '');
  const stack = [];
  let inStr = false, escaped = false;
  for (const ch of attempt) {
    if (escaped) { escaped = false; continue; }
    if (ch === '\\') { escaped = true; continue; }
    if (ch === '"') { inStr = !inStr; continue; }
    if (inStr) continue;
    if (ch === '{' || ch === '[') stack.push(ch);
    if (ch === '}' || ch === ']') stack.pop();
  }
  while (stack.length) {
    const ch = stack.pop();
    attempt += ch === '{' ? '}' : ']';
  }
  attempt = attempt.replace(/,\s*([}\]])/g, '$1');
  
  try { return JSON.parse(attempt); } catch(e) { return null; }
}

// ── Extraction ──────────────────────────────────────────────────────────────

async function extractBatch(batchFile, apiKey) {
  const prompt = fs.readFileSync(batchFile, 'utf8');
  
  for (let attempt = 0; attempt <= MAX_RETRIES; attempt++) {
    try {
      const raw = await callGemini(apiKey, prompt);
      const parsed = repairJSON(raw);
      
      if (!parsed || !parsed.results) {
        if (attempt < MAX_RETRIES) {
          console.log(`  ⚠️  Bad JSON, retrying (${attempt + 1}/${MAX_RETRIES})...`);
          await sleep(RETRY_DELAY_MS);
          continue;
        }
        return { success: false, error: 'Unparseable JSON after retries', raw: raw.slice(0, 200) };
      }
      
      const lessons = parsed.results.reduce((s, r) => s + (r.lessons?.length || 0), 0);
      return { success: true, data: parsed, moments: parsed.results.length, lessons };
    } catch(e) {
      if (attempt < MAX_RETRIES) {
        console.log(`  ⚠️  ${e.message.slice(0, 80)}, retrying (${attempt + 1}/${MAX_RETRIES})...`);
        await sleep(RETRY_DELAY_MS * (attempt + 1));
        continue;
      }
      return { success: false, error: e.message };
    }
  }
}

// ── Batch Processing ────────────────────────────────────────────────────────

async function processBatches(batchFiles, apiKey, concurrency) {
  fs.mkdirSync(RESULTS_DIR, { recursive: true });
  const state = loadState();
  
  // Filter out already-completed batches
  const pending = batchFiles.filter(f => {
    const name = path.basename(f);
    return !state.completed[name];
  });
  
  if (pending.length === 0) {
    console.log('All batches already processed.');
    return;
  }
  
  console.log(`Processing ${pending.length} batches (${concurrency} concurrent)...\n`);
  
  let completed = 0, failed = 0, totalLessons = 0;
  
  // Process in chunks of `concurrency`
  for (let i = 0; i < pending.length; i += concurrency) {
    const chunk = pending.slice(i, i + concurrency);
    const results = await Promise.all(chunk.map(async (batchFile) => {
      const name = path.basename(batchFile);
      const batchNum = name.match(/\d+/)?.[0] || name;
      
      process.stdout.write(`  b${batchNum}: `);
      const result = await extractBatch(batchFile, apiKey);
      
      if (result.success) {
        const outFile = path.join(RESULTS_DIR, `result-${batchNum}.json`);
        fs.writeFileSync(outFile, JSON.stringify(result.data, null, 2));
        state.completed[name] = { at: new Date().toISOString(), lessons: result.lessons, moments: result.moments };
        delete state.failed[name];
        completed++;
        totalLessons += result.lessons;
        console.log(`✅ ${result.moments} moments → ${result.lessons} lessons`);
      } else {
        state.failed[name] = { at: new Date().toISOString(), error: result.error };
        failed++;
        console.log(`❌ ${result.error.slice(0, 60)}`);
      }
      
      return result;
    }));
    
    saveState(state);
  }
  
  console.log(`\n=== DONE ===`);
  console.log(`Completed: ${completed} | Failed: ${failed} | Lessons: ${totalLessons}`);
  console.log(`Total completed batches: ${Object.keys(state.completed).length}`);
}

// ── CLI ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  const concurrency = parseInt(args.find((a, i) => args[i-1] === '--concurrency') || DEFAULT_CONCURRENCY);
  const retryFailed = args.includes('--retry-failed');
  const specificBatch = args.find((a, i) => args[i-1] === '--batch');
  
  const apiKey = getApiKey();
  console.log('Gemini API key loaded ✓');
  
  let batchFiles;
  
  if (specificBatch) {
    const f = path.join('/tmp', `extract-batch-${specificBatch}.txt`);
    if (!fs.existsSync(f)) { console.error(`Batch file not found: ${f}`); process.exit(1); }
    batchFiles = [f];
  } else if (retryFailed) {
    const state = loadState();
    batchFiles = Object.keys(state.failed).map(name => {
      // Try both /tmp and BATCH_DIR
      const tmp = path.join('/tmp', name);
      const local = path.join(BATCH_DIR, name);
      return fs.existsSync(tmp) ? tmp : fs.existsSync(local) ? local : null;
    }).filter(Boolean);
    console.log(`Retrying ${batchFiles.length} failed batches...`);
  } else {
    // Find all batch files
    const tmpBatches = fs.readdirSync('/tmp').filter(f => f.match(/^extract-batch-\d+\.txt$/)).map(f => path.join('/tmp', f));
    const localBatches = fs.existsSync(BATCH_DIR) ? fs.readdirSync(BATCH_DIR).filter(f => f.match(/^batch-\d+\.json$/)).map(f => path.join(BATCH_DIR, f)) : [];
    batchFiles = [...tmpBatches, ...localBatches].sort((a, b) => {
      const an = parseInt(path.basename(a).match(/\d+/)[0]);
      const bn = parseInt(path.basename(b).match(/\d+/)[0]);
      return an - bn;
    });
  }
  
  if (batchFiles.length === 0) {
    console.log('No batch files found. Generate them first with learn-signals.js + learn-extract.js');
    return;
  }
  
  console.log(`Found ${batchFiles.length} batch files`);
  await processBatches(batchFiles, apiKey, concurrency);
}

main().catch(e => { console.error('Fatal:', e.message); process.exit(1); });
