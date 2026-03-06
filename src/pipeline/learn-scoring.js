'use strict';

/**
 * learn-scoring.js — Heuristic Signal Scoring System
 * AI Agent Learning Pipeline — Sprint 1
 *
 * Scores moments from learn-signals.js using:
 *   - Baseline Credibility Scores (BCS) per heuristic
 *   - Signal Strength Modifiers (SSM) per moment
 *   - Cluster boosting for nearby signals
 *
 * Usage:
 *   const { scoreMoment, scoreAllMoments, BASELINE_CREDIBILITY } = require('./learn-scoring');
 */

// ── Baseline Credibility Scores ───────────────────────────────────────────────

const BASELINE_CREDIBILITY = {
  user_correction:                0.9,
  user_comparative_clarification: 0.85,
  tool_error_recovery:            0.8,
  strategy_pivot:                 0.7,
  user_frustration:               0.6,
  self_correction:                0.6,
  user_approval:                  0.5,
  tool_loop_break:                0.4,
  thinking_depth_spike:           0.3,
  long_user_spec:                 0.3,
};

// ── Regex Patterns ────────────────────────────────────────────────────────────

const PATTERNS = {
  EXPLICIT_CORRECTION: /\b(no|not quite|wrong|incorrect|that's not right|I wanted|I meant|I asked for|instead of|you should have)\b/gi,
  METACOGNITIVE: /\b(re-evaluating|rethinking|my initial approach was wrong|let's try a different|I need to reconsider|the key insight|wait,?\s*actually|I was wrong about)\b/gi,
  LOOP_ACKNOWLEDGEMENT: /\b(stuck in a loop|repeating myself|this isn't working|new approach|trying something else)\b/gi,
  FRUSTRATION_WORDS: /\b(frustrated|annoyed|useless|this isn't working|can't you just|why can't you|ugh|come on|seriously\??)\b/gi,
  COMPARATIVE_CLARIFICATION: /\b(not\s+\w+,?\s+(?:like|but|instead)\s+\w+|you\s+(?:gave|did|used)\s+\w+,?\s+but\s+I\s+(?:need|want|meant))\b/gi,
};

// ── Utility Helpers ───────────────────────────────────────────────────────────

function tokenise(text) {
  if (!text || typeof text !== 'string') return new Set();
  return new Set(
    text.toLowerCase().replace(/[^a-z0-9\s]/g, ' ').split(/\s+/).filter(Boolean)
  );
}

function wordOverlapRatio(a, b) {
  const setA = tokenise(a);
  const setB = tokenise(b);
  if (setA.size === 0 && setB.size === 0) return 1.0;
  if (setA.size === 0 || setB.size === 0) return 0.0;
  let intersection = 0;
  for (const word of setA) { if (setB.has(word)) intersection++; }
  const union = setA.size + setB.size - intersection;
  return intersection / union;
}

function hasMatch(text, pattern) {
  if (!text) return false;
  pattern.lastIndex = 0;
  return pattern.test(text);
}

function countMatches(text, pattern) {
  if (!text) return 0;
  pattern.lastIndex = 0;
  return (text.match(pattern) || []).length;
}

// ── Signal Strength Modifiers ─────────────────────────────────────────────────

function ssm_user_correction(moment) {
  const trigger = moment.triggerContent || '';
  const agentPrev = moment.contextBefore || '';

  const hasExplicit = hasMatch(trigger, PATTERNS.EXPLICIT_CORRECTION);
  let ssm = hasExplicit ? 1.0 : (wordOverlapRatio(trigger, agentPrev) < 0.15 ? 0.2 : 0.6);

  // Multi-topic penalty
  if (trigger.length > 0) {
    const matchCount = countMatches(trigger, PATTERNS.EXPLICIT_CORRECTION);
    const density = (matchCount * 8) / trigger.length;
    if (density < 0.2) ssm *= 0.5;
  }

  return Math.min(1.0, Math.max(0.0, ssm));
}

function ssm_thinking_depth_spike(moment) {
  const trigger = moment.triggerContent || '';
  return hasMatch(trigger, PATTERNS.METACOGNITIVE) ? 0.8 : 0.2;
}

function ssm_tool_loop_break(moment) {
  const trigger = moment.triggerContent || '';
  const meta = moment.metadata || {};

  if (hasMatch(trigger, PATTERNS.LOOP_ACKNOWLEDGEMENT)) return 0.8;

  const looped = (meta.toolName || '').toLowerCase();
  const next = (meta.nextTool || '').toLowerCase();
  if (looped && next && looped !== next) return 0.6;

  return 0.2;
}

function ssm_tool_error_recovery(moment) {
  const trigger = moment.triggerContent || '';
  const after = moment.contextAfter || '';
  const errorRe = /\b(error|failed|exception|timeout|refused|unavailable|invalid)\b/gi;
  const pivotRe = /\b(instead|alternative|different|retry with|fall[- ]?back|switched to)\b/gi;

  const hasError = hasMatch(trigger, errorRe);
  const hasPivot = hasMatch(after, pivotRe);
  if (hasError && hasPivot) return 0.9;
  if (hasError) return 0.6;
  return 0.3;
}

function ssm_strategy_pivot(moment) {
  const trigger = moment.triggerContent || '';
  const after = moment.contextAfter || '';
  const pivotRe = /\b(let me try a different|switching to|changing my approach|new strategy|instead of|pivoting to|abandon(ing)?|starting over)\b/gi;

  if (hasMatch(trigger, pivotRe) || hasMatch(after, pivotRe)) return 0.9;

  const before = moment.contextBefore || '';
  if (wordOverlapRatio(before, after) < 0.25) return 0.6;
  return 0.4;
}

function ssm_self_correction(moment) {
  const trigger = moment.triggerContent || '';
  const re = /\b(actually,?|wait,?|I made a mistake|correction:|let me correct|I was wrong|I misspoke|scratch that|disregard|apologies,? I)\b/gi;
  return hasMatch(trigger, re) ? 0.8 : 0.4;
}

function ssm_user_approval(moment) {
  const trigger = moment.triggerContent || '';
  const strong = /\b(perfect|exactly|that's exactly|that's what I needed|nailed it|great job|well done|yes! that's|that works perfectly)\b/gi;
  const mild = /\b(good|nice|okay|ok|thanks|thank you|looks good|that's better|correct)\b/gi;
  if (hasMatch(trigger, strong)) return 0.9;
  if (hasMatch(trigger, mild)) return 0.5;
  return 0.2;
}

function ssm_long_user_spec(moment) {
  const trigger = moment.triggerContent || '';
  const len = trigger.length;
  const structure = /(\n[-*•]\s|\n\d+\.\s|```)/g;
  if (len > 500 && hasMatch(trigger, structure)) return 0.8;
  if (len > 500) return 0.6;
  if (len > 200) return 0.4;
  return 0.2;
}

function ssm_user_frustration(moment) {
  const trigger = moment.triggerContent || '';
  const meta = moment.metadata || {};
  let score = 0.0;

  if (hasMatch(trigger, PATTERNS.FRUSTRATION_WORDS)) score += 0.5;
  if ((trigger.match(/\?/g) || []).length >= 3) score += 0.2;
  if ((trigger.match(/!/g) || []).length >= 3) score += 0.2;

  const afterFailure = meta.previousTurnHadFailure === true ||
    ['tool_error_recovery', 'tool_loop_break'].includes(meta.previousTurnHeuristic || '');
  if (trigger.trim().length < 30 && afterFailure) score += 0.2;

  return Math.min(1.0, Math.max(0.0, score));
}

function ssm_user_comparative_clarification(moment) {
  const trigger = moment.triggerContent || '';
  return hasMatch(trigger, PATTERNS.COMPARATIVE_CLARIFICATION) ? 0.95 : 0.3;
}

// ── SSM Dispatcher ────────────────────────────────────────────────────────────

const SSM_FUNCTIONS = {
  user_correction:                ssm_user_correction,
  tool_error_recovery:            ssm_tool_error_recovery,
  strategy_pivot:                 ssm_strategy_pivot,
  self_correction:                ssm_self_correction,
  user_approval:                  ssm_user_approval,
  tool_loop_break:                ssm_tool_loop_break,
  thinking_depth_spike:           ssm_thinking_depth_spike,
  long_user_spec:                 ssm_long_user_spec,
  user_frustration:               ssm_user_frustration,
  user_comparative_clarification: ssm_user_comparative_clarification,
};

function calculateSSM(moment) {
  const fn = SSM_FUNCTIONS[moment.heuristic];
  if (!fn) return 0.5; // unknown heuristic, neutral
  return fn(moment);
}

// ── Cluster Detection ─────────────────────────────────────────────────────────

function getLineIndex(moment) {
  return parseInt(moment.id.split(':')[1]) || 0;
}

function isInCluster(moment, allMoments, windowSize = 3) {
  if (!allMoments || allMoments.length < 2) return false;
  const myLine = getLineIndex(moment);
  const nearby = allMoments.filter(m =>
    m.id !== moment.id &&
    Math.abs(getLineIndex(m) - myLine) <= windowSize
  );
  return nearby.length >= 1; // at least 1 other signal within window
}

// ── Main Scoring Function ─────────────────────────────────────────────────────

/**
 * Score a single moment.
 * @param {object} moment — from learn-signals.js
 * @param {object[]} allMoments — all moments in this session (for clustering)
 * @returns {number} — final score (0.0 to ~1.35)
 */
function scoreMoment(moment, allMoments = []) {
  const bcs = BASELINE_CREDIBILITY[moment.heuristic] || 0.3;
  const ssm = calculateSSM(moment);
  const clusterBoost = isInCluster(moment, allMoments) ? 1.5 : 1.0;
  const score = bcs * ssm * clusterBoost;
  return +score.toFixed(4);
}

/**
 * Score all moments and return sorted (highest first).
 * Attaches .score to each moment.
 */
function scoreAllMoments(moments) {
  for (const m of moments) {
    m.score = scoreMoment(m, moments);
  }
  return moments.sort((a, b) => b.score - a.score);
}

// ── New Heuristic Detectors ───────────────────────────────────────────────────
// These run AFTER the main extractSignals pass, on raw messages.

function detectFrustration(sessionId, messages, makeMomentFn) {
  const moments = [];
  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];
    if (msg.role !== 'user') continue;
    const text = msg.text || '';

    const hasFrustration = hasMatch(text, PATTERNS.FRUSTRATION_WORDS);
    const manyQuestions = (text.match(/\?/g) || []).length >= 3;
    const manyBangs = (text.match(/!/g) || []).length >= 3;

    // Check if previous turn had a failure
    let prevFailure = false;
    if (i > 0) {
      const prev = messages[i - 1];
      if (prev.role === 'toolResult' && prev.exitCode !== null && prev.exitCode !== 0) prevFailure = true;
    }

    const shortAfterFailure = text.trim().length < 30 && prevFailure;

    if (hasFrustration || manyQuestions || manyBangs || shortAfterFailure) {
      moments.push(makeMomentFn(
        sessionId, msg, i,
        'user_frustration', 'high', messages,
        { previousTurnHadFailure: prevFailure }
      ));
    }
  }
  return moments;
}

function detectComparativeClarification(sessionId, messages, makeMomentFn) {
  const moments = [];
  for (let i = 0; i < messages.length; i++) {
    const msg = messages[i];
    if (msg.role !== 'user') continue;
    const text = msg.text || '';

    if (hasMatch(text, PATTERNS.COMPARATIVE_CLARIFICATION)) {
      moments.push(makeMomentFn(
        sessionId, msg, i,
        'user_comparative_clarification', 'high', messages,
        {}
      ));
    }
  }
  return moments;
}

// ── Exports ───────────────────────────────────────────────────────────────────

module.exports = {
  scoreMoment,
  scoreAllMoments,
  calculateSSM,
  isInCluster,
  detectFrustration,
  detectComparativeClarification,
  BASELINE_CREDIBILITY,
  PATTERNS,
  SSM_FUNCTIONS,
};
