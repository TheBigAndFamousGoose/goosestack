/**
 * server.js — GooseStack API Proxy
 *
 * The revenue engine. Proxies AI requests to Anthropic/OpenAI with:
 *   - Per-user API keys (gsk_xxx format)
 *   - Prepaid credit system (never goes negative)
 *   - Token counting + cost tracking
 *   - Pro subscription with BYOK support
 *   - Stripe billing integration
 *
 * Runs as a single process with SQLite. Handles ~100 req/s easily on a $5 VPS.
 */

const express = require('express');
const crypto = require('crypto');
const db = require('./db');
const tc = require('./token-counter');
const stripeRouter = require('./stripe');

const app = express();
const PORT = process.env.PORT || 3000;

// ============================================================
// Middleware
// ============================================================

// JSON body parser for all routes EXCEPT Stripe webhook (needs raw body).
// The webhook route has its own raw parser in stripe.js.
app.use((req, res, next) => {
  if (req.path === '/billing/webhook') return next();
  express.json({ limit: '1mb' })(req, res, next);
});

// Request logging
app.use((req, res, next) => {
  const start = Date.now();
  res.on('finish', () => {
    const ms = Date.now() - start;
    console.log(`${req.method} ${req.path} ${res.statusCode} ${ms}ms`);
  });
  next();
});

// ============================================================
// Auth middleware — extracts user from Bearer token
// ============================================================
function authenticate(req, res, next) {
  const authHeader = req.headers.authorization;
  if (!authHeader || !authHeader.startsWith('Bearer ')) {
    return res.status(401).json({
      error: { message: 'Missing or invalid Authorization header. Use: Bearer gsk_xxx', type: 'auth_error' },
    });
  }

  const token = authHeader.slice(7);
  if (!token.startsWith('gsk_')) {
    return res.status(401).json({
      error: { message: 'Invalid API key format. Keys start with gsk_', type: 'auth_error' },
    });
  }

  const user = db.getUserByApiKey(token);
  if (!user) {
    return res.status(401).json({
      error: { message: 'Invalid or revoked API key', type: 'auth_error' },
    });
  }

  req.user = user;
  next();
}

// Soft auth — sets req.user if present, but doesn't block
function softAuth(req, res, next) {
  const authHeader = req.headers.authorization;
  if (authHeader && authHeader.startsWith('Bearer gsk_')) {
    req.user = db.getUserByApiKey(authHeader.slice(7));
  }
  next();
}

// ============================================================
// Stripe billing routes (must be before JSON parser catches webhook)
// ============================================================
app.use('/billing', softAuth, stripeRouter);

// ============================================================
// Health check
// ============================================================
app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'goosestack-api', version: '1.0.0' });
});

// ============================================================
// POST /v1/keys — Issue a new API key
// Body: { email: "user@example.com", name?: "my-key" }
// ============================================================
app.post('/v1/keys', (req, res) => {
  try {
    const { email, name } = req.body;
    if (!email || typeof email !== 'string' || !email.includes('@')) {
      return res.status(400).json({ error: 'Valid email is required' });
    }

    const user = db.findOrCreateUser(email.toLowerCase().trim());
    const key = db.createApiKey(user.id, name || 'default');

    res.status(201).json({
      api_key: key.raw_key,
      prefix: key.prefix,
      name: key.name,
      message: 'Save this key — it cannot be retrieved again.',
    });
  } catch (err) {
    console.error('[keys] error:', err.message);
    res.status(500).json({ error: 'Failed to create API key' });
  }
});

// ============================================================
// GET /v1/usage — Credit balance + usage stats
// ============================================================
app.get('/v1/usage', authenticate, (req, res) => {
  try {
    const user = req.user;
    const balance = db.getBalance(user.id);
    const summary = db.getUsageSummary(user.id);
    const recent = db.getRecentUsage(user.id, 10);
    const keys = db.listApiKeys(user.id);
    const isPro = db.isProActive(user);

    res.json({
      balance_cents: balance,
      balance_usd: `$${(balance / 100).toFixed(2)}`,
      pro: isPro,
      pro_until: user.pro_until || null,
      usage_30d: summary,
      recent_requests: recent,
      api_keys: keys,
    });
  } catch (err) {
    console.error('[usage] error:', err.message);
    res.status(500).json({ error: 'Failed to fetch usage' });
  }
});

// ============================================================
// POST /v1/chat/completions — OpenAI-compatible proxy
// ============================================================
app.post('/v1/chat/completions', authenticate, async (req, res) => {
  try {
    const user = req.user;
    const body = req.body;
    const model = body.model || 'gpt-4o-mini';
    const isStream = body.stream === true;

    // Check for BYOK (Pro users can pass their own key)
    const providerKey = req.headers['x-provider-key'];
    const isPro = db.isProActive(user);
    const usingBYOK = isPro && providerKey;

    if (!usingBYOK) {
      // ----- Credit check -----
      const estimatedInput = tc.estimateInputTokens(body.messages);
      const maxOutput = body.max_tokens || body.max_completion_tokens || 4096;
      const estimatedCost = tc.estimateMaxCost(model, estimatedInput, maxOutput);
      const balance = db.getBalance(user.id);

      if (balance < estimatedCost) {
        return res.status(402).json({
          error: {
            message: `Insufficient credits. Balance: $${(balance / 100).toFixed(2)}, estimated cost: $${(estimatedCost / 100).toFixed(2)}. Add credits at https://goosestack.com/billing`,
            type: 'insufficient_credits',
            balance_cents: balance,
          },
        });
      }
    }

    // ----- Proxy to OpenAI -----
    const apiKey = usingBYOK ? providerKey : process.env.OPENAI_API_KEY;
    if (!apiKey) {
      return res.status(503).json({ error: { message: 'OpenAI provider not configured', type: 'provider_error' } });
    }

    const upstreamRes = await fetch('https://api.openai.com/v1/chat/completions', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`,
      },
      body: JSON.stringify(body),
    });

    if (isStream) {
      // ----- Streaming response -----
      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');

      let fullContent = '';
      let completionTokens = 0;
      let promptTokens = 0;
      let usageData = null;

      const reader = upstreamRes.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          const chunk = decoder.decode(value, { stream: true });
          buffer += chunk;

          // Forward the raw chunk to client
          res.write(chunk);

          // Parse SSE events to extract usage
          const lines = buffer.split('\n');
          buffer = lines.pop() || ''; // keep incomplete line

          for (const line of lines) {
            if (!line.startsWith('data: ') || line === 'data: [DONE]') continue;
            try {
              const parsed = JSON.parse(line.slice(6));
              if (parsed.usage) {
                usageData = parsed.usage;
                promptTokens = parsed.usage.prompt_tokens || 0;
                completionTokens = parsed.usage.completion_tokens || 0;
              }
              if (parsed.choices?.[0]?.delta?.content) {
                fullContent += parsed.choices[0].delta.content;
              }
            } catch (_) { /* partial JSON, skip */ }
          }
        }
      } finally {
        res.end();
      }

      // ----- Post-stream billing -----
      if (!usingBYOK) {
        // If no usage data from stream, estimate from content
        if (!usageData) {
          promptTokens = tc.estimateInputTokens(body.messages);
          completionTokens = Math.ceil(fullContent.length / 4);
        }
        const cost = tc.calculateCost(model, promptTokens, completionTokens);
        const deducted = db.deductCredits(user.id, cost);
        if (deducted) {
          db.logUsage(user.id, 'openai', model, promptTokens, completionTokens, cost);
        }
      }

    } else {
      // ----- Non-streaming response -----
      const data = await upstreamRes.json();

      if (!upstreamRes.ok) {
        return res.status(upstreamRes.status).json(data);
      }

      // Extract token counts from response
      const promptTokens = data.usage?.prompt_tokens || tc.estimateInputTokens(body.messages);
      const completionTokens = data.usage?.completion_tokens || 0;

      if (!usingBYOK) {
        const cost = tc.calculateCost(model, promptTokens, completionTokens);
        const deducted = db.deductCredits(user.id, cost);
        if (!deducted) {
          // Shouldn't happen (we pre-checked), but safety net
          return res.status(402).json({
            error: { message: 'Insufficient credits for this request', type: 'insufficient_credits' },
          });
        }
        db.logUsage(user.id, 'openai', model, promptTokens, completionTokens, cost);
      }

      res.json(data);
    }

  } catch (err) {
    console.error('[openai proxy] error:', err.message);
    res.status(502).json({ error: { message: 'Upstream request failed', type: 'proxy_error' } });
  }
});

// ============================================================
// POST /v1/messages — Anthropic-compatible proxy
// ============================================================
app.post('/v1/messages', authenticate, async (req, res) => {
  try {
    const user = req.user;
    const body = req.body;
    const model = body.model || 'claude-sonnet-4-20250514';
    const isStream = body.stream === true;

    // Check for BYOK
    const providerKey = req.headers['x-provider-key'];
    const isPro = db.isProActive(user);
    const usingBYOK = isPro && providerKey;

    if (!usingBYOK) {
      // ----- Credit check -----
      const estimatedInput = tc.estimateInputTokens(body.messages);
      const maxOutput = body.max_tokens || 4096;
      const estimatedCost = tc.estimateMaxCost(model, estimatedInput, maxOutput);
      const balance = db.getBalance(user.id);

      if (balance < estimatedCost) {
        return res.status(402).json({
          error: {
            message: `Insufficient credits. Balance: $${(balance / 100).toFixed(2)}, estimated cost: $${(estimatedCost / 100).toFixed(2)}. Add credits at https://goosestack.com/billing`,
            type: 'insufficient_credits',
            balance_cents: balance,
          },
        });
      }
    }

    // ----- Proxy to Anthropic -----
    const apiKey = usingBYOK ? providerKey : process.env.ANTHROPIC_API_KEY;
    if (!apiKey) {
      return res.status(503).json({ error: { message: 'Anthropic provider not configured', type: 'provider_error' } });
    }

    const upstreamRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': body['anthropic-version'] || req.headers['anthropic-version'] || '2023-06-01',
      },
      body: JSON.stringify(body),
    });

    if (isStream) {
      // ----- Streaming response -----
      res.setHeader('Content-Type', 'text/event-stream');
      res.setHeader('Cache-Control', 'no-cache');
      res.setHeader('Connection', 'keep-alive');

      let inputTokens = 0;
      let outputTokens = 0;

      const reader = upstreamRes.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      try {
        while (true) {
          const { done, value } = await reader.read();
          if (done) break;

          const chunk = decoder.decode(value, { stream: true });
          buffer += chunk;

          // Forward raw chunk to client
          res.write(chunk);

          // Parse SSE events to extract usage from Anthropic stream
          const lines = buffer.split('\n');
          buffer = lines.pop() || '';

          for (const line of lines) {
            if (!line.startsWith('data: ')) continue;
            try {
              const parsed = JSON.parse(line.slice(6));
              // Anthropic sends usage in message_start and message_delta events
              if (parsed.type === 'message_start' && parsed.message?.usage) {
                inputTokens = parsed.message.usage.input_tokens || 0;
              }
              if (parsed.type === 'message_delta' && parsed.usage) {
                outputTokens = parsed.usage.output_tokens || 0;
              }
            } catch (_) { /* partial JSON, skip */ }
          }
        }
      } finally {
        res.end();
      }

      // ----- Post-stream billing -----
      if (!usingBYOK) {
        if (!inputTokens) inputTokens = tc.estimateInputTokens(body.messages);
        const cost = tc.calculateCost(model, inputTokens, outputTokens);
        const deducted = db.deductCredits(user.id, cost);
        if (deducted) {
          db.logUsage(user.id, 'anthropic', model, inputTokens, outputTokens, cost);
        }
      }

    } else {
      // ----- Non-streaming response -----
      const data = await upstreamRes.json();

      if (!upstreamRes.ok) {
        return res.status(upstreamRes.status).json(data);
      }

      const inputTokens = data.usage?.input_tokens || tc.estimateInputTokens(body.messages);
      const outputTokens = data.usage?.output_tokens || 0;

      if (!usingBYOK) {
        const cost = tc.calculateCost(model, inputTokens, outputTokens);
        const deducted = db.deductCredits(user.id, cost);
        if (!deducted) {
          return res.status(402).json({
            error: { message: 'Insufficient credits for this request', type: 'insufficient_credits' },
          });
        }
        db.logUsage(user.id, 'anthropic', model, inputTokens, outputTokens, cost);
      }

      res.json(data);
    }

  } catch (err) {
    console.error('[anthropic proxy] error:', err.message);
    res.status(502).json({ error: { message: 'Upstream request failed', type: 'proxy_error' } });
  }
});

// ============================================================
// 404 catch-all
// ============================================================
app.use((req, res) => {
  res.status(404).json({
    error: {
      message: `Not found: ${req.method} ${req.path}`,
      type: 'not_found',
      docs: 'https://docs.goosestack.com/api',
    },
  });
});

// ============================================================
// Global error handler
// ============================================================
app.use((err, req, res, _next) => {
  console.error('[server] unhandled error:', err);
  res.status(500).json({ error: { message: 'Internal server error', type: 'server_error' } });
});

// ============================================================
// Start
// ============================================================
app.listen(PORT, () => {
  console.log(`🪿 GooseStack API running on port ${PORT}`);
  console.log(`   OpenAI proxy:    POST /v1/chat/completions`);
  console.log(`   Anthropic proxy: POST /v1/messages`);
  console.log(`   Usage:           GET  /v1/usage`);
  console.log(`   Issue key:       POST /v1/keys`);
  console.log(`   Billing:         POST /billing/checkout`);
  console.log(`   Webhook:         POST /billing/webhook`);
  console.log(`   Portal:          GET  /billing/portal`);
});

module.exports = app;
