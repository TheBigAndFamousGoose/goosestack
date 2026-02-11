/**
 * token-counter.js — Token cost estimation for GooseStack API
 *
 * Pricing is in cents per 1M tokens. We estimate cost AFTER the response
 * completes (using actual token counts from provider response headers/body).
 *
 * Our pricing includes a margin over raw provider costs. We frame this as
 * "optimized routing" — never expose the raw costs or markup percentage.
 *
 * Pricing updated: 2025-01 — check quarterly and adjust.
 */

// ============================================================
// Provider pricing — our sell price (cents per 1M tokens)
// These are what WE CHARGE, already including our margin.
// ============================================================

const PRICING = {
  // --- OpenAI models ---
  'gpt-4o': { input: 300, output: 1200 },
  'gpt-4o-mini': { input: 18, output: 75 },
  'gpt-4o-2024-11-20': { input: 300, output: 1200 },
  'gpt-4o-2024-08-06': { input: 300, output: 1200 },
  'gpt-4o-mini-2024-07-18': { input: 18, output: 75 },
  'gpt-4-turbo': { input: 1200, output: 3600 },
  'gpt-4-turbo-preview': { input: 1200, output: 3600 },
  'gpt-4': { input: 3600, output: 7200 },
  'gpt-3.5-turbo': { input: 60, output: 180 },
  'o1': { input: 1800, output: 7200 },
  'o1-mini': { input: 360, output: 1440 },
  'o1-preview': { input: 1800, output: 7200 },
  'o3-mini': { input: 135, output: 540 },
  'o3': { input: 1200, output: 4800 },
  'o3-2025-04-16': { input: 1200, output: 4800 },
  'gpt-4.1': { input: 240, output: 960 },
  'gpt-4.1-2025-04-14': { input: 240, output: 960 },
  'gpt-4.1-mini': { input: 48, output: 192 },
  'gpt-4.1-mini-2025-04-14': { input: 48, output: 192 },
  'gpt-4.1-nano': { input: 12, output: 48 },
  'gpt-4.1-nano-2025-04-14': { input: 12, output: 48 },

  // --- Anthropic models ---
  'claude-sonnet-4-20250514': { input: 360, output: 1800 },
  'claude-opus-4-20250514': { input: 1800, output: 7200 },
  'claude-3-5-sonnet-20241022': { input: 360, output: 1800 },
  'claude-3-5-sonnet-20240620': { input: 360, output: 1800 },
  'claude-3-5-haiku-20241022': { input: 96, output: 480 },
  'claude-3-opus-20240229': { input: 1800, output: 7200 },
  'claude-3-sonnet-20240229': { input: 360, output: 1800 },
  'claude-3-haiku-20240307': { input: 30, output: 150 },
};

// Friendly aliases → canonical model name
const ALIASES = {
  'claude-sonnet-4': 'claude-sonnet-4-20250514',
  'claude-opus-4': 'claude-opus-4-20250514',
  'claude-3.5-sonnet': 'claude-3-5-sonnet-20241022',
  'claude-3.5-haiku': 'claude-3-5-haiku-20241022',
  'claude-3-opus': 'claude-3-opus-20240229',
  'claude-3-sonnet': 'claude-3-sonnet-20240229',
  'claude-3-haiku': 'claude-3-haiku-20240307',
};

/**
 * Resolve a model name to its canonical form (handles aliases).
 */
function resolveModel(model) {
  return ALIASES[model] || model;
}

/**
 * Get pricing for a model. Falls back to a generous default if unknown
 * (we'd rather overcharge slightly than undercharge for unknown models).
 */
function getModelPricing(model) {
  const resolved = resolveModel(model);
  return PRICING[resolved] || { input: 300, output: 1200 }; // safe fallback (GPT-4o level)
}

/**
 * Calculate cost in cents for a request.
 *
 * @param {string} model - Model name
 * @param {number} inputTokens - Number of input/prompt tokens
 * @param {number} outputTokens - Number of output/completion tokens
 * @returns {number} Cost in cents (integer, rounded up — we never round down)
 */
function calculateCost(model, inputTokens, outputTokens) {
  const pricing = getModelPricing(model);

  // cents_per_million → cents: (tokens * rate) / 1_000_000
  const inputCost = (inputTokens * pricing.input) / 1_000_000;
  const outputCost = (outputTokens * pricing.output) / 1_000_000;

  // Always round UP — fractional cents go in our favor
  return Math.ceil(inputCost + outputCost);
}

/**
 * Pre-flight cost estimate based on input tokens only (before we know output).
 * Used to check if user has enough credits to even start the request.
 * We estimate a reasonable max output and check against that.
 *
 * @param {string} model - Model name
 * @param {number} inputTokens - Estimated input tokens
 * @param {number} maxOutputTokens - Max output tokens (from request or default)
 * @returns {number} Estimated max cost in cents
 */
function estimateMaxCost(model, inputTokens, maxOutputTokens = 4096) {
  return calculateCost(model, inputTokens, maxOutputTokens);
}

/**
 * Rough input token estimate from message content.
 * ~4 chars per token is a reasonable approximation.
 * Only used for pre-flight checks; actual billing uses provider-reported counts.
 */
function estimateInputTokens(messages) {
  if (!messages) return 0;
  let chars = 0;
  if (Array.isArray(messages)) {
    for (const msg of messages) {
      if (typeof msg.content === 'string') chars += msg.content.length;
      else if (Array.isArray(msg.content)) {
        for (const part of msg.content) {
          if (part.text) chars += part.text.length;
        }
      }
    }
  } else if (typeof messages === 'string') {
    chars = messages.length;
  }
  // ~4 chars/token + overhead for message formatting
  return Math.ceil(chars / 4) + 50;
}

/**
 * Detect provider from model name.
 */
function detectProvider(model) {
  const resolved = resolveModel(model);
  if (resolved.startsWith('claude')) return 'anthropic';
  if (resolved.startsWith('gpt') || resolved.startsWith('o1') || resolved.startsWith('o3') || resolved.startsWith('o4')) return 'openai';
  return 'unknown';
}

module.exports = {
  PRICING,
  resolveModel,
  getModelPricing,
  calculateCost,
  estimateMaxCost,
  estimateInputTokens,
  detectProvider,
};
