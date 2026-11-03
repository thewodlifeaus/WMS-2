/**
 * TWL WMS - Intelligent pick routing
 * ---------------------------------------------------------------------------
 * Turns a bag of pick stops ("go to bin A-02-04, pick 2 x SKU") into a
 * single-direction walk with no backtracking.
 *
 * Mirrors the SQL in supabase/migrations/..._picking.sql (wms_route_key) so the
 * desktop app can preview / simulate routes without hitting the database.
 *
 * Strategies
 *   snake  (S-shape)  row 1 walked forward, row 2 backward, row 3 forward ...
 *   zigzag            snake + alternate which side of the aisle is picked
 *                     first at each bay so you cross the aisle once per bay
 *   linear            every row walked the same way (one-way aisles)
 *
 * The key idea: direction alternates by the order rows are VISITED in this
 * session, not by the physical row number. If rows A, C, D have picks and B
 * has none, A goes forward, C backward, D forward. Using physical parity would
 * make C forward and force the picker to walk the full length of C twice.
 */

export type RouteStrategy = "snake" | "zigzag" | "linear";
export type Side = "L" | "R" | null;

export interface BinCoord {
  row: string; // 'A', 'B', ... 'AA'
  shelf: number; // 2  (from '02')
  bin: number; // 4  (from '04')
  side?: Side;
  rowSeq?: number; // explicit walking order of the row, overrides the letter
  zoneSeq?: number; // zones visited in this order first
}

export interface PickStop {
  binCode: string; // 'A-02-04'
  sku: string;
  qty: number;
  coord?: BinCoord; // optional: supply if you already have it (e.g. from DB sort keys)
}

export interface RoutedStop extends PickStop {
  sequence: number;
  visitIdx: number; // 1 = first row walked
  direction: "forward" | "backward";
  key: bigint;
}

const CODE_RE = /^\s*([A-Za-z]+)\s*-\s*(\d+)\s*-\s*(\d+)\s*([LR])?\s*$/;

/** 'A' -> 1, 'Z' -> 26, 'AA' -> 27 (spreadsheet-style, so AA sorts after Z) */
export function rowLetterToNumber(row: string): number {
  return row
    .toUpperCase()
    .split("")
    .reduce((n, ch) => n * 26 + (ch.charCodeAt(0) - 64), 0);
}

/** Parse 'A-02-04', 'aa-10-3', 'B-03-01L'. Throws on anything else. */
export function parseBinCode(code: string): BinCoord {
  const m = CODE_RE.exec(code);
  if (!m) throw new Error(`Bad bin code "${code}" (expected ROW-SHELF-BIN, e.g. A-02-04)`);
  return {
    row: m[1].toUpperCase(),
    shelf: parseInt(m[2], 10),
    bin: parseInt(m[3], 10),
    side: (m[4]?.toUpperCase() as Side) ?? null,
  };
}

/** Same formula as SQL wms_route_key() */
export function routeKey(strategy: RouteStrategy, visitIdx: number, c: BinCoord): bigint {
  const rowSeq = c.rowSeq ?? rowLetterToNumber(c.row);
  const zone = c.zoneSeq ?? 0;
  const forward = strategy === "linear" || visitIdx % 2 === 1;
  const shelfPart = forward ? c.shelf : 9999 - c.shelf;
  let sidePart = 0;
  if (c.side) {
    if (strategy === "zigzag") sidePart = (c.shelf % 2 === 1) === (c.side === "L") ? 0 : 1;
    else sidePart = c.side === "L" ? 0 : 1;
  }
  return (
    BigInt(zone) * 10n ** 12n +
    BigInt(rowSeq) * 100_000_000n +
    BigInt(shelfPart) * 10_000n +
    BigInt(sidePart) * 1_000n +
    BigInt(Math.min(c.bin, 999))
  );
}

/**
 * Main entry point. Returns stops in walking order, numbered 1..n.
 * Stops for the same bin + SKU are merged (batch / cluster consolidation).
 */
export function routePickStops(stops: PickStop[], strategy: RouteStrategy = "snake"): RoutedStop[] {
  // 1. parse + merge duplicates
  const merged = new Map<string, PickStop & { coord: BinCoord }>();
  for (const s of stops) {
    const coord = s.coord ?? parseBinCode(s.binCode);
    const k = `${s.binCode}|${s.sku}`;
    const prev = merged.get(k);
    if (prev) prev.qty += s.qty;
    else merged.set(k, { ...s, coord });
  }
  const list = [...merged.values()];

  // 2. visit index per (zone,row): dense rank over rows that actually have picks
  const rowId = (c: BinCoord) => `${c.zoneSeq ?? 0}|${c.rowSeq ?? rowLetterToNumber(c.row)}`;
  const rowsInOrder = [...new Set(list.map((s) => rowId(s.coord)))].sort((a, b) => {
    const [za, ra] = a.split("|").map(Number);
    const [zb, rb] = b.split("|").map(Number);
    return za - zb || ra - rb;
  });
  const visitIdxOf = new Map(rowsInOrder.map((r, i) => [r, i + 1]));

  // 3. key + sort
  const keyed = list.map((s) => {
    const visitIdx = visitIdxOf.get(rowId(s.coord))!;
    return {
      ...s,
      visitIdx,
      direction: (strategy === "linear" || visitIdx % 2 === 1 ? "forward" : "backward") as RoutedStop["direction"],
      key: routeKey(strategy, visitIdx, s.coord),
    };
  });
  keyed.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : a.sku.localeCompare(b.sku)));

  // 4. number them
  return keyed.map(({ coord: _c, ...s }, i) => ({ ...s, sequence: i + 1 }));
}

/**
 * Hyper-picking helper: greedily choose up to `maxOrders` orders that share
 * rows, so one cart visits as few rows as possible. Same logic as the SQL
 * function wms_hyper_next_session().
 */
export interface OrderCandidate {
  id: string;
  priority: number; // lower = more urgent
  orderedAt: number; // epoch ms
  rows: string[]; // rows its items live in
}

export function clusterOrders(cands: OrderCandidate[], maxOrders: number): { chosen: string[]; rows: string[] } {
  const pool = [...cands].sort((a, b) => a.priority - b.priority || a.orderedAt - b.orderedAt);
  const chosen: OrderCandidate[] = [];
  const rows = new Set<string>();
  while (chosen.length < maxOrders && pool.length) {
    let bestIdx = 0;
    if (chosen.length > 0) {
      let bestNew = Infinity;
      pool.forEach((c, i) => {
        const added = c.rows.filter((r) => !rows.has(r)).length;
        if (added < bestNew) {
          bestNew = added;
          bestIdx = i; // pool is already priority-sorted, so first wins ties
        }
      });
    }
    const [pick] = pool.splice(bestIdx, 1);
    chosen.push(pick);
    pick.rows.forEach((r) => rows.add(r));
  }
  return { chosen: chosen.map((c) => c.id), rows: [...rows].sort() };
}
