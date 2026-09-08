# BTraderFeed — MQL5 EA price feed

An alternative to the Python Manager-API bridge: an MQL5 Expert Advisor that runs
on an ordinary **MT5 client terminal** and POSTs bid/ask to B-Trader's `/ingest`
endpoint. No Manager API, no manager login, no IP allow-list on a manager account,
none of the manager-DLL fragility — just a terminal logged into *any* broker
account (a demo is fine for feed-only). It is a drop-in producer for the same
endpoint the Python bridge uses, so **B-Trader needs no changes**.

Use it when the Manager API is unavailable, or to pull a price feed from a broker
you only have a client account with.

## How the pieces fit
```
MT5 client terminal (any broker) ── BTraderFeed.mq5 ──HTTPS POST──► feed.example.com/ingest
                                                                     (mt5-ingest adapter → per-source
                                                                      quote store → markup → clients)
```
The EA sends the broker's raw symbol names (e.g. `EURUSD.x`); B-Trader's per-provider
**symbol mapping** normalises them to your canonical symbols.

## Setup

### 1. Register the source in B-Trader admin
Admin → **Liquidity → Providers → Add**:
- Transport: **MT5_PUSH**
- Copy the generated **feed token**.
- Set **symbol suffix / per-class suffix** (and any explicit maps) so this broker's
  names map to yours — the "unmapped seen" list shows what's actually arriving.

### 2. Allow the URL in the terminal (REQUIRED)
`Tools → Options → Expert Advisors → "Allow WebRequest for listed URL"` and add:
```
https://feed.example.com
```
(Without this, `WebRequest` returns error 4060 and nothing is sent.)

### 3. Install + attach the EA
- Copy `BTraderFeed.mq5` into the terminal's `MQL5\Experts\` folder
  (File → Open Data Folder), then compile it in MetaEditor (F7).
- Add the symbols you want to stream to **Market Watch**.
- Drag the EA onto **one** chart (it streams *all* configured symbols via a timer,
  not just the chart symbol). Enable **Algo Trading**.
- Inputs:
  | Input | Meaning |
  |---|---|
  | `InpFeedToken` | the provider feed token from step 1 (**required**) |
  | `InpSymbols` | comma list e.g. `EURUSD,XAUUSD`; empty = all Market Watch symbols |
  | `InpFeedHost` | `https://feed.example.com` (must match the allow-listed URL) |
  | `InpPollMs` / `InpFlushMs` | sample / POST cadence (defaults 100 / 300 ms) |
  | `InpStripSuffix` | usually leave empty — map on the provider instead |
  | `InpVerbose` | log each POST response |

### 4. Verify
- Terminal **Experts** tab logs `streaming N symbol(s) -> …/ingest`.
- Admin → **Liquidity → Spread Monitor** shows this provider's quotes.

## Operational notes
- Keep the terminal **running + logged in** (host it on a small Windows VPS with
  auto-login; a demo account is fine for a feed-only source).
- The feed is **that broker's prices** (their spread) — B-Trader applies your own
  markup on top. Use best-spread across providers if you run several.
- The EA queues changed ticks and flushes every `InpFlushMs`; lower `InpPollMs`
  for finer granularity, raise `InpFlushMs` to reduce request volume.

---

# BTraderCover — MQL5 EA A-book cover execution

`BTraderCover.mq5` is the execution counterpart: it runs on the MT5 terminal of
your **cover account** and executes B-Trader A-book covers via `OrderSend` — no
Manager API. It covers **both ways automatically**, because the pending queue
returns every MT5 hedge regardless of origin:
- **STP** — automatic 1:1 client A-book cover,
- **Manual** — desk cover from Dealing → Net Hedge,
- **Auto** — the net-hedge sweep.

It also does **partial closes** (Phase 7): a `CLOSE_PENDING` hedge closes only its
`volume` lots of the cover ticket.

Keep this **separate** from the feed EA — the feed is read-only on a demo/any
broker; covers place **real orders** on your funded cover account. They can run on
different brokers (price off one, cover at another).

## Setup

### 1. B-Trader admin
- The cover venue = an **LP provider** (Liquidity → Providers). Put its `code` in
  the EA's `InpProviderCode` to scope covers to it (empty = legacy/unscoped).
- Give that provider an **LP Venue** (Dealing → LP Venues): driver **MT5**, enabled.
- Add a **routing rule** (Dealing → Routing Rules): book **A** → that provider
  (fixed), with the coverage % you want.

### 2. Terminal (on the cover account)
- `Tools → Options → Expert Advisors`: tick **Allow algorithmic trading** and
  **Allow WebRequest for listed URL** → add **`https://api.example.com`**
  (note: `api.`, the bridge host — different from the feed host).
- The logged-in account must have **trade permission**.

### 3. Attach the EA
Compile `BTraderCover.mq5` (F7), drag onto one chart, Algo Trading **green**, and set:
| Input | Meaning |
|---|---|
| `InpBridgeToken` | server `BRIDGE_TOKEN` (X-Bridge-Token) |
| `InpTenantId` | your tenant id (X-BT-Tenant) |
| `InpProviderCode` | the LP provider code to cover for (empty = unscoped) |
| `InpSymbolSuffix` | append to the B-Trader symbol to get THIS broker's name (e.g. `m`) |
| `InpPollMs` | poll cadence (default 1000 ms) |
| `InpDeviation` | max slippage points on cover fills |

### 4. Verify
- Experts log: `BTraderCover: polling …/bridge/hedges/pending …`, then
  `FILLED … #<ticket>` per cover.
- B-Trader admin → Dealing → **A-book Covers**: the hedge flips `PENDING → FILLED`
  with the LP fill price.

## Notes / caveats
- **Symbol names**: the hedge carries the canonical B-Trader name (e.g. `EURUSD`);
  the EA appends `InpSymbolSuffix` to trade the broker's name (`EURUSDm`). The cover
  account must actually offer those symbols.
- **Hedging account** recommended (each cover is its own position; the close
  targets it by ticket).
- **Idempotency**: the EA won't re-`OrderSend` the same hedge id within a session.
  If a fill *report* fails after the order filled (rare), the hedge stays `PENDING`
  and could be re-covered on a later restart — same edge as the manager bridge;
  watch the Experts log for report errors.
- Real money moves here — validate with a **0.01-lot** cover first.
