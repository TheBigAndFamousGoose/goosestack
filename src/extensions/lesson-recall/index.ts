/**
 * Lesson Recall Plugin for OpenClaw
 * 
 * On every message, embeds the user's prompt via local Ollama (nomic-embed-text),
 * searches committed lessons in SQLite via sqlite-vec, and injects the top
 * matches as system context before the agent starts.
 * 
 * This is the "Option C" retrieval hook — the thing that makes the learning
 * pipeline actually change agent behavior.
 */

import type { OpenClawPluginApi } from "openclaw/plugin-sdk";
import { resolve } from "node:path";
import { existsSync } from "node:fs";

// ── Types ───────────────────────────────────────────────────────────────────

interface LessonRow {
  id: string;
  title: string;
  rule: string;
  lesson_type: string;
  confidence: number;
  status: string;
}

interface Config {
  enabled: boolean;
  dbPath: string;
  ollamaUrl: string;
  embeddingModel: string;
  topK: number;
  minSimilarity: number;
  maxChars: number;
}

// ── Embedding ───────────────────────────────────────────────────────────────

async function getEmbedding(text: string, ollamaUrl: string, model: string): Promise<number[]> {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000); // 2s timeout

  try {
    const resp = await fetch(`${ollamaUrl}/api/embeddings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ model, prompt: text }),
      signal: controller.signal,
    });

    if (!resp.ok) {
      throw new Error(`Ollama embedding failed: ${resp.status} ${resp.statusText}`);
    }

    const data = await resp.json() as { embedding: number[] };
    if (!data.embedding || !Array.isArray(data.embedding) || data.embedding.length < 100) {
      throw new Error("Invalid embedding response from Ollama");
    }
    return data.embedding;
  } finally {
    clearTimeout(timeout);
  }
}

function cosineSimilarity(a: number[], b: number[]): number {
  let dot = 0, normA = 0, normB = 0;
  for (let i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  return dot / (Math.sqrt(normA) * Math.sqrt(normB) + 1e-10);
}

// ── Category Balancing ──────────────────────────────────────────────────────

/**
 * Apply category balancing to a pre-sorted list of scored lessons.
 * Rules:
 *   - Iterate candidates in descending score order.
 *   - Allow at most `maxPerCategory` entries per lesson_type.
 *   - Stop when `topK` results are collected.
 *
 * Example: 5 reliability lessons → output keeps only the top 2 reliability,
 * then fills remaining slots from other categories.
 */
function balanceByCategory(
  candidates: Array<{ lesson: LessonRow; score: number }>,
  topK: number,
  maxPerCategory: number,
): Array<{ lesson: LessonRow; score: number }> {
  const result: Array<{ lesson: LessonRow; score: number }> = [];
  const categoryCount: Record<string, number> = {};

  for (const item of candidates) {
    if (result.length >= topK) break;
    const cat = item.lesson.lesson_type || "unknown";
    const count = categoryCount[cat] || 0;
    if (count >= maxPerCategory) continue;
    categoryCount[cat] = count + 1;
    result.push(item);
  }

  return result;
}

// ── Lesson DB ───────────────────────────────────────────────────────────────

class LessonDB {
  private db: any = null;
  private lessons: Array<{ lesson: LessonRow; embedding: number[] }> = [];
  private lastRefresh = 0;
  private refreshIntervalMs = 60_000; // Re-read lessons every 60s

  constructor(private dbPath: string) {}

  private ensureOpen(): void {
    if (this.db) return;
    
    const resolvedPath = this.dbPath.replace(/^~/, process.env.HOME || "");
    if (!existsSync(resolvedPath)) {
      throw new Error(`Lesson DB not found: ${resolvedPath}`);
    }

    // Dynamic require for better-sqlite3 (available in the content-pipeline)
    const Database = require("better-sqlite3");
    this.db = new Database(resolvedPath, { readonly: true });
  }

  async refreshLessons(ollamaUrl: string, model: string): Promise<void> {
    const now = Date.now();
    if (now - this.lastRefresh < this.refreshIntervalMs && this.lessons.length > 0) {
      return; // Cache still fresh
    }

    this.ensureOpen();
    
    const rows = this.db.prepare(
      "SELECT id, title, rule, lesson_type, confidence, status FROM lessons WHERE status IN ('probationary', 'committed', 'confirmed') ORDER BY confidence DESC"
    ).all() as LessonRow[];

    if (rows.length === 0) {
      this.lessons = [];
      this.lastRefresh = now;
      return;
    }

    // Check if lessons changed
    const currentIds = new Set(this.lessons.map(l => l.lesson.id));
    const newIds = new Set(rows.map(r => r.id));
    const unchanged = rows.length === this.lessons.length && 
      rows.every(r => currentIds.has(r.id));

    if (unchanged) {
      this.lastRefresh = now;
      return; // Same lessons, no need to re-embed
    }

    // Re-embed only new lessons, keep cached embeddings for existing ones
    const existingMap = new Map(this.lessons.map(l => [l.lesson.id, l.embedding]));
    const newLessons: Array<{ lesson: LessonRow; embedding: number[] }> = [];

    for (const row of rows) {
      const existing = existingMap.get(row.id);
      if (existing) {
        newLessons.push({ lesson: row, embedding: existing });
      } else {
        const text = `title: ${row.title} guideline: ${row.rule}`;
        const embedding = await getEmbedding(text, ollamaUrl, model);
        newLessons.push({ lesson: row, embedding });
      }
    }

    this.lessons = newLessons;
    this.lastRefresh = now;
  }

  search(queryEmbedding: number[], topK: number, minSimilarity: number): Array<{ lesson: LessonRow; score: number }> {
    const scored = this.lessons.map(({ lesson, embedding }) => ({
      lesson,
      score: cosineSimilarity(queryEmbedding, embedding),
    }));

    const filtered = scored
      .filter(r => r.score >= minSimilarity)
      .sort((a, b) => b.score - a.score);

    // Category balancing: max 2 per category in the final top-K
    return balanceByCategory(filtered, topK, 2);
  }

  close(): void {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  }
}

// ── Format ──────────────────────────────────────────────────────────────────

function formatLessonsContext(results: Array<{ lesson: LessonRow; score: number }>, maxChars: number): string {
  const lines: string[] = [
    "<relevant-lessons>",
    "The following lessons were learned from past conversations. Follow these guidelines when relevant:",
    "",
  ];

  let totalChars = lines.join("\n").length;

  for (const { lesson, score } of results) {
    const entry = `• [${lesson.lesson_type}] ${lesson.title}\n  ${lesson.rule}`;
    if (totalChars + entry.length > maxChars) break;
    lines.push(entry);
    lines.push("");
    totalChars += entry.length + 1;
  }

  lines.push("</relevant-lessons>");
  return lines.join("\n");
}

// ── Plugin ──────────────────────────────────────────────────────────────────

const lessonRecallPlugin = {
  id: "lesson-recall",
  name: "Lesson Recall",
  description: "Injects relevant lessons from the learning pipeline into agent context",
  configSchema: {
    type: "object" as const,
    additionalProperties: false,
    properties: {
      enabled: { type: "boolean" as const, default: true },
      dbPath: { type: "string" as const, default: "~/Projects/content-pipeline/data/goosestack.db" },
      ollamaUrl: { type: "string" as const, default: "http://localhost:11434" },
      embeddingModel: { type: "string" as const, default: "nomic-embed-text" },
      topK: { type: "number" as const, default: 5 },
      minSimilarity: { type: "number" as const, default: 0.35 },
      maxChars: { type: "number" as const, default: 2000 },
    },
  },

  register(api: OpenClawPluginApi) {
    const cfg: Config = {
      enabled: true,
      dbPath: "~/Projects/content-pipeline/data/goosestack.db",
      ollamaUrl: "http://localhost:11434",
      embeddingModel: "nomic-embed-text",
      topK: 5,
      minSimilarity: 0.45,
      maxChars: 2000,
      ...(api.pluginConfig || {}),
    };

    if (!cfg.enabled) {
      api.logger.info("lesson-recall: disabled via config");
      return;
    }

    const lessonDB = new LessonDB(cfg.dbPath);
    api.logger.info(`lesson-recall: registered (db: ${cfg.dbPath}, model: ${cfg.embeddingModel})`);

    // Core hook: inject lessons before agent starts
    api.on("before_agent_start", async (event: any) => {
      if (!event.prompt || event.prompt.length < 20) {
        return; // Too short to meaningfully search (skip "ok", "yes", "honk", etc.)
      }

      try {
        // Refresh lesson cache (reads DB, embeds new lessons)
        await lessonDB.refreshLessons(cfg.ollamaUrl, cfg.embeddingModel);

        // Embed the user's message
        const queryEmbedding = await getEmbedding(event.prompt, cfg.ollamaUrl, cfg.embeddingModel);

        // Search for relevant lessons
        const results = lessonDB.search(queryEmbedding, cfg.topK, cfg.minSimilarity);

        if (results.length === 0) {
          return;
        }

        api.logger.info?.(`lesson-recall: injecting ${results.length} lessons (top score: ${results[0].score.toFixed(3)})`);

        // Record trigger for each injected lesson (updates trigger_count + confidence)
        try {
          const pipelineDbPath = resolve(
            (process.env.HOME || ""),
            "Projects/content-pipeline/db.js"
          );
          const pipelineDb = require(pipelineDbPath);
          pipelineDb.init();
          for (const { lesson } of results) {
            try { pipelineDb.recordLessonTrigger(lesson.id); } catch { /* non-fatal */ }
          }
        } catch { /* db module not accessible from this plugin context — skip */ }

        return {
          prependContext: formatLessonsContext(results, cfg.maxChars),
        };
      } catch (err) {
        api.logger.warn(`lesson-recall: recall failed: ${String(err)}`);
      }
    });
  },
};

export default lessonRecallPlugin;
