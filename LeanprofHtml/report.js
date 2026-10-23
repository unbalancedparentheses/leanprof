// leanprof html: renders the report data embedded in the page. No network,
// no libraries. Data: {title, project, threshold, min_ms, sources, reports:
// [{path, kind: run|sample|elab|measure, role: only|base|new, data, flame?}]}.
"use strict";
(function () {
const D = JSON.parse(document.getElementById("leanprof-data").textContent);

// ---------- helpers ----------
function h(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  if (attrs) for (const k in attrs) {
    const v = attrs[k];
    if (v == null || v === false) continue;
    if (k === "class") e.className = v;
    else if (k === "style") e.style.cssText = v;
    else if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const c of kids.flat(Infinity)) if (c != null && c !== false) e.append(c instanceof Node ? c : String(c));
  return e;
}
const num = (o, k) => (o && typeof o[k] === "number" ? o[k] : 0);
const arr = (o, k) => (o && Array.isArray(o[k]) ? o[k] : []);
const sum = (xs, f) => xs.reduce((a, x) => a + f(x), 0);
function sig(x) { const a = Math.abs(x); return a >= 100 ? x.toFixed(0) : a >= 10 ? x.toFixed(1) : x.toFixed(2); }
const fN = (n) => Math.round(n).toLocaleString("en-US");
function fNs(ns) {
  const a = Math.abs(ns);
  if (a < 1e3) return Math.round(ns) + " ns";
  if (a < 1e6) return sig(ns / 1e3) + " µs";
  if (a < 1e9) return sig(ns / 1e6) + " ms";
  return sig(ns / 1e9) + " s";
}
function fBytes(b) {
  const a = Math.abs(b);
  if (a < 1024) return Math.round(b) + " B";
  if (a < 1048576) return sig(b / 1024) + " KiB";
  if (a < 1073741824) return sig(b / 1048576) + " MiB";
  return sig(b / 1073741824) + " GiB";
}
const fHB = (x) => (Math.abs(x) >= 1e6 ? sig(x / 1e6) + " MHB" : sig(x / 1e3) + " kHB");
const fPct = (x) => (isFinite(x) ? sig(x) + "%" : "–");
function change(b, n, f) {
  const d = n - b;
  if (d === 0) return "0";
  const pct = b > 0 ? " (" + (d > 0 ? "+" : "−") + sig(Math.abs(d / b * 100)) + "%)" : "";
  return (d > 0 ? "+" : "−") + f(Math.abs(d)) + pct;
}
const isPos = (s) => typeof s === "string" && /\.lean:\d+$/.test(s);
// `File.lean:12:3-12:40` as `12:3-12:40`
const rangeCols = (s) => s.split(":").slice(-3).join(":");
function hashStr(s) { let x = 2166136261; for (let i = 0; i < s.length; i++) { x ^= s.charCodeAt(i); x = Math.imul(x, 16777619); } return x >>> 0; }

// ---------- the reports ----------
const by = {};
for (const r of D.reports) {
  const c = r.kind === "sample" ? "run" : r.kind;
  by[c] = by[c] || {};
  by[c][r.role === "base" ? "base" : "cur"] = r;
}
const run = by.run && by.run.cur, runB = by.run && by.run.base;
const elab = by.elab && by.elab.cur, elabB = by.elab && by.elab.base;
const meas = by.measure && by.measure.cur, measB = by.measure && by.measure.base;
const sampled = !!run && run.kind === "sample";
const hbUnit = (rep) => !!rep && rep.data.unit === "heartbeats";
const fAmt = (rep) => (hbUnit(rep) ? fHB : fNs);
const sources = D.sources || {};

// ---------- hints, as the editor shows them ----------
const hints = new Map(); // "file:line" -> [{label, tip, cls}]
const NEAR_PROBE = "near the probe cost: use `leanprof sample` for this function's time";
function addHint(pos, label, tip, cls) {
  if (!isPos(pos)) return;
  if (!hints.has(pos)) hints.set(pos, []);
  hints.get(pos).push({ label, tip, cls });
}
if (run) {
  const d = run.data, wall = num(d, "wall_ns");
  const best = new Map();
  for (const s of arr(d, "scopes")) {
    if (!isPos(s.pos)) continue;
    const t = num(s, "total_ns"), pct = wall > 0 ? t / wall * 100 : 0;
    const near = !sampled && s.near_probe_cost === true;
    const label = sampled ? "≈ " + fNs(t) + " CPU · " + fPct(pct) : "⏱ " + fNs(t) + (near ? "*" : "") + " · " + fPct(pct) + " · " + fN(num(s, "calls")) + "×";
    const tip = sampled ? s.name + ": " + fNs(t) + " CPU inclusive (sampled)"
      : s.name + ": " + fN(num(s, "calls")) + " calls, total " + fNs(t) + ", self " + fNs(num(s, "self_ns")) +
        ", mean " + fNs(num(s, "mean_ns")) + ", p50 " + fNs(num(s, "p50_ns")) + ", p99 " + fNs(num(s, "p99_ns")) +
        (near ? "\n* " + NEAR_PROBE : "");
    const b = best.get(s.pos);
    if (!b || b.t < t) best.set(s.pos, { t, label, tip });
  }
  for (const [p, b] of best) addHint(p, b.label, b.tip, "time");
  for (const c of arr(d, "copies")) {
    const n = num(c, "shared") + num(c, "multi_threaded");
    if (n > 0) addHint(c.where, "⚠ " + fN(n) + " copies · " + fBytes(num(c, "bytes")) + " · " + fNs(num(c, "copy_ns")),
      c.function + " copied a " + (num(c, "multi_threaded") > 0 ? "multi-threaded" : "shared") + " " + c.kind + " " + fN(n) +
      " times in scope " + c.scope + ": another reference was still alive, so it could not be updated in place.", "copy");
  }
  const allocs = new Map();
  for (const a of arr(d, "allocations")) if (isPos(a.where)) {
    const e = allocs.get(a.where) || { n: 0, b: 0 };
    e.n += num(a, "allocs"); e.b += num(a, "bytes"); allocs.set(a.where, e);
  }
  for (const [p, e] of allocs) addHint(p, "▲ " + fN(e.n) + " allocs · " + fBytes(e.b), "allocations by compiled code of this declaration", "alloc");
}
if (elab) {
  const f = fAmt(elab), best = new Map();
  for (const s of arr(elab.data, "scopes")) {
    if (!isPos(s.pos)) continue;
    const t = num(s, "total_ns");
    const ops = arr(s, "top").map((o) => "\n  " + f(num(o, "amount")) + "  " + o.op).join("");
    const tip = "compile cost: elaboration " + f(num(s, "elab_ns")) + ", kernel " + f(num(s, "kernel_ns")) + ", compiler " +
      f(num(s, "compile_ns")) + ", linters " + f(num(s, "lint_ns")) + (ops ? "\ncostliest operations:" + ops : "");
    const b = best.get(s.pos);
    if (!b || b.t < t) best.set(s.pos, { t, label: "⚙ " + f(t) + " to compile", tip });
  }
  // terms and tactics by exact source range (elab with its driver), in the hint of their line
  const byLine = new Map();
  for (const r of arr(elab.data, "ranges")) {
    if (!isPos(r.pos)) continue;
    if (!byLine.has(r.pos)) byLine.set(r.pos, []);
    byLine.get(r.pos).push(r);
  }
  for (const [p, rs] of byLine) {
    rs.sort((a, b) => num(b, "amount") - num(a, "amount"));
    const list = "by exact source range (line:column, inclusive):" + rs.slice(0, 6).map((r) => "\n  " + rangeCols(r.range) + "  " +
      f(num(r, "amount")) + (num(r, "count") > 1 ? " (" + num(r, "count") + "×)" : "") + "  " + r.kind + " " + (r.syntax || "").split(".").pop() + ": " + r.text).join("");
    const b = best.get(p);
    if (b) b.tip += "\n" + list;
    else best.set(p, { t: num(rs[0], "amount"), label: "⚙ " + f(num(rs[0], "amount")), tip: list });
  }
  for (const [p, b] of best) addHint(p, b.label, b.tip, "compile");
}

// ---------- source ----------
function splitPos(p) { const i = p.lastIndexOf(":"); return [p.slice(0, i), +p.slice(i + 1)]; }
function srcLines(file, lines, at) {
  const src = sources[file] || {};
  const box = h("div", { class: "src" });
  let prev = null;
  for (const n of lines) {
    if (prev != null && n > prev + 1) box.append(h("div", { class: "gap" }, "⋯"));
    prev = n;
    const hs = hints.get(file + ":" + n) || [];
    box.append(h("div", { class: "l" + (n === at || (at == null && hs.length) ? " at" : "") },
      h("span", { class: "ln" }, n), h("span", null, src[n] == null ? "" : src[n]),
      hs.map((x) => h("span", { class: "hint " + x.cls, title: x.tip }, x.label))));
  }
  return box;
}
function context(pos, n) {
  const [file, line] = splitPos(pos);
  const src = sources[file];
  if (!src || src[line] == null) return h("div", { class: "empty" }, "The source of " + pos + " was not found under the project directory when this page was made.");
  const lines = [];
  for (let k = line - n; k <= line + n; k++) if (src[k] != null) lines.push(k);
  return srcLines(file, lines, line);
}
const drawer = h("div", { id: "drawer" });
function openSource(pos) {
  drawer.replaceChildren(
    h("div", { class: "bar" }, h("b", null, pos), h("span", { class: "grow" }),
      h("button", { onclick: () => { selectTab("source"); const el = document.getElementById("file-" + splitPos(pos)[0]); if (el) el.scrollIntoView(); drawer.style.display = "none"; } }, "whole file"),
      h("button", { onclick: () => { drawer.style.display = "none"; } }, "close")),
    context(pos, 4));
  drawer.style.display = "block";
}
function posLink(p) {
  if (!isPos(p)) return p ? h("span", { class: "mono" }, p) : "";
  return h("a", { class: "pos", title: "show the source", onclick: (e) => { e.preventDefault(); openSource(p); } }, p);
}

// ---------- sortable, filterable tables ----------
// cols: {t: title, v: row => value, f?: (value, row) => text|Node, num?, bar?, wrap?, tip?}
function table(rows, cols, o) {
  o = o || {};
  let sortI = o.sort != null ? o.sort : Math.max(0, cols.findIndex((c) => c.bar));
  let asc = !!o.asc, q = "", limit = 200;
  const wrap = h("div");
  const input = h("input", { type: "search", placeholder: "filter " + (o.what || "rows") + "…", oninput: () => { q = input.value.toLowerCase(); limit = 200; draw(); } });
  const count = h("span", { class: "note", style: "margin:0" });
  const tw = h("div", { class: "tw" });
  wrap.append(h("div", { class: "bar" }, input, count), tw);
  const text = (c, r) => { const v = c.v(r); return v == null ? "" : String(v); };
  function draw() {
    const shown = rows.filter((r) => !q || cols.some((c) => !c.num && text(c, r).toLowerCase().includes(q)));
    const c0 = cols[sortI];
    shown.sort((a, b) => {
      const x = c0.v(a), y = c0.v(b);
      const r = typeof x === "number" && typeof y === "number" ? x - y : String(x == null ? "" : x).localeCompare(String(y == null ? "" : y));
      return asc ? r : -r;
    });
    const max = cols.map((c) => (c.bar ? Math.max(0, ...shown.map((r) => +c.v(r) || 0)) : 0));
    const thead = h("tr", null, cols.map((c, i) => h("th", {
      class: (c.num ? "num " : "") + (i === sortI ? "sorted" + (asc ? " asc" : "") : ""), title: c.tip || "sort",
      onclick: () => { if (sortI === i) asc = !asc; else { sortI = i; asc = !c.num; } draw(); } }, c.t)));
    const body = shown.slice(0, limit).map((r) => h("tr", { class: o.rowClass ? o.rowClass(r) : null }, cols.map((c, i) => {
      const v = c.v(r);
      const td = h("td", { class: (c.num ? "num" : "") + (c.wrap ? " wrap" : "") + (c.bar ? " cell-bar" : "") },
        c.f ? c.f(v, r) : c.pos ? posLink(v) : v == null ? "" : v);
      if (c.bar && max[i] > 0) td.style.setProperty("--w", ((+v || 0) / max[i]).toFixed(3));
      return td;
    })));
    tw.replaceChildren(h("table", null, h("thead", null, thead), h("tbody", null, body)));
    const rws = (n) => fN(n) + (n === 1 ? " row" : " rows");
    count.textContent = shown.length === rows.length ? rws(rows.length) : fN(shown.length) + " of " + rws(rows.length);
    if (shown.length > limit) tw.append(h("div", { class: "more" }, h("button", { onclick: () => { limit = Infinity; draw(); } }, "show all " + fN(shown.length))));
  }
  draw();
  return wrap;
}
const col = (t, k, f, extra) => Object.assign({ t, v: (r) => r[k], f }, extra || {});
const ncol = (t, k, f, extra) => Object.assign({ t, v: (r) => num(r, k), f: f || fN, num: true }, extra || {});
const pcol = (t, k) => ({ t, v: (r) => r[k], pos: true });

// ---------- flame graph (icicle: callers above callees) ----------
const isDark = () => {
  const t = document.documentElement.getAttribute("data-theme");
  return t === "dark" || (t !== "light" && matchMedia("(prefers-color-scheme: dark)").matches);
};
const KINDS = {
  lean: [215, 55, "Lean code"], rt: [35, 75, "Lean runtime"], copy: [3, 70, "copying shared values"],
  free: [55, 60, "freeing objects"], sys: [220, 6, "system libraries"], prof: [150, 35, "leanprof"],
  other: [265, 35, "other"], elab: [215, 55, "elaboration"], kernel: [160, 45, "kernel"],
  compile: [35, 75, "compiler"], lint: [290, 35, "linters"], file: [220, 6, "file"],
};
function kindOf(n) {
  if (n.k) return n.k;
  const s = n.n;
  if (/lean_copy_|copy_expand/.test(s)) return "copy";
  if (/lean_dec_ref|del_core|lean_free|_mi_free|mi_free/.test(s)) return "free";
  if (n.p) return "lean";
  if (s.startsWith("[")) return "sys";
  if (/^_?(leanprof_|lpf_)/.test(s)) return "prof";
  if (/^_?(lean_|mi_|_mi_)|lean::/.test(s)) return "rt";
  return "other";
}
function colorOf(n) {
  const [hue, sat] = KINDS[kindOf(n)];
  const j = hashStr(n.n);
  const dh = (j % 21) - 10, dl = (j >> 5) % 9;
  return "hsl(" + (hue + dh) + "," + sat + "%," + (isDark() ? 30 + dl : 72 + dl) + "%)";
}
const flames = [];
// direct recursion (f calling f) folded into one frame, as flame graph tools offer
function mergeInto(a, b) {
  a.v += b.v;
  for (const c of b.c) { const e = a.c.find((x) => x.n === c.n); if (e) mergeInto(e, c); else a.c.push(c); }
}
function foldRecursion(n) {
  const out = { n: n.n, v: n.v, p: n.p, k: n.k, c: [] };
  const add = (c) => {
    if (c.n === n.n) { (c.c || []).forEach(add); return; }
    const m = foldRecursion(c), e = out.c.find((x) => x.n === m.n);
    if (e) mergeInto(e, m); else out.c.push(m);
  };
  (n.c || []).forEach(add);
  out.c.sort((a, b) => b.v - a.v);
  return out;
}
function prep(n, parent) {
  n.parent = parent; n.c = n.c || [];
  n.self = n.v - sum(n.c, (c) => c.v);
  for (const c of n.c) prep(c, n);
  return n;
}
function flame(orig, o) {
  const folded = foldRecursion(orig);
  let root = prep(folded, null);
  const fmt = o.fmt || fNs;
  let zoom = root, query = "";
  const area = h("div", { class: "flame" });
  const crumbs = h("div", { class: "crumbs" });
  const info = h("div", { class: "note", style: "margin:6px 0 0" }, "Click a frame to zoom in, click a dimmed frame above to zoom out; hover for details.");
  const found = h("span", { class: "note", style: "margin:0" });
  const input = h("input", { type: "search", placeholder: "search frames…", oninput: () => { query = input.value.toLowerCase(); draw(); } });
  const tip = document.getElementById("tip");
  function describe(n) {
    const pctAll = root.v > 0 ? n.v / root.v * 100 : 0;
    return [h("b", null, n.n), n.p ? h("div", { class: "mono" }, n.p) : null,
      h("div", null, fmt(n.v) + " · " + fPct(pctAll) + " of all" + (zoom !== root && zoom.v > 0 ? " · " + fPct(n.v / zoom.v * 100) + " of zoom" : "")),
      h("div", null, "self " + fmt(n.self))];
  }
  function draw() {
    const W = area.clientWidth || 800, ROW = 18;
    const nodes = [];
    const anc = [];
    for (let a = zoom.parent; a; a = a.parent) anc.unshift(a);
    anc.forEach((a, i) => nodes.push([a, 0, 100, i, "anc"]));
    const scale = zoom.v > 0 ? 100 / zoom.v : 0;
    let maxRow = anc.length;
    (function lay(n, x, row) {
      const w = n.v * scale;
      if (w * W / 100 < 1.5) return;
      nodes.push([n, x, w, row, ""]);
      if (row > maxRow) maxRow = row;
      let cx = x;
      for (const c of n.c) { lay(c, cx, row + 1); cx += c.v * scale; }
    })(zoom, 0, anc.length);
    let matched = 0;
    const frag = document.createDocumentFragment();
    for (const [n, x, w, row, cls] of nodes) {
      const m = query && n.n.toLowerCase().includes(query);
      if (m && cls !== "anc") {
        let a = n.parent, inner = false;
        while (a && a !== zoom.parent) { if (a.n.toLowerCase().includes(query)) { inner = true; break; } a = a.parent; }
        if (!inner) matched += n.v;
      }
      const e = h("div", { class: "f " + cls + (m ? " match" : query ? " dim" : "") });
      e.style.cssText = "left:" + x + "%;width:" + w + "%;top:" + row * ROW + "px;background:" + colorOf(n) + (isDark() ? ";color:#eef0f3" : "");
      if (w * W / 100 > 28) e.textContent = n.n;
      e._n = n;
      frag.append(e);
    }
    area.replaceChildren(frag);
    area.style.height = (maxRow + 1) * ROW + 4 + "px";
    found.textContent = query ? "matched " + fPct(zoom.v > 0 ? matched / zoom.v * 100 : 0) + " of the view (" + fmt(matched) + ")" : "";
    const path = [];
    for (let a = zoom; a; a = a.parent) path.unshift(a);
    crumbs.replaceChildren(...path.flatMap((a, i) => [i ? " › " : "", h("a", { href: "#", onclick: (e) => { e.preventDefault(); zoom = a; draw(); } }, a.n)]));
  }
  area.addEventListener("click", (e) => {
    const n = e.target._n;
    if (!n) return;
    zoom = n === zoom && n.parent ? n.parent : n;
    info.replaceChildren(h("b", null, n.n), "  ", fmt(n.v), " total, ", fmt(n.self), " self", n.p ? "  " : "", n.p ? posLink(n.p) : "");
    draw();
  });
  area.addEventListener("mousemove", (e) => {
    const n = e.target._n;
    if (!n) { tip.style.display = "none"; return; }
    tip.replaceChildren(...describe(n));
    tip.style.display = "block";
    const r = tip.getBoundingClientRect();
    tip.style.left = Math.min(e.clientX + 14, innerWidth - r.width - 8) + "px";
    tip.style.top = (e.clientY + 16 + r.height > innerHeight ? e.clientY - r.height - 10 : e.clientY + 16) + "px";
  });
  area.addEventListener("mouseleave", () => { tip.style.display = "none"; });
  const used = new Set();
  (function walk(n) { used.add(kindOf(n)); n.c.forEach(walk); })(root);
  const legend = h("div", { class: "legend" }, [...used].map((k) => h("span", null, h("i", { style: "background:" + colorOf({ n: "", k }) }), KINDS[k][2])));
  const fold = h("input", { type: "checkbox", checked: true, onchange: () => { root = fold.checked ? folded : prep(orig, null); zoom = root; draw(); } });
  const el = h("div", null, h("div", { class: "bar" }, input, found, h("span", { class: "grow" }),
    h("label", { class: "note", style: "margin:0", title: "fold f calling f into one frame" }, fold, " fold recursion"),
    h("button", { onclick: () => { zoom = root; draw(); } }, "reset zoom")), crumbs, area, info, legend);
  el._draw = draw;
  flames.push(el);
  requestAnimationFrame(draw);
  return el;
}
addEventListener("resize", () => flames.forEach((f) => f.isConnected && f._draw()));

// ---------- trees from the reports ----------
function runTree() {
  if (run.flame) return run.flame;
  const d = run.data;
  const kids = arr(d, "scopes").filter((s) => num(s, "self_ns") > 0)
    .map((s) => ({ n: s.name + (s.auto ? "" : " (profile!)"), v: num(s, "self_ns"), p: s.pos || undefined, k: s.pos ? "lean" : "other" }))
    .sort((a, b) => b.v - a.v);
  return { n: "self time per scope", v: Math.max(num(d, "wall_ns"), sum(kids, (k) => k.v)), c: kids, k: "file" };
}
function compileTree() {
  const files = new Map();
  for (const s of arr(elab.data, "scopes")) {
    const [file] = isPos(s.pos) ? splitPos(s.pos) : [s.pos || "?"];
    if (!files.has(file)) files.set(file, []);
    const parts = [["elaboration", "elab_ns", "elab"], ["kernel", "kernel_ns", "kernel"], ["compiler", "compile_ns", "compile"], ["linters", "lint_ns", "lint"]]
      .map(([n, k, kind]) => ({ n, v: num(s, k), k: kind })).filter((p) => p.v > 0).sort((a, b) => b.v - a.v);
    files.get(file).push({ n: (s.name || s.pos).slice(0, 80), v: num(s, "total_ns"), p: s.pos, k: "elab", c: parts });
  }
  const c = [...files].map(([n, kids]) => ({ n, v: sum(kids, (k) => k.v), k: "file", c: kids.sort((a, b) => b.v - a.v) })).sort((a, b) => b.v - a.v);
  return { n: "compile", v: sum(c, (x) => x.v), k: "file", c };
}

// ---------- comparison (the rules of `leanprof compare`) ----------
function scopeMap(rep) {
  const m = new Map();
  for (const s of arr(rep.data, "scopes")) {
    const k = s.key || s.name + " " + s.pos;
    const e = m.get(k) || { t: 0, c: 0 };
    e.t += num(s, "total_ns"); e.c += num(s, "calls"); m.set(k, e);
  }
  return m;
}
function copyMap(rep) {
  const m = new Map();
  for (const c of arr(rep.data, "copies")) {
    const n = num(c, "shared") + num(c, "multi_threaded");
    if (n > 0) { const k = c.function + " [" + c.kind + "] in " + c.scope; m.set(k, (m.get(k) || 0) + n); }
  }
  return m;
}
const fnName = (j) => (String(j.function || "").startsWith("0x") ? "(no symbol)" : j.function);
function allocMap(rep) {
  const m = new Map();
  for (const a of arr(rep.data, "allocations")) { const k = fnName(a) + " in " + a.scope; m.set(k, (m.get(k) || 0) + num(a, "allocs")); }
  return m;
}
function comparePair(b, n) {
  const exact = hbUnit(b) && hbUnit(n), thr = D.threshold, minMs = D.min_ms;
  const bs = scopeMap(b), ns = scopeMap(n), scopes = [];
  for (const k of new Set([...bs.keys(), ...ns.keys()])) {
    const x = bs.get(k), y = ns.get(k);
    if (x && y) {
      const pct = x.t > 0 ? (y.t - x.t) / x.t * 100 : 0;
      const slower = exact ? y.t - x.t > Math.max(x.t * 0.01, 1000) : pct > thr && (y.t - x.t) / 1e6 > minMs;
      const calls = x.c !== y.c;
      scopes.push({ k, b: x.t, n: y.t, pct, bc: x.c, nc: y.c, st: slower || calls ? "regression" : pct < -thr ? "faster" : "ok",
        why: slower && calls ? "slower, calls changed" : slower ? "slower" : calls ? "calls changed" : "" });
    } else if (y) scopes.push({ k, b: 0, n: y.t, pct: NaN, bc: 0, nc: y.c, st: "new", why: "" });
    else scopes.push({ k, b: x.t, n: 0, pct: NaN, bc: x.c, nc: 0, st: "gone", why: "" });
  }
  const bc = copyMap(b), nc = copyMap(n), copies = [];
  for (const k of new Set([...bc.keys(), ...nc.keys()])) {
    const x = bc.get(k) || 0, y = nc.get(k) || 0;
    copies.push({ k, b: x, n: y, st: y > x ? "regression" : y < x ? "fewer" : "same" });
  }
  const ba = allocMap(b), na = allocMap(n), allocs = [];
  for (const k of new Set([...ba.keys(), ...na.keys()])) {
    const x = ba.get(k) || 0, y = na.get(k) || 0;
    if (x !== y) allocs.push({ k, b: x, n: y, st: y > x ? "more" : "fewer" });
  }
  const regressions = scopes.filter((s) => s.st === "regression").length + copies.filter((c) => c.st === "regression").length;
  return { exact, scopes, copies, allocs, regressions };
}
const pairs = [];
if (run && runB) pairs.push({ name: "run", b: runB, n: run, r: comparePair(runB, run) });
if (elab && elabB) pairs.push({ name: "compile", b: elabB, n: elab, r: comparePair(elabB, elab) });
// measure summaries: what makes `leanprof judge` say DISCARD
function judgeWorse(b, n) {
  const out = [];
  if (JSON.stringify(b.command) !== JSON.stringify(n.command)) out.push("different commands");
  if (num(b, "exit_code") !== num(n, "exit_code")) out.push("exit code changed");
  if ((b.output || {}).hash !== (n.output || {}).hash) out.push("output changed");
  if (num(n, "copies_total") > num(b, "copies_total")) out.push("more copies");
  if (b.heartbeats_total != null && n.heartbeats_total != null &&
      num(n, "heartbeats_total") - num(b, "heartbeats_total") > Math.max(num(b, "heartbeats_total") * 0.01, 1000)) out.push("more heartbeats");
  if (num(n.time_ns, "min") > num(b.time_ns, "max")) out.push("every run slower");
  return out;
}
const measWorse = meas && measB ? judgeWorse(measB.data, meas.data) : [];
const totalRegressions = sum(pairs, (p) => p.r.regressions) + measWorse.length;

// ---------- summary tiles ----------
function tile(k, v, d, bv, fmt, higherBad) {
  const kids = [h("div", { class: "k" }, k), h("div", { class: "v", title: v }, v)];
  if (d) kids.push(h("div", { class: "d" }, d));
  if (bv && bv.base != null) {
    const delta = bv.cur - bv.base;
    const cls = delta === 0 ? "" : (delta > 0) === (higherBad !== false) ? "delta-bad" : "delta-good";
    kids.push(h("div", { class: "d" }, "base " + fmt(bv.base) + " · ", h("span", { class: cls }, change(bv.base, bv.cur, fmt))));
  }
  return h("div", { class: "tile" }, kids);
}
function runTiles() {
  const out = [], d = run.data, bd = runB && runB.data;
  const pair = (f) => (bd ? { base: f(bd), cur: f(d) } : null);
  const mem = d.memory;
  if (sampled) {
    out.push(tile("CPU sampled", fNs(num(d, "wall_ns")), "samply, no instrumentation", pair((x) => num(x, "wall_ns")), fNs));
  } else {
    const wall = (x) => (x.memory && num(x.memory, "wall_ns")) || num(x, "wall_ns");
    out.push(tile("wall", fNs(wall(d)), "program start to exit", pair(wall), fNs));
  }
  if (mem) {
    const cpu = (x) => num(x.memory, "user_ns") + num(x.memory, "sys_ns");
    const w = num(mem, "wall_ns");
    out.push(tile("CPU", fNs(cpu(d)), fNs(num(mem, "user_ns")) + " user + " + fNs(num(mem, "sys_ns")) + " sys" + (w > 0 ? " · " + (cpu(d) / w).toFixed(2) + " cores" : ""), bd && bd.memory ? { base: cpu(bd), cur: cpu(d) } : null, fNs));
    out.push(tile("peak memory", fBytes(num(mem, "peak_rss")), fBytes(num(mem, "peak_commit")) + " committed by Lean's allocator", bd && bd.memory ? { base: num(bd.memory, "peak_rss"), cur: num(mem, "peak_rss") } : null, fBytes));
  }
  const al = (x) => sum(arr(x, "allocations"), (a) => num(a, "allocs"));
  if (arr(d, "allocations").length) out.push(tile("allocations", fN(al(d)), fBytes(sum(arr(d, "allocations"), (a) => num(a, "bytes"))) + " by compiled Lean code", pair(al), fN));
  if (!sampled) {
    const cp = (x) => sum(arr(x, "copies"), (c) => num(c, "shared") + num(c, "multi_threaded"));
    const sh = arr(d, "copies").filter((c) => num(c, "shared") + num(c, "multi_threaded") > 0);
    out.push(tile("copies", fN(cp(d)), "of shared values · " + fBytes(sum(sh, (c) => num(c, "bytes"))) + " · " + fNs(sum(sh, (c) => num(c, "copy_ns"))), pair(cp), fN));
  }
  if (d.frees) out.push(tile("frees", fN(num(d.frees, "objects")), fN(num(d.frees, "cascades")) + " cascades · " + fNs(num(d.frees, "free_ns")) + " · max pause " + fNs(num(d.frees, "max_ns")), bd && bd.frees ? { base: num(bd.frees, "objects"), cur: num(d.frees, "objects") } : null, fN));
  const tk = (x) => sum(arr(x, "tasks"), (t) => num(t, "tasks"));
  if (arr(d, "tasks").length) out.push(tile("tasks", fN(tk(d)), fNs(sum(arr(d, "tasks"), (t) => num(t, "run_sum_ns"))) + " run · " + fNs(sum(arr(d, "tasks"), (t) => num(t, "wait_ns"))) + " queued", pair(tk), fN));
  if (arr(d, "waits").length) out.push(tile("blocking waits", fN(sum(arr(d, "waits"), (w) => num(w, "waits"))), fNs(sum(arr(d, "waits"), (w) => num(w, "blocked_ns"))) + " blocked"));
  if (arr(d, "reuse").length) out.push(tile("failed reuse", fN(sum(arr(d, "reuse"), (r) => num(r, "failures"))), "of " + fN(sum(arr(d, "reuse"), (r) => num(r, "checks"))) + " checks"));
  if (arr(d, "closures").length) out.push(tile("closure calls", fN(sum(arr(d, "closures"), (c) => num(c, "applications"))), arr(d, "closures").length + " call sites and targets"));
  const top = arr(d, "scopes").slice().sort((a, b) => num(b, "total_ns") - num(a, "total_ns"))[0];
  if (top) out.push(tile("top scope", top.name, fNs(num(top, "total_ns")) + (top.pos ? " · " + top.pos : "")));
  return out;
}
function elabTiles() {
  const d = elab.data, f = fAmt(elab), out = [];
  const tot = (x) => sum(arr(x, "scopes"), (s) => num(s, "total_ns"));
  out.push(tile(hbUnit(elab) ? "compile heartbeats" : "compile time", f(tot(d)), hbUnit(elab) ? "exact, the same on every run" : "wall time, noisy", elabB ? { base: tot(elabB.data), cur: tot(d) } : null, f));
  out.push(tile("lines with cost", fN(arr(d, "scopes").length), new Set(arr(d, "scopes").map((s) => isPos(s.pos) ? splitPos(s.pos)[0] : s.pos)).size + " files"));
  if (arr(d, "repeated").length) out.push(tile("repeated work", fN(arr(d, "repeated").length), "operations done more than once"));
  const top = arr(d, "scopes").slice().sort((a, b) => num(b, "total_ns") - num(a, "total_ns"))[0];
  if (top) out.push(tile("costliest line", top.name || top.pos, f(num(top, "total_ns")) + " · " + top.pos));
  return out;
}
function measTiles() {
  const d = meas.data, bd = measB && measB.data, t = d.time_ns || {}, out = [];
  out.push(tile("median time", fNs(num(t, "median")), d.runs + " runs · " + fNs(num(t, "min")) + " – " + fNs(num(t, "max")), bd ? { base: num(bd.time_ns, "median"), cur: num(t, "median") } : null, fNs));
  out.push(tile("copies", fN(num(d, "copies_total")), d.copies_stable === false ? "differ between runs" : "shared + multi-threaded", bd ? { base: num(bd, "copies_total"), cur: num(d, "copies_total") } : null, fN));
  if (d.heartbeats_total != null) out.push(tile("compile heartbeats", fHB(num(d, "heartbeats_total")), "measured files", bd && bd.heartbeats_total != null ? { base: num(bd, "heartbeats_total"), cur: num(d, "heartbeats_total") } : null, fHB));
  out.push(tile("exit code", String(num(d, "exit_code")), (d.output && d.output.hash) || ""));
  return out;
}

// ---------- tabs ----------
const tabs = [];
const addTab = (id, label, count, render) => tabs.push({ id, label, count, render });
const panel = (title, note, ...body) => h("div", { class: "panel" }, title ? h("h2", null, title) : null, note ? h("p", { class: "note" }, note) : null, body);
const whyOf = (c) => ["shared", "multi_threaded", "persistent"].filter((k) => num(c, k) > 0).map((k) => k.replace("_", "-") + " " + fN(num(c, k))).join(", ");

if (run || elab) addTab("flame", run && (run.flame || sampled) ? "Flame graph" : "Overview", null, () => {
  const out = [];
  if (run) {
    const t = runTree();
    const note = sampled ? (run.flame ? "Sampled CPU time by call stack, from samply's profile " + run.flame_from + ". Each frame's width is its share of CPU time; its children are what it called."
        : "No samply profile was found next to " + run.path + " (EXE.json and EXE.syms.json, written by leanprof sample); pass --profile FILE. The Declarations tab has sampled time per declaration.")
      : run.flame ? "Time per scope by call path, from the timeline " + run.flame_from + "."
      : "A run report records time per scope but not who called whom, so this shows each scope's self time. For the call tree, render with --trace FILE from `leanprof run --trace FILE`, or use `leanprof sample`.";
    out.push(panel(sampled ? "CPU flame graph" : "Run time", note, sampled && !run.flame ? null : flame(t, { fmt: fNs })));
  }
  if (elab) out.push(panel("Compile cost", "Per file, line and phase (elaboration, kernel, compiler, linters), from " + elab.path + ".", flame(compileTree(), { fmt: fAmt(elab) })));
  return out;
});

if (run) {
  const d = run.data, wall = num(d, "wall_ns");
  if (arr(d, "scopes").length) addTab("scopes", sampled ? "Declarations" : "Scopes", arr(d, "scopes").length, () => panel(null,
    sampled ? "Sampled CPU time per Lean declaration, inclusive of what it calls." : "Exact time and calls per scope (profile! labels and, with --auto, functions), leanprof's own cost subtracted. * " + NEAR_PROBE + ".",
    table(arr(d, "scopes"), sampled ? [col("declaration", "name"), pcol("where", "pos"), ncol("CPU (incl.)", "total_ns", fNs, { bar: true }), { t: "% CPU", v: (r) => wall > 0 ? num(r, "total_ns") / wall * 100 : 0, f: fPct, num: true }]
      : [col("scope", "name"), pcol("where", "pos"), { t: "kind", v: (r) => (r.auto ? "function" : "profile!") }, ncol("calls", "calls"), ncol("total", "total_ns", (v, r) => r && r.near_probe_cost === true ? h("span", { title: NEAR_PROBE }, fNs(v) + "*") : fNs(v), { bar: true }), ncol("self", "self_ns", fNs),
        { t: "% wall", v: (r) => wall > 0 ? num(r, "total_ns") / wall * 100 : 0, f: fPct, num: true }, ncol("mean", "mean_ns", fNs), ncol("p50", "p50_ns", fNs), ncol("p99", "p99_ns", fNs), ncol("max", "max_ns", fNs),
        ncol("allocs", "allocs"), ncol("alloc bytes", "alloc_bytes", fBytes)], { what: "scopes" })));
  if (sampled && run.flame) addTab("self", "Self time", null, () => {
    const self = new Map(), incl = new Map(), pos = new Map();
    const onPath = new Map();
    (function walk(n) {
      onPath.set(n.n, (onPath.get(n.n) || 0) + 1);
      self.set(n.n, (self.get(n.n) || 0) + n.self);
      if (n.p) pos.set(n.n, n.p);
      for (const name of onPath.keys()) incl.set(name, (incl.get(name) || 0) + n.self);
      n.c.forEach(walk);
      const k = onPath.get(n.n) - 1;
      if (k) onPath.set(n.n, k); else onPath.delete(n.n);
    })(run.flame);
    const total = run.flame.v;
    const rows = [...self].filter(([n]) => n !== run.flame.n).map(([n, s]) => ({ name: n, self: s, incl: incl.get(n) || 0, pos: pos.get(n) || "", kind: KINDS[kindOf({ n, p: pos.get(n) })][2] }));
    return panel(null, "Every function in the sampled stacks, Lean or not: self time is where the CPU was, inclusive time adds what it called.",
      table(rows, [col("function", "name", null, { wrap: true }), pcol("where", "pos"), col("kind", "kind"), ncol("self", "self", fNs, { bar: true }),
        { t: "% self", v: (r) => r.self / total * 100, f: fPct, num: true }, ncol("inclusive", "incl", fNs), { t: "% incl.", v: (r) => r.incl / total * 100, f: fPct, num: true }], { what: "functions" }));
  });
  const scopeTotal = new Map();
  for (const s of arr(d, "scopes")) scopeTotal.set(s.name, Math.max(scopeTotal.get(s.name) || 0, num(s, "total_ns")));
  if (arr(d, "copies").length) addTab("copies", "Copies", arr(d, "copies").length, () => panel(null,
    "Copies of arrays, strings and byte arrays that were not exclusive. Shared: another reference was alive; multi-threaded: the value was shared between threads; persistent: a compile-time constant (not counted as a regression).",
    table(arr(d, "copies"), [col("function", "function", null, { wrap: true }), col("kind", "kind"), { t: "why", v: whyOf }, ncol("copies", "copies", null, { bar: true }),
      ncol("shared", "shared"), ncol("multi-thr.", "multi_threaded"), ncol("persistent", "persistent"), ncol("bytes", "bytes", fBytes), ncol("time", "copy_ns", fNs),
      { t: "% scope", v: (r) => (scopeTotal.get(r.scope) ? num(r, "copy_ns") / scopeTotal.get(r.scope) * 100 : NaN), f: fPct, num: true, tip: "copy time as a share of the scope's time" },
      col("scope", "scope"), pcol("where", "where")], { what: "copies", rowClass: (r) => (num(r, "shared") + num(r, "multi_threaded") > 0 ? "" : null) })));
  if (arr(d, "allocations").length) addTab("allocs", "Allocations", arr(d, "allocations").length, () => panel(null, "Objects allocated by compiled Lean code, per function and scope.",
    table(arr(d, "allocations"), [col("function", "function", null, { wrap: true }), col("scope", "scope"), pcol("where", "where"), ncol("allocations", "allocs", null, { bar: true }), ncol("bytes", "bytes", fBytes),
      { t: "mean size", v: (r) => (num(r, "allocs") ? num(r, "bytes") / num(r, "allocs") : 0), f: fBytes, num: true }], { what: "allocations" })));
  if (arr(d, "reuse").length) addTab("reuse", "Reuse failures", arr(d, "reuse").length, () => panel(null, "Constructor cells that could not be updated in place because they were not exclusive (with --counters).",
    table(arr(d, "reuse"), [col("function", "function", null, { wrap: true }), pcol("where", "where"), ncol("checks", "checks"), ncol("failures", "failures", null, { bar: true }),
      { t: "% failed", v: (r) => (num(r, "checks") ? num(r, "failures") / num(r, "checks") * 100 : 0), f: fPct, num: true },
      ncol("shared", "shared"), ncol("multi-thr.", "multi_threaded"), ncol("persistent", "persistent"), ncol("fields", "fields"), ncol("sites", "sites")], { what: "functions" })));
  if (arr(d, "closures").length) addTab("closures", "Closures", arr(d, "closures").length, () => panel(null, "Closure applications per call site and target (with --counters): exact, partial (more arguments still needed) and over-applied.",
    table(arr(d, "closures"), [col("call site", "function", null, { wrap: true }), pcol("where", "where"), col("target", "target", null, { wrap: true }), pcol("target where", "target_where"),
      ncol("applications", "applications", null, { bar: true }), ncol("exact", "exact"), ncol("partial", "partial"), ncol("over", "over")], { what: "closures" })));
  if (arr(d, "tasks").length) addTab("tasks", "Tasks", arr(d, "tasks").length, () => panel(null, "Tasks by the scope that spawned them: run time, and time queued before a worker picked them up.",
    table(arr(d, "tasks"), [col("spawned by", "spawned_by"), ncol("tasks", "tasks"), ncol("run (wall)", "run_total_ns", fNs), ncol("run (sum)", "run_sum_ns", fNs, { bar: true }),
      { t: "mean run", v: (r) => (num(r, "tasks") ? num(r, "run_sum_ns") / num(r, "tasks") : 0), f: fNs, num: true }, ncol("queued", "wait_ns", fNs), ncol("max queued", "wait_max_ns", fNs)], { what: "tasks" })));
  if (arr(d, "waits").length) addTab("waits", "Waits", arr(d, "waits").length, () => panel(null, "Blocking waits on tasks (Task.get, IO.wait), per function.",
    table(arr(d, "waits"), [col("function", "function", null, { wrap: true }), col("scope", "scope"), pcol("where", "where"), ncol("waits", "waits"), ncol("blocked", "blocked_ns", fNs, { bar: true }),
      { t: "mean", v: (r) => (num(r, "waits") ? num(r, "blocked_ns") / num(r, "waits") : 0), f: fNs, num: true }], { what: "waits" })));
  if (d.frees) addTab("frees", "Frees", arr(d.frees, "sites").length, () => {
    const fc = (first, k, pk) => [col(first, k, null, { wrap: true }), pk === "where" ? col("scope", "scope") : null, pcol("where", pk), ncol("cascades", "cascades"), ncol("objects", "objects"),
      ncol("time", "free_ns", fNs, { bar: true }), ncol("p50", "p50_ns", fNs), ncol("p99", "p99_ns", fNs), ncol("max pause", "max_ns", fNs), ncol("atomic decr.", "mt_decrements")].filter(Boolean);
    return [panel("Freeing cascades per call site", "Time spent freeing objects whose last reference was dropped, and atomic decrements of objects shared between threads (with --frees).",
      table(arr(d.frees, "sites"), fc("function", "function", "where"), { what: "sites" })),
      panel("Per scope", null, table(arr(d.frees, "scopes"), fc("scope", "scope", "pos"), { what: "scopes" }))];
  });
  if (d.memory && arr(d.memory, "scopes").length) addTab("memory", "Memory", arr(d.memory, "scopes").length, () => panel(null,
    "Lean's committed memory sampled at scope exits (at most once per ms): the peak while a scope ran and the largest rise over one call.",
    table(arr(d.memory, "scopes"), [col("scope", "name"), pcol("where", "pos"), ncol("sampled calls", "sampled_calls"), ncol("peak", "peak_commit", fBytes), ncol("max rise", "max_rise", fBytes, { bar: true })], { what: "scopes" })));
}

if (elab) {
  const d = elab.data, f = fAmt(elab), all = sum(arr(d, "scopes"), (s) => num(s, "total_ns"));
  addTab("compile", "Compile time", arr(d, "scopes").length, () => panel(null,
    "Compile cost per line: elaboration, kernel, compiler and linters" + (hbUnit(elab) ? ", in heartbeats (exact)." : ", in wall time (noisy; --heartbeats is exact)."),
    table(arr(d, "scopes"), [col("declaration", "name", (v) => h("span", { class: "mono" }, v), { wrap: true }), pcol("where", "pos"), ncol("total", "total_ns", f, { bar: true }),
      { t: "%", v: (r) => (all ? num(r, "total_ns") / all * 100 : 0), f: fPct, num: true }, ncol("elaboration", "elab_ns", f), ncol("kernel", "kernel_ns", f), ncol("compiler", "compile_ns", f), ncol("linters", "lint_ns", f),
      { t: "costliest operation", v: (r) => (arr(r, "top")[0] ? arr(r, "top")[0].op : ""), f: (v, r) => (v ? h("span", { class: "mono", title: arr(r, "top").map((o) => f(num(o, "amount")) + "  " + o.op).join("\n") }, f(num(arr(r, "top")[0], "amount")) + "  " + v) : ""), wrap: true }],
    { what: "lines" })));
  if (arr(d, "ranges").length) addTab("ranges", "Source ranges", arr(d, "ranges").length, () => panel(null,
    "Terms and tactics by exact source range (line:column), from leanprof's in-process driver; inclusive: a term or tactic contains those elaborated inside it." +
      (d.compact ? " Compact profile: commands, terms and tactics only, not the operations inside them." : ""),
    table(arr(d, "ranges"), [col("source", "text", (v) => h("span", { class: "mono" }, v), { wrap: true }), col("kind", "kind"),
      col("syntax", "syntax", (v) => (v || "").split(".").pop()), pcol("line", "pos"), col("range", "range", (v) => rangeCols(v || "")),
      ncol("total", "amount", f, { bar: true }), ncol("times", "count")], { what: "ranges" })));
  if (arr(d, "repeated").length) addTab("repeated", "Repeated work", arr(d, "repeated").length, () => panel(null, "The same operation (up to metavariable numbers) done more than once: candidates for caching, a local instance or a lemma.",
    table(arr(d, "repeated"), [col("class", "class"), col("operation", "op", (v) => h("span", { class: "mono" }, v), { wrap: true }), ncol("times", "count"), ncol("total", "total", f, { bar: true }), pcol("first at", "first_at")], { what: "operations" })));
  let kinds = arr(d, "kinds"), approx = false;
  if (!kinds.length) {
    const m = new Map();
    for (const s of arr(d, "scopes")) for (const o of arr(s, "top")) { const c = (/^\[([^\]]+)\]/.exec(o.op) || [])[1]; if (c) m.set(c, (m.get(c) || 0) + num(o, "amount")); }
    kinds = [...m].map(([cls, total]) => ({ class: cls, total }));
    approx = true;
  }
  const kall = sum(kinds, (k) => num(k, "total"));
  if (kinds.length) addTab("kinds", "Operation kinds", kinds.length, () => panel(null,
    approx ? "This elab.json predates per-kind totals: these sum each line's costliest operations (inclusive), so they overlap. Rerun `leanprof elab` for exact self cost per kind."
      : "Self cost per kind of operation (trace class): where compile time went.",
    table(kinds, [col("operation kind", "class", (v) => h("span", { class: "mono" }, v)), ncol("cost", "total", f, { bar: true }), { t: "%", v: (r) => (kall ? num(r, "total") / kall * 100 : 0), f: fPct, num: true }], { what: "kinds" })));
}

if (meas) addTab("measure", "Measure", null, () => {
  const d = meas.data, t = d.time_ns || {};
  const kv = (rows) => h("div", { class: "kv" }, rows.flatMap(([k, v]) => [h("div", null, k), h("div", null, v)]));
  return [panel("Summary", "From " + meas.path + " (leanprof measure).", kv([["command", (d.command || []).join(" ")], ["runs", d.runs], ["time", "median " + fNs(num(t, "median")) + ", min " + fNs(num(t, "min")) + ", max " + fNs(num(t, "max"))],
      ["copies", fN(num(d, "copies_total")) + (d.copies_stable === false ? " (differ between runs)" : "")], ["output", ((d.output || {}).hash || "") + " (" + ((d.output || {}).source || "") + ")" + ((d.output || {}).stable === false ? ", differs between runs" : "")],
      ["exit code", num(d, "exit_code")], ["compile heartbeats", d.heartbeats_total == null ? "not measured" : fHB(num(d, "heartbeats_total"))]])),
    arr(d, "copies").length ? panel("Copies per site", null, table(arr(d, "copies"), [col("site", "key", null, { wrap: true }), ncol("copies", "copies", null, { bar: true })])) : null,
    arr(d, "calls").length ? panel("Calls per scope", null, table(arr(d, "calls"), [col("scope", "key", null, { wrap: true }), ncol("calls", "calls", null, { bar: true })])) : null,
    arr(d, "heartbeats").length ? panel("Heartbeats per declaration", null, table(arr(d, "heartbeats"), [col("declaration", "key", null, { wrap: true }), ncol("heartbeats", "heartbeats", fHB, { bar: true })])) : null];
});

const filesWithSource = Object.keys(sources);
if (filesWithSource.length) addTab("source", "Source", filesWithSource.length, () => {
  const order = filesWithSource.map((f) => [f, [...hints.keys()].filter((p) => splitPos(p)[0] === f).length]).sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
  return panel(null, "The lines each report mentions, read from the project when this page was made, with the hints `#leanprof` shows in the editor. Hover a hint for details.",
    order.map(([f, n]) => h("div", { class: "file", id: "file-" + f }, h("h3", null, f, h("span", { class: "note" }, "  " + n + " hinted lines")),
      srcLines(f, Object.keys(sources[f]).map(Number).sort((a, b) => a - b), null))));
});

if (pairs.length || (meas && measB)) addTab("diff", "Comparison", totalRegressions || null, () => {
  const out = [];
  const st = (s) => h("span", { class: "tag " + (s === "regression" ? "bad" : s === "faster" || s === "fewer" ? "good" : s === "more" ? "warn" : "muted") }, s);
  const rowCls = (r) => (r.st === "regression" ? "bad" : r.st === "faster" || r.st === "fewer" ? "good" : null);
  const rank = { regression: 0, new: 1, gone: 2, faster: 3, fewer: 3, more: 1, ok: 4, same: 5 };
  for (const p of pairs) {
    const f = p.r.exact ? fHB : fNs, r = p.r;
    const metrics = [];
    if (p.name === "run") {
      const total = (m) => [...m.values()].reduce((a, x) => a + (typeof x === "number" ? x : x.c), 0);
      const bc = total(copyMap(p.b)), nc = total(copyMap(p.n));
      metrics.push(["copies", fN(bc), fN(nc), change(bc, nc, fN), r.copies.some((c) => c.st === "regression") ? "fail" : "pass"]);
      if (arr(p.b.data, "allocations").length + arr(p.n.data, "allocations").length) {
        const ba = total(allocMap(p.b)), na = total(allocMap(p.n));
        metrics.push(["allocations", fN(ba), fN(na), change(ba, na, fN), na > ba ? "worse" : "pass"]);
      }
      const bcl = total(scopeMap(p.b)), ncl = total(scopeMap(p.n));
      metrics.push(["calls", fN(bcl), fN(ncl), change(bcl, ncl, fN), r.scopes.some((s) => s.bc !== s.nc && s.st !== "new" && s.st !== "gone") ? "fail" : "pass"]);
      metrics.push(["time (wall, noisy)", fNs(num(p.b.data, "wall_ns")), fNs(num(p.n.data, "wall_ns")), change(num(p.b.data, "wall_ns"), num(p.n.data, "wall_ns"), fNs), "not checked"]);
    } else {
      const tb = sum(r.scopes, (s) => s.b), tn = sum(r.scopes, (s) => s.n);
      metrics.push([r.exact ? "compile heartbeats" : "compile time (noisy)", f(tb), f(tn), change(tb, tn, f), r.scopes.some((s) => s.st === "regression") ? "fail" : "pass"]);
    }
    const tag = (c) => h("span", { class: "tag " + (c === "fail" ? "bad" : c === "pass" ? "good" : c === "worse" ? "warn" : "muted") }, c);
    out.push(panel((p.name === "run" ? "Run" : "Compile") + ": " + p.b.path + " → " + p.n.path,
      "Regressions as `leanprof compare` counts them: " + (p.name === "run" ? "more copies of shared values at a site, changed call counts, " : "") +
      (r.exact ? "a declaration's heartbeats up by more than 1% and 1,000" : "a " + (p.name === "run" ? "scope" : "declaration") + " slower by more than " + D.threshold + "% and " + D.min_ms + " ms") + ".",
      h("div", { class: "tw" }, h("table", null, h("thead", null, h("tr", null, ["metric", "base", "new", "change", "check"].map((t, i) => h("th", { class: i && i < 4 ? "num" : "" }, t)))),
        h("tbody", null, metrics.map((m) => h("tr", null, h("td", null, m[0]), h("td", { class: "num" }, m[1]), h("td", { class: "num" }, m[2]), h("td", { class: "num" }, m[3]), h("td", null, tag(m[4])))))))));
    out.push(panel(p.name === "run" ? "Scopes" : "Declarations", null, table(r.scopes, [{ t: "status", v: (x) => rank[x.st], f: (v, x) => [st(x.st), x.why ? " " + x.why : ""] },
      col(p.name === "run" ? "scope" : "declaration", "k", null, { wrap: true }), { t: "base", v: (x) => x.b, f, num: true }, { t: "new", v: (x) => x.n, f, num: true },
      { t: "change", v: (x) => x.n - x.b, f: (v, x) => change(x.b, x.n, f), num: true }, { t: "%", v: (x) => x.pct, f: (v) => (v > 0 ? "+" : "") + fPct(v), num: true },
      ...(p.name === "run" ? [{ t: "calls base", v: (x) => x.bc, f: fN, num: true }, { t: "calls new", v: (x) => x.nc, f: fN, num: true }] : [])],
      { sort: 0, asc: true, rowClass: rowCls, what: "scopes" })));
    if (r.copies.length) out.push(panel("Copies of shared values", "Any increase at a site is a regression.", table(r.copies, [{ t: "status", v: (x) => rank[x.st], f: (v, x) => st(x.st) },
      col("site", "k", null, { wrap: true }), { t: "base", v: (x) => x.b, f: fN, num: true }, { t: "new", v: (x) => x.n, f: fN, num: true }, { t: "change", v: (x) => x.n - x.b, f: (v, x) => change(x.b, x.n, fN), num: true }],
      { sort: 0, asc: true, rowClass: rowCls, what: "sites" })));
    if (r.allocs.length) out.push(panel("Allocations that changed", "Shown for information; `report-md --fail-on allocs` checks the total.", table(r.allocs, [{ t: "", v: (x) => rank[x.st], f: (v, x) => st(x.st) },
      col("site", "k", null, { wrap: true }), { t: "base", v: (x) => x.b, f: fN, num: true }, { t: "new", v: (x) => x.n, f: fN, num: true }, { t: "change", v: (x) => x.n - x.b, f: (v, x) => change(x.b, x.n, fN), num: true }],
      { sort: 4, what: "sites" })));
  }
  if (meas && measB) {
    const b = measB.data, n = meas.data;
    const rows = [["median time", num(b.time_ns, "median"), num(n.time_ns, "median"), fNs], ["min time", num(b.time_ns, "min"), num(n.time_ns, "min"), fNs], ["max time", num(b.time_ns, "max"), num(n.time_ns, "max"), fNs],
      ["copies", num(b, "copies_total"), num(n, "copies_total"), fN]];
    if (b.heartbeats_total != null && n.heartbeats_total != null) rows.push(["compile heartbeats", num(b, "heartbeats_total"), num(n, "heartbeats_total"), fHB]);
    const same = (b.output || {}).hash === (n.output || {}).hash && num(b, "exit_code") === num(n, "exit_code");
    out.push(panel("Measure: " + measB.path + " → " + meas.path, "`leanprof judge` decides KEEP or DISCARD from these: output and exit code must match, copies and heartbeats must not grow, and time counts only when the runs do not overlap.",
      measWorse.length ? h("p", null, h("span", { class: "tag bad" }, "worse"), " " + measWorse.join(", ")) : null,
      h("div", { class: "tw" }, h("table", null, h("thead", null, h("tr", null, ["", "base", "new", "change"].map((t, i) => h("th", { class: i ? "num" : "" }, t)))), h("tbody", null, rows.map(([k, x, y, f]) => h("tr", null, h("td", null, k), h("td", { class: "num" }, f(x)), h("td", { class: "num" }, f(y)), h("td", { class: "num" }, change(x, y, f)))),
        h("tr", null, h("td", null, "output and exit code"), h("td", { colspan: 3 }, same ? h("span", { class: "tag good" }, "same") : h("span", { class: "tag bad" }, "changed"))))))));
  }
  return out;
});

// ---------- page ----------
const app = document.getElementById("app");
const tip = h("div", { id: "tip" });
const themeBtn = h("button", { title: "colour theme" });
function getTheme() {
  const q = /[?&]theme=(light|dark|auto)/.exec(location.search);
  if (q) return q[1];
  try { return localStorage.getItem("leanprof-theme") || "auto"; } catch (e) { return "auto"; }
}
function setTheme(t) {
  if (t === "auto") document.documentElement.removeAttribute("data-theme"); else document.documentElement.setAttribute("data-theme", t);
  themeBtn.textContent = "theme: " + t;
  try { localStorage.setItem("leanprof-theme", t); } catch (e) { /* storage unavailable */ }
  flames.forEach((f) => f.isConnected && f._draw());
}
themeBtn.addEventListener("click", () => setTheme({ auto: "light", light: "dark", dark: "auto" }[getTheme()]));
matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => flames.forEach((f) => f.isConnected && f._draw()));

const kindsText = D.reports.map((r) => (r.role === "base" ? "base " : r.role === "new" ? "new " : "") + r.kind + " " + r.path).join(" · ");
const head = h("header", { class: "top" }, h("div", { class: "grow" }, h("h1", null, D.title), h("div", { class: "sub" }, kindsText)), themeBtn);
const tiles = h("div", { class: "tiles" }, run ? runTiles() : [], elab ? elabTiles() : [], meas ? measTiles() : []);
const verdict = pairs.length ? h("div", { class: "verdict " + (totalRegressions ? "bad" : "good") },
  totalRegressions ? totalRegressions + " regression" + (totalRegressions === 1 ? "" : "s") + " against the base (see Comparison)" : "No regressions against the base") : null;
const nav = h("nav", { class: "tabs" });
const mainEl = h("main");
const rendered = {};
function selectTab(id) {
  const t = tabs.find((x) => x.id === id) || tabs[0];
  if (!t) return;
  for (const b of nav.children) b.classList.toggle("on", b.dataset.id === t.id);
  if (!rendered[t.id]) rendered[t.id] = h("div", null, t.render());
  mainEl.replaceChildren(rendered[t.id]);
  flames.forEach((f) => f.isConnected && f._draw());
  if (location.hash.slice(1) !== t.id) history.replaceState(null, "", "#" + t.id);
}
for (const t of tabs) nav.append(h("button", { "data-id": t.id, onclick: () => selectTab(t.id) }, t.label, t.count != null ? h("span", { class: "n" }, fN(t.count)) : null));
const foot = h("footer", null, "Made by leanprof html (github.com/unbalancedparentheses/leanprof) from " + D.reports.length + " report" + (D.reports.length === 1 ? "" : "s") +
  " in " + D.project + ". Source lines were read when the page was made and may have changed since.");
app.replaceChildren(head, verdict || "", tiles, nav, mainEl, foot, drawer, tip);
if (!tabs.length) mainEl.append(h("div", { class: "empty" }, "These reports contain nothing to show."));
setTheme(getTheme());
selectTab(location.hash.slice(1) || (pairs.length && totalRegressions ? "diff" : tabs[0] && tabs[0].id));
addEventListener("keydown", (e) => { if (e.key === "Escape") drawer.style.display = "none"; });
})();
