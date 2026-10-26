// Unit tests of lib.js (no VS Code): reading the difference files and reports
// that `leanprof elab|run --since-last` writes, and running one profile per
// file at a time.   npm run test:unit
"use strict";
const test = require("node:test");
const assert = require("node:assert");
const path = require("path");
const lib = require("../lib");

// as `leanprof elab --heartbeats --since-last` writes it (Leanprof/Delta.lean)
const elabDelta = {
  version: 1, delta: true, kind: "elab", unit: "heartbeats", comparable: true, first: false, errors: 0,
  total: { base: 94280, new: 120300 },
  decls: [
    {
      key: "Foo/Bar.lean t2", name: "theorem t2 (a b : Nat) : a + b = b + a := by simp", pos: "Foo/Bar.lean:5",
      status: "changed", base: 20000, new: 45000, change: 25000, regression: true,
      why: {
        headline: "whnf reduces Foo.f (Foo/Bar.lean:1) +20.00 kHB",
        parts: [{ part: "elaboration", base: 20000, new: 45000 }],
        rows: [{ what: "whnf", label: "whnf reduces", name: "Foo.f", where: "Foo/Bar.lean:1", base: "0.00 kHB, 0×",
          new: "20.00 kHB, 30×", change: "+20.00 kHB", up: true }],
        more: 2,
        notes: ["exact unfold, instance and simp-lemma counts need `leanprof elab --counts` on both commits"],
      },
    },
    { key: "Foo/Bar.lean f", name: "def f", pos: "Foo/Bar.lean:1", status: "changed", base: 9000, new: 4000, change: -5000,
      regression: false },
    { key: "Foo/Bar.lean g", name: "def g", pos: "Foo/Bar.lean:9", status: "changed", base: 9000, new: 11000, change: 2000,
      regression: true },
    { key: "Foo/Bar.lean h", name: "def h", pos: "Foo/Bar.lean:12", status: "new", base: 0, new: 3000, change: 3000,
      regression: false },
    { key: "Foo/Bar.lean old", name: "def old", pos: "", status: "gone", base: 3000, new: 0, change: -3000, regression: false },
    { key: "Other.lean x", name: "def x", pos: "Other.lean:3", status: "changed", base: 1, new: 90000, change: 89999 },
  ],
};

const runDelta = {
  version: 1, delta: true, kind: "run", unit: "ns", comparable: true, first: false,
  copies: [{ key: "build [Array] in build", where: "Foo/Bar.lean:17", base: 1, new: 2001, change: 2000,
    function: "build", kind: "Array", scope: "build" }],
  allocations: [{ key: "build in build", where: "Foo/Bar.lean:17", base: 10, new: 5, change: -5 },
    { key: "other in main", where: "Main.lean:2", base: 1, new: 2, change: 1 }],
  scopes: [],
};

test("compile-time differences land on their declaration's line, worded and colored", () => {
  const items = lib.deltaItems(elabDelta, "Foo/Bar.lean", { redAbove: 10000 });
  assert.deepStrictEqual(items.map((i) => [i.line, i.level, i.text]), [
    [0, "down", "−5.0 kHB since the last save"],
    [4, "red", "+25.0 kHB since the last save"],
    [8, "up", "+2.0 kHB since the last save"],
    [11, "new", "3.0 kHB (new)"],
  ]);
  const hover = items[1].hover;
  assert.match(hover, /\*\*`t2`\*\*: 20\.0 kHB → 45\.0 kHB to compile/);
  assert.match(hover, /top change: whnf reduces Foo\.f/);
  assert.match(hover, /\| \+20\.00 kHB \| whnf reduces \| `Foo\.f` \(Foo\/Bar\.lean:1\) \| 0\.00 kHB, 0× \| 20\.00 kHB, 30× \|/);
  assert.match(hover, /2 more changed/);
  assert.match(hover, /note: exact unfold/);
});

test("other files' declarations and gone ones are not shown", () => {
  const items = lib.deltaItems(elabDelta, "Other.lean");
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].line, 2);
  assert.strictEqual(lib.deltaItems(elabDelta, "Bar.lean").length, 0, "another file of the same name");
});

test("files are matched by their whole path in the project", () => {
  assert.ok(lib.sameFile("./Foo/Bar.lean", "Foo/Bar.lean"));
  assert.ok(!lib.sameFile("pkg/Foo/Bar.lean", "Foo/Bar.lean"));
});

test("the first profile and incomparable reports show nothing", () => {
  assert.deepStrictEqual(lib.deltaItems({ ...elabDelta, first: true }, "Foo/Bar.lean"), []);
  assert.deepStrictEqual(lib.deltaItems({ ...elabDelta, comparable: false }, "Foo/Bar.lean"), []);
  assert.deepStrictEqual(lib.deltaItems(undefined, "Foo/Bar.lean"), []);
  assert.match(lib.deltaSummary({ first: true }), /first profile/);
});

test("copies and allocations on one line are combined, largest first", () => {
  const items = lib.deltaItems(runDelta, "Foo/Bar.lean");
  assert.strictEqual(items.length, 1);
  assert.strictEqual(items[0].line, 16);
  assert.strictEqual(items[0].text, "+2,000 copies · −5 allocations");
  assert.strictEqual(items[0].level, "red");
  assert.match(items[0].hover, /`build \[Array\] in build`: 1 → 2,001 copies/);
});

test("summaries", () => {
  assert.strictEqual(lib.deltaSummary(elabDelta), "6 declarations changed, +26.0 kHB in the file");
  assert.strictEqual(lib.deltaSummary({ ...elabDelta, decls: [] }), "no declaration changed");
  assert.strictEqual(lib.deltaSummary(runDelta), "+2,000 copies, −4 allocations");
  assert.strictEqual(lib.deltaSummary({ ...runDelta, copies: [], allocations: [] }), "no copies or allocations changed");
});

test("the costliest declarations of a file, lines merged at the first", () => {
  const report = {
    unit: "heartbeats",
    files: [{ file: "Foo/Bar.lean", wall_ns: 3.1e8, errors: 0 }],
    scopes: [
      { name: "theorem big : x", key: "Foo/Bar.lean big", pos: "Foo/Bar.lean:10", total_ns: 60000, elab_ns: 60000,
        top: [{ amount: 50000, op: "[Meta.synthInstance] Foo" }] },
      { name: "theorem big : x", key: "Foo/Bar.lean big", pos: "Foo/Bar.lean:14", total_ns: 20000, kernel_ns: 20000 },
      { name: "def small", key: "Foo/Bar.lean small", pos: "Foo/Bar.lean:3", total_ns: 20000, compile_ns: 20000 },
      { name: "def elsewhere", key: "Other.lean e", pos: "Other.lean:3", total_ns: 1e9 },
    ],
  };
  const s = lib.slowest(report, "Foo/Bar.lean", 5);
  assert.strictEqual(s.total, 100000);
  assert.strictEqual(s.wallNs, 3.1e8);
  assert.deepStrictEqual(s.decls.map((d) => [d.name, d.line, d.total, d.share]), [["big", 9, 80000, 0.8], ["small", 2, 20000, 0.2]]);
  assert.deepStrictEqual(s.decls[0].parts, { elab: 60000, kernel: 20000, compiler: 0, linters: 0 });
  assert.strictEqual(s.decls[0].top[0].op, "[Meta.synthInstance] Foo");
  assert.deepStrictEqual(lib.slowest(undefined, "x").decls, []);
});

test("where --since-last keeps its files", () => {
  const r = lib.onSaveReport("/p", "Foo/Bar.lean");
  assert.strictEqual(r, path.join("/p", ".lake", "leanprof", "onsave", "Foo", "Bar.lean.json"));
  assert.strictEqual(lib.deltaOf(r), path.join("/p", ".lake", "leanprof", "onsave", "Foo", "Bar.lean.delta.json"));
  assert.strictEqual(lib.onSaveRunReport("/p", "copybug"), path.join("/p", ".lake", "leanprof", "onsave", "run-copybug.json"));
});

test("formatting", () => {
  assert.strictEqual(lib.groupDigits(1234567), "1,234,567");
  assert.strictEqual(lib.signed(-1500, lib.fmtKHB), "−1.5 kHB");
  assert.strictEqual(lib.fmtNs(2.5e6), "2.5 ms");
  assert.deepStrictEqual(lib.parsePos("A/B.lean:12"), { file: "A/B.lean", line: 12 });
  assert.strictEqual(lib.declName({ key: "F.lean #leanprof #1", name: "#leanprof" }), "#leanprof");
});

const tick = (ms) => new Promise((r) => setTimeout(r, ms));

test("debounce: saves in quick succession profile once, with the last", async () => {
  const d = new lib.Debouncer(30);
  const ran = [];
  const a = d.schedule("f", async () => (ran.push("a"), "a"));
  await tick(5);
  const b = d.schedule("f", async () => (ran.push("b"), "b"));
  assert.strictEqual(await a, undefined, "superseded before it started");
  assert.strictEqual(await b, "b");
  assert.deepStrictEqual(ran, ["b"]);
});

test("a new save stops the profile of the old one", async () => {
  const d = new lib.Debouncer(0);
  let aborted = false;
  const a = d.schedule("f", (signal) => new Promise((resolve) => {
    signal.addEventListener("abort", () => { aborted = true; resolve("stopped"); });
  }));
  await tick(10);
  assert.ok(d.busy("f"));
  const b = d.schedule("f", async () => "b");
  assert.strictEqual(await b, "b");
  assert.strictEqual(await a, undefined, "a stopped job resolves with nothing");
  assert.ok(aborted);
  assert.ok(!d.busy("f"));
});

test("different files profile independently", async () => {
  const d = new lib.Debouncer(0);
  const [x, y] = await Promise.all([d.schedule("x", async () => 1), d.schedule("y", async () => 2)]);
  assert.deepStrictEqual([x, y], [1, 2]);
});

test("a failing job rejects; dispose stops everything", async () => {
  const d = new lib.Debouncer(0);
  await assert.rejects(d.schedule("f", async () => { throw new Error("boom"); }), /boom/);
  let aborted = false;
  const p = d.schedule("g", (signal) => new Promise((resolve) => signal.addEventListener("abort", () => { aborted = true; resolve(1); })));
  await tick(5);
  d.dispose();
  assert.strictEqual(await p, undefined);
  assert.ok(aborted);
});
