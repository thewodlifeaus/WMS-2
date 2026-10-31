# Intelligent pick routing

Code: SQL `wms_route_key()` + `wms_create_pick_session()` (migration 003) and the matching TypeScript in `packages/routing/src/route.ts` (unit tested).

## Bin coordinates

Every bin has a code `ROW-SHELF-BIN`, eg `A-02-04`:

| Part | Meaning | Sort value |
|---|---|---|
| `A` | Row (aisle). `A`..`Z`, then `AA`, `AB` | `aisle_rows.sequence` (walking order, so rows can be renumbered without relabelling) |
| `02` | Shelf = bay along the row, `01` at the dispatch end | `shelves.sequence` |
| `04` | Bin = slot on that shelf (level / position) | digits of the bin code |
| `L`/`R` (optional) | Which side of the aisle the shelf is on | used by zigzag |

Letters are converted spreadsheet-style (`A`=1 ... `Z`=26, `AA`=27) so `AA` never sorts before `B`. The database stores numeric `row_seq`, `shelf_seq`, `bin_seq` on each bin (kept up to date by a trigger), so routing never parses strings at run time.

## Strategies

```
SNAKE (S-shape, default)         ZIGZAG (both sides of aisle)      LINEAR (one-way aisles)
 Row A  01 -> 02 -> 03 -> 04       A-01L A-01R  A-02R A-02L ...     Row A  01 -> 04
 Row B  04 <- 03 <- 02 <- 01       cross the aisle once per bay     Row B  01 -> 04  (walk back first)
 Row C  01 -> 02 -> 03 -> 04
```

## The rule that prevents backtracking

Direction alternates by the **order rows are visited in this session**, not by physical row number.

Picks in rows A, C, D (none in B):

| Approach | A | C | D | Result |
|---|---|---|---|---|
| Physical parity (A=1 odd, C=3 odd, D=4 even) | forward | forward | backward | Picker exits A at the far end, then must walk to the front of C: **backtrack** |
| Visit order (A=1st, C=2nd, D=3rd) | forward | backward | forward | Continuous S path, **no backtrack** |

## Pseudo-code

```text
FUNCTION build_route(stops, strategy):
    # stops = list of {bin, sku, qty} produced by stock allocation

    # 1. consolidate: batch / cluster orders that need the same SKU from the same bin
    merged = GROUP stops BY (bin, sku) SUM qty

    # 2. resolve coordinates (from DB sort keys, or parse "A-02-04")
    FOR each s IN merged:
        s.zone  = bin.zone_sequence            # zones walked first (SQL version: number rows in zone order)
        s.row   = bin.row_seq                  # A=1, B=2 ... AA=27
        s.shelf = bin.shelf_seq
        s.side  = bin.shelf_side               # 'L', 'R' or null
        s.bin   = bin.bin_seq

    # 3. visit index = dense rank of the rows that actually have picks
    rows_used = SORTED DISTINCT (s.zone, s.row) FOR s IN merged
    FOR each s IN merged:
        s.visit = position of (s.zone, s.row) in rows_used   # 1, 2, 3 ...

    # 4. direction per row
        forward = (strategy == LINEAR) OR (s.visit is odd)
        shelf_key = forward ? s.shelf : (9999 - s.shelf)

    # 5. aisle side
        IF s.side is null:        side_key = 0
        ELIF strategy == ZIGZAG:  side_key = 0 if (s.shelf is odd) == (s.side == 'L') else 1
        ELSE:                     side_key = 0 if s.side == 'L' else 1

    # 6. one sortable number per stop
        s.key = zone * 10^12 + row * 10^8 + shelf_key * 10^4 + side_key * 10^3 + min(s.bin, 999)

    # 7. order and number the walk
    SORT merged BY key, then sku
    ASSIGN sequence = 1..n
    RETURN merged
```

## How stock is chosen before routing (allocation)

For each order line, in order priority then oldest first:

1. Only bins in the session's warehouse (and zone, for zone picking) with free stock (`on_hand - allocated > 0`).
2. Pick bins before backfill/overstock bins.
3. Prefer a single bin that covers the whole quantity (fewer stops).
4. Then nearest in walking order.
5. Reserve the units (`qty_allocated`) with a row lock, so two tablets can never be sent for the same unit.

Lines that cannot be filled come back as `shortages` and those orders go `on_hold` when the session ends.

## Scan-to-pick gate (what the tablet enforces)

```text
LOOP:
    task = wms_get_current_task(session)          # lowest pending sequence only
    IF task.done: show "Cart complete -> pack bench"; STOP
    SHOW big bin code, SKU, image, qty, and which basket(s) to drop into
    (optional) picker scans bin label -> wms_confirm_bin  (wrong bin = red + alarm)
    picker scans product -> wms_pick_scan(task.id, barcode)
        WRONG_ITEM / UNKNOWN_BARCODE / OVER_QTY / NOT_CURRENT_TASK
            -> full-screen red, alarm chirp, stay on this task
        ok -> green flash, show "put in Basket 3 (#564704)", refresh task
    "Can't find it" button -> wms_pick_short(task.id): releases the rest, flags a cycle count, moves on
```

## Hyper picking

`wms_hyper_next_session(cart)` is the "Give me work" button:

1. Candidate orders = `awaiting_pick` orders that can be fully picked now (up to 300, priority then oldest).
2. Seed the cart with the most urgent order.
3. Repeatedly add the order that adds the **fewest new rows** to the walk (ties: priority, then age) until the cart's baskets are full.
4. Create a session with those orders, assign it to the caller and start it immediately.

Supervisors can still push work: create a session with `p_assign_to = <picker>`; tablets subscribe to `pick_sessions` via Supabase Realtime and pop it up.

## Possible later upgrades

- Largest-gap heuristic: for a row with a few picks near the front only, enter and return instead of traversing it.
- Real distances: store x/y on bins and solve a small TSP per cart (only worth it if the floor layout is irregular).
