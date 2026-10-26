// Drive the project view of a page written by `leanprof html` from a
// compile-time report, in jsdom, and fail on a script error or a level that
// does not render.
//
//   npm install --prefix DIR jsdom@24.1.3
//   NODE_PATH=DIR/node_modules node scripts/check-html-view.js PAGE.html [--module FILE] [--compare]
//
// It opens the page (which must open on the Project tab), goes to the module
// FILE (default: the first module listed), then to its costliest declaration
// and, when there is one, a term or tactic of it; with --compare, every level
// must compare with the base (a base column, or the base in its tiles); with
// --same-ranges (a report compared with itself), every term or tactic of the
// module and of the declaration must be "same" as in the base.
"use strict";
const { JSDOM, VirtualConsole } = require("jsdom");
const fs = require("fs");

const args = process.argv.slice(2);
const page = args[0];
const opt = (k) => { const i = args.indexOf(k); return i > 0 ? args[i + 1] : null; };
const compare = args.includes("--compare");
const sameRanges = args.includes("--same-ranges");
const failures = [];
const vc = new VirtualConsole();
vc.on("jsdomError", (e) => failures.push("script error: " + e.message + (e.detail && e.detail.stack ? "\n" + e.detail.stack : "")));
const dom = new JSDOM(fs.readFileSync(page, "utf8"), {
  runScripts: "dangerously", pretendToBeVisual: true, url: "http://localhost/report.html", virtualConsole: vc,
  beforeParse(w) {
    w.matchMedia = () => ({ matches: false, addEventListener() {} });
    w.HTMLElement.prototype.scrollIntoView = function () {};
  },
});
const w = dom.window, doc = w.document;
const panels = () => [...doc.querySelectorAll("main .panel > h2")].map((x) => x.textContent);
const crumbs = () => (doc.querySelector("main .pv-crumbs") || {}).textContent || "";
function level(name, wantPanel) {
  const ps = panels();
  console.log(name + ": " + crumbs() + "\n  panels: " + ps.join(" | "));
  if (!ps.some((p) => p.startsWith(wantPanel))) failures.push(name + ": no panel " + JSON.stringify(wantPanel));
  const based = [...doc.querySelectorAll("main th")].some((th) => th.textContent.startsWith("base")) ||
    [...doc.querySelectorAll("main .pv-tiles .tile .d")].some((d) => d.textContent.startsWith("base ")) ||
    [...doc.querySelectorAll("main .kv > div")].some((d) => d.textContent === "base");
  if (compare && !based) failures.push(name + ": nothing compared with the base");
  if (sameRanges) {
    const p = [...doc.querySelectorAll("main .panel")].find((x) => /terms and tactics/i.test((x.querySelector("h2") || {}).textContent || ""));
    const tags = p ? [...p.querySelectorAll("tbody .tag")].map((t) => t.textContent) : [];
    console.log("  terms and tactics: " + tags.join(" "));
    if (p && (!tags.length || tags.some((t) => t !== "same"))) failures.push(name + ": a term or tactic compared with itself is not \"same\": " + tags.join(" "));
  }
}
function click(panelStart) {
  const p = [...doc.querySelectorAll("main .panel")].find((x) => { const t = x.querySelector("h2"); return t && t.textContent.startsWith(panelStart); });
  const a = p && p.querySelector("tbody a[href^='#project']");
  if (!a) return false;
  a.dispatchEvent(new w.MouseEvent("click", { bubbles: true, cancelable: true }));
  return true;
}
setTimeout(() => {
  const on = doc.querySelector("nav.tabs button.on");
  if (!on || on.dataset.id !== "project") failures.push("the page does not open on the project view");
  level("project", "Folders and modules");
  const data = JSON.parse(doc.getElementById("leanprof-data").textContent);
  const elab = data.reports.find((r) => r.kind === "elab" && r.role !== "base");
  const files = elab.data.files.slice().sort((a, b) => b.total_ns - a.total_ns);
  const file = opt("--module") || files[0].file;
  w.history.pushState(null, "", "#project~f=" + encodeURIComponent(file));
  w.dispatchEvent(new w.PopStateEvent("popstate"));
  level("module", "Declarations in " + file);
  if (!click("Declarations in")) failures.push("module: no declaration to open");
  else {
    level("declaration", "Source");
    if (click("Terms and tactics")) level("term or tactic", "Source");
  }
  w.history.back();
  for (const f of failures) console.log("error: " + f);
  console.log(failures.length ? "FAIL" : "ok");
  process.exit(failures.length ? 1 : 0);
}, 200);
