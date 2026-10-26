// The parts of the extension that do not need VS Code: reading what
// `leanprof elab|run --since-last` writes (the difference from the previous
// profile, `.lake/leanprof/onsave/NAME.delta.json`, and the report itself) into
// what the editor shows, and running at most one profile per file at a time.
// Every number comes from the command; this only places and words it.
// Tested by test/unit.test.js (`npm run test:unit`, no VS Code needed).
"use strict";
const path = require("path");

/** Where `--since-last` keeps the report of FILE (relative to the project). */
function onSaveReport(root, rel) {
  return path.join(root, ".lake", "leanprof", "onsave", rel + ".json");
}

/** The report's difference file (`NAME.delta.json` next to `NAME.json`). */
function deltaOf(report) {
  return report.replace(/\.json$/, "") + ".delta.json";
}

/** Where `run --since-last EXE` keeps its report (as the command names it). */
function onSaveRunReport(root, exe) {
  return path.join(root, ".lake", "leanprof", "onsave", `run-${path.basename(exe)}.json`);
}

/** `File.lean:12` as { file, line } (line 1-based; 0 when there is none). */
function parsePos(pos) {
  const m = /^(.*):(\d+)$/.exec(pos || "");
  return m ? { file: m[1], line: Number(m[2]) } : { file: pos || "", line: 0 };
}

/** Whether a report's file is `rel`: both are relative to the project. */
function sameFile(reported, rel) {
  if (!reported || !rel) return false;
  const norm = (p) => p.split(path.sep).join("/").replace(/^\.\//, "");
  return norm(reported) === norm(rel);
}

function groupDigits(n) {
  return Math.round(Math.abs(n)).toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
}

function fmtKHB(hb) {
  return `${(Math.abs(hb) / 1000).toFixed(1)} kHB`;
}

function fmtNs(ns) {
  ns = Math.abs(ns);
  if (ns < 1e3) return `${ns.toFixed(0)} ns`;
  if (ns < 1e6) return `${(ns / 1e3).toFixed(1)} µs`;
  if (ns < 1e9) return `${(ns / 1e6).toFixed(1)} ms`;
  return `${(ns / 1e9).toFixed(2)} s`;
}

function signed(d, fmt) {
  return d > 0 ? `+${fmt(d)}` : d < 0 ? `−${fmt(-d)}` : "±0";
}

/** The declaration's name from its key (`File.lean name`), else the first words of its line. */
function declName(d) {
  const key = d.key || "";
  const i = key.indexOf(" ");
  if (i > 0 && !key.slice(i + 1).startsWith("#")) return key.slice(i + 1).replace(/ #\d+$/, "");
  return (d.name || key).slice(0, 60);
}

/** Markdown-safe inline code. */
function code(s) {
  const t = String(s).replace(/`/g, "'");
  return "`" + t + "`";
}

/**
 * What to show for one difference file in `rel`: one item per line,
 * { line (0-based), text, level, hover (Markdown) }. `level`: "red" for an
 * increase above `redAbove` (heartbeats; any increase of copies or
 * allocations, which are exact), "up" for a smaller increase, "down" for a
 * decrease, "new" for a declaration that was not there.
 */
function deltaItems(delta, rel, opts = {}) {
  const redAbove = opts.redAbove === undefined ? 10000 : opts.redAbove;
  const since = opts.since || "since the last save";
  if (!delta || delta.first || delta.comparable === false) return [];
  const hb = delta.unit === "heartbeats";
  const amount = hb ? fmtKHB : fmtNs;
  const byLine = new Map();
  const add = (line, part) => {
    if (!byLine.has(line)) byLine.set(line, []);
    byLine.get(line).push(part);
  };
  for (const d of delta.decls || []) {
    const { file, line } = parsePos(d.pos);
    if (!line || !sameFile(file, rel)) continue;
    const change = d.change || 0;
    const level = d.status === "new" ? "new" : change > 0 ? (change > redAbove ? "red" : "up") : "down";
    const text = d.status === "new" ? `${amount(change)} (new)` : `${signed(change, amount)} ${since}`;
    const hover = [`**${code(declName(d))}**: ${amount(d.base || 0)} → ${amount(d.new || 0)} to compile (${signed(change, amount)} ${since})`];
    const why = d.why;
    if (why) {
      if (why.headline) hover.push("", `top change: ${why.headline}`);
      if ((why.parts || []).length) hover.push("");
      for (const p of why.parts || []) hover.push(`- ${p.part}: ${amount(p.base)} → ${amount(p.new)}`);
      if ((why.rows || []).length) {
        hover.push("", "what changed inside it:", "", "| change | what | name | before | after |", "|---|---|---|---|---|");
        for (const r of why.rows)
          hover.push(`| ${r.change} | ${r.label} | ${code(r.name)}${r.where ? ` (${r.where})` : ""} | ${r.base} | ${r.new} |`);
        if (why.more > 0) hover.push("", `(${why.more} more changed: \`leanprof compare\` lists them)`);
      }
      for (const n of why.notes || []) hover.push("", `note: ${n}`);
    }
    add(line, { level, text, hover: hover.join("\n"), size: Math.abs(change) });
  }
  for (const [field, what] of [["copies", "copies"], ["allocations", "allocations"]]) {
    for (const c of delta[field] || []) {
      const { file, line } = parsePos(c.where);
      if (!line || !sameFile(file, rel)) continue;
      const change = c.change || 0;
      const text = `${signed(change, groupDigits)} ${what}`;
      const hover = `${code(c.key)}: ${groupDigits(c.base)} → ${groupDigits(c.new)} ${what} (${signed(change, groupDigits)} ${opts.sinceRun || "since the last run"}; exact)`;
      add(line, { level: change > 0 ? "red" : "down", text, hover, size: Math.abs(change) * 1e6 });
    }
  }
  const rank = { red: 3, up: 2, new: 1, down: 0 };
  const items = [];
  for (const [line, parts] of byLine) {
    parts.sort((a, b) => b.size - a.size);
    const level = parts.reduce((l, p) => (rank[p.level] > rank[l] ? p.level : l), "down");
    items.push({ line: line - 1, level, text: parts.map((p) => p.text).join(" · "), hover: parts.map((p) => p.hover).join("\n\n---\n\n") });
  }
  return items.sort((a, b) => a.line - b.line);
}

/** One line for the status bar and the log: what changed in a difference file. */
function deltaSummary(delta) {
  if (!delta) return "";
  if (delta.first || delta.comparable === false) return "first profile: the next save is compared with it";
  if (delta.kind === "elab") {
    const amount = delta.unit === "heartbeats" ? fmtKHB : fmtNs;
    const decls = delta.decls || [];
    const t = delta.total || {};
    const total = (t.new || 0) - (t.base || 0);
    if (!decls.length) return "no declaration changed";
    return `${decls.length} ${decls.length === 1 ? "declaration" : "declarations"} changed, ${signed(total, amount)} in the file`;
  }
  const parts = [];
  for (const [field, what] of [["copies", "copies"], ["allocations", "allocations"]]) {
    const rows = delta[field] || [];
    if (!rows.length) continue;
    parts.push(`${signed(rows.reduce((a, r) => a + (r.change || 0), 0), groupDigits)} ${what}`);
  }
  return parts.length ? parts.join(", ") : "no copies or allocations changed";
}

/**
 * The costliest declarations of `rel` in an `elab` report, costliest first:
 * { name, line (0-based), total, share (of the file), parts: {elab, kernel,
 * compiler, linters}, top: [{amount, op}] }. A declaration's lines (kernel and
 * compiler work can sit on later lines) are merged, at its first line.
 */
function slowest(report, rel, n = 10) {
  if (!report || !Array.isArray(report.scopes)) return { decls: [], total: 0, wallNs: 0, unit: "" };
  const byKey = new Map();
  for (const s of report.scopes) {
    const { file, line } = parsePos(s.pos);
    if (!line || !sameFile(file, rel)) continue;
    const key = s.key || `${s.name} ${s.pos}`;
    let d = byKey.get(key);
    if (!d) {
      d = { key, name: declName({ key: s.key, name: (s.name || "").replace(/\s+/g, " ") }), line: line - 1, total: 0,
        parts: { elab: 0, kernel: 0, compiler: 0, linters: 0 }, top: [] };
      byKey.set(key, d);
    }
    d.line = Math.min(d.line, line - 1);
    d.total += s.total_ns || 0;
    d.parts.elab += s.elab_ns || 0;
    d.parts.kernel += s.kernel_ns || 0;
    d.parts.compiler += s.compile_ns || 0;
    d.parts.linters += s.lint_ns || 0;
    d.top.push(...(s.top || []));
  }
  const decls = [...byKey.values()];
  const total = decls.reduce((a, d) => a + d.total, 0);
  for (const d of decls) {
    d.share = total > 0 ? d.total / total : 0;
    d.top.sort((a, b) => b.amount - a.amount);
    d.top = d.top.slice(0, 3);
  }
  decls.sort((a, b) => b.total - a.total || a.line - b.line);
  const f = (report.files || []).find((x) => sameFile(x.file, rel)) || {};
  // what is left of a command after its declaration (a few heartbeats on the last line) is not a row
  return { decls: decls.filter((d) => d.share >= 0.005).slice(0, n), total, wallNs: f.wall_ns || 0, errors: f.errors || 0, unit: report.unit || "" };
}

/**
 * Runs at most one job per key: `schedule(key, job[, delay])` waits `delay` ms (a
 * newer schedule of the key restarts the wait) and then runs `job(signal)`.
 * A job of the key still running is aborted first (its `signal` fires), so a
 * new save cancels the profile of the old one. Resolves with the job's
 * result, or `undefined` when it was superseded.
 */
class Debouncer {
  constructor(delay, timers = { setTimeout, clearTimeout }) {
    this.delay = delay;
    this.timers = timers;
    this.pending = new Map(); // key -> { timer, resolve }
    this.running = new Map(); // key -> AbortController
  }

  schedule(key, job, delay = this.delay) {
    const old = this.pending.get(key);
    if (old) {
      this.timers.clearTimeout(old.timer);
      old.resolve(undefined);
    }
    return new Promise((resolve, reject) => {
      const timer = this.timers.setTimeout(async () => {
        this.pending.delete(key);
        const prev = this.running.get(key);
        if (prev) prev.abort();
        const ctl = new AbortController();
        this.running.set(key, ctl);
        try {
          const r = await job(ctl.signal);
          resolve(ctl.signal.aborted ? undefined : r);
        } catch (e) {
          if (ctl.signal.aborted) resolve(undefined);
          else reject(e);
        } finally {
          if (this.running.get(key) === ctl) this.running.delete(key);
        }
      }, delay);
      this.pending.set(key, { timer, resolve });
    });
  }

  /** Whether a job of `key` waits or runs. */
  busy(key) {
    return this.pending.has(key) || this.running.has(key);
  }

  dispose() {
    for (const p of this.pending.values()) {
      this.timers.clearTimeout(p.timer);
      p.resolve(undefined);
    }
    this.pending.clear();
    for (const c of this.running.values()) c.abort();
    this.running.clear();
  }
}

module.exports = {
  onSaveReport, deltaOf, onSaveRunReport, parsePos, sameFile, groupDigits, fmtKHB, fmtNs, signed,
  declName, deltaItems, deltaSummary, slowest, Debouncer,
};
