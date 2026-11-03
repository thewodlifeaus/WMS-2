import { test } from "node:test";
import assert from "node:assert/strict";
import { parseBinCode, rowLetterToNumber, routePickStops, clusterOrders } from "../src/route.ts";

const codes = (r: { binCode: string }[]) => r.map((s) => s.binCode);

test("parses bin codes", () => {
  assert.deepEqual(parseBinCode("A-02-04"), { row: "A", shelf: 2, bin: 4, side: null });
  assert.deepEqual(parseBinCode("aa-10-3R"), { row: "AA", shelf: 10, bin: 3, side: "R" });
  assert.throws(() => parseBinCode("A02"));
});

test("AA sorts after Z", () => {
  assert.ok(rowLetterToNumber("AA") > rowLetterToNumber("Z"));
});

test("snake: alternates direction by VISITED row, not physical row", () => {
  // rows A, C, D have picks; B has none
  const r = routePickStops(
    [
      { binCode: "D-01-01", sku: "x", qty: 1 },
      { binCode: "C-01-01", sku: "x", qty: 1 },
      { binCode: "A-05-01", sku: "x", qty: 1 },
      { binCode: "C-09-02", sku: "x", qty: 1 },
      { binCode: "A-01-02", sku: "x", qty: 1 },
      { binCode: "D-07-01", sku: "x", qty: 1 },
    ],
    "snake",
  );
  // A forward (01 -> 05), C backward (09 -> 01), D forward (01 -> 07)
  assert.deepEqual(codes(r), ["A-01-02", "A-05-01", "C-09-02", "C-01-01", "D-01-01", "D-07-01"]);
  assert.equal(r[2].direction, "backward");
});

test("linear: every row forward", () => {
  const r = routePickStops(
    [
      { binCode: "B-09-01", sku: "x", qty: 1 },
      { binCode: "B-01-01", sku: "x", qty: 1 },
      { binCode: "A-03-01", sku: "x", qty: 1 },
    ],
    "linear",
  );
  assert.deepEqual(codes(r), ["A-03-01", "B-01-01", "B-09-01"]);
});

test("zigzag: alternates aisle side per bay", () => {
  const r = routePickStops(
    ["A-01-01L", "A-01-01R", "A-02-01L", "A-02-01R", "A-03-01R", "A-03-01L"].map((c) => ({ binCode: c, sku: "x", qty: 1 })),
    "zigzag",
  );
  assert.deepEqual(codes(r), ["A-01-01L", "A-01-01R", "A-02-01R", "A-02-01L", "A-03-01L", "A-03-01R"]);
});

test("merges duplicate bin+sku stops (batch consolidation)", () => {
  const r = routePickStops([
    { binCode: "A-01-01", sku: "TEE-M", qty: 2 },
    { binCode: "A-01-01", sku: "TEE-M", qty: 3 },
  ]);
  assert.equal(r.length, 1);
  assert.equal(r[0].qty, 5);
  assert.equal(r[0].sequence, 1);
});

test("matches the SQL smoke-test route", () => {
  const r = routePickStops([
    { binCode: "B-03-01", sku: "TEE-M", qty: 3 },
    { binCode: "A-04-02", sku: "TEE-L", qty: 1 },
    { binCode: "A-01-03", sku: "SHO-M", qty: 4 },
  ]);
  assert.deepEqual(codes(r), ["A-01-03", "A-04-02", "B-03-01"]);
});

test("hyper clustering prefers orders sharing rows", () => {
  const t = Date.now();
  const res = clusterOrders(
    [
      { id: "urgent", priority: 1, orderedAt: t, rows: ["A"] },
      { id: "far", priority: 100, orderedAt: t - 9e6, rows: ["F", "G"] },
      { id: "nearA", priority: 100, orderedAt: t, rows: ["A"] },
      { id: "AB", priority: 100, orderedAt: t, rows: ["A", "B"] },
    ],
    3,
  );
  assert.deepEqual(res.chosen, ["urgent", "nearA", "AB"]);
  assert.deepEqual(res.rows, ["A", "B"]);
});
