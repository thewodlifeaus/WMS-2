# TWL WMS

Warehouse Management System for TWL HQ, modelled on SkuVault: SKU-to-bin inventory, scan-to-pick on tablets, scan-to-pack with ShipStation labels.

| Doc | What's in it |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | The big picture, data model diagram, picking methods, reports, decisions to make, build phases |
| [docs/PICK_ROUTING.md](docs/PICK_ROUTING.md) | Routing algorithm (snake / zigzag / linear) and pseudo-code |
| [docs/SHIPSTATION_PAYLOADS.md](docs/SHIPSTATION_PAYLOADS.md) | Every request/response from pack bench to printed label |

## What's in this repo

```
supabase/
  migrations/      Database: tables, rules and functions (already applied to the WMS.github Supabase project)
  functions/       Edge functions: ShipStation order sync, Cin7 PO sync, pack-and-ship (label + print)
  tests/           smoke_test.sql: end-to-end test that rolls itself back
packages/routing/  The routing algorithm in TypeScript, with tests
apps/              (next) tablet app and desktop app
```

## Status

- [x] Database schema + business functions live in Supabase project **WMS.github**
- [x] Smoke test passes (receive, move, backfill, cluster pick with wrong-scan alarm, pack, label hook, hyper pick, wave, short pick)
- [x] Routing module + 8 unit tests
- [x] Edge functions written (not deployed yet: need API keys)
- [ ] Tablet app
- [ ] Desktop app

## Beginner guide: running things yourself

You only need these if you want to run the tests on your Mac. Open the **Terminal** app and paste one line at a time.

**1. Get the code onto your Mac** (one time)
```bash
cd ~/Documents
gh repo clone thewodlifeaus/WMS-2
cd WMS-2
```

**2. Run the routing tests** (needs Node 22 or newer: check with `node --version`)
```bash
cd packages/routing
npm test
```
You should see `# pass 8` and `# fail 0`.

**3. Run the database smoke test** (safe: it undoes itself)
Open Supabase, go to project **WMS.github**, then **SQL Editor**, then **New query**. Paste the contents of `supabase/tests/smoke_test.sql` and click **Run**. You should see `SMOKE TEST PASSED` in the messages.

**4. Get the latest changes later**
```bash
cd ~/Documents/WMS-2
git pull
```

## Deploying the edge functions (when ready)

1. Install the Supabase CLI: `brew install supabase/tap/supabase`
2. Log in: `supabase login`
3. Link this folder: `supabase link --project-ref nklbnykqftzkbqbuammg`
4. Add secrets (values from ShipStation, PrintNode and Cin7 settings pages):
   ```bash
   supabase secrets set SHIPSTATION_API_KEY=xxx PRINTNODE_API_KEY=xxx CIN7_ACCOUNT_ID=xxx CIN7_APP_KEY=xxx TEST_LABELS=true
   ```
5. Deploy: `supabase functions deploy pack-and-ship sync-shipstation-orders sync-cin7-pos`

Keep `TEST_LABELS=true` until a full test pack has been done. Never commit API keys to this repo.
