# MT5 Manager API bridge → B-Trader (Python)

The easy route. Uses MetaQuotes' official **`MT5Manager`** Python package — no
Visual Studio, no DLL wrangling. Connects to your MT5 server as a manager,
streams ticks to `/ingest`, and pushes OHLC history to `/ingest/candles`. Same
contract as the EA, so the B-Trader side is unchanged.

```
MT5 server --Manager API--> mt5_bridge.py --HTTPS--> feed.example.com
   ticks   -> POST /ingest          (batched every TickFlushMs)
   history -> POST /ingest/candles  (M1 aggregated to 1m..1d)
```

## Requirements

- **Windows** (the `MT5Manager` package is Windows-only), Python **3.7–3.12**.
- A **manager login** on your MT5 server with market-data access.
- Your B-Trader **feed token** (the `MT5_FEED_TOKEN` set on the server).

## Setup

```powershell
cd path\to\bridges\mt5-manager-python
pip install -r requirements.txt
```

Edit **config.json**:

| key | value |
|-----|-------|
| `Mt5Server` | server name, e.g. `DemoServer-Trade` (or `host:port`) |
| `Mt5Login` | a **manager** login (e.g. `1111`) |
| `Mt5Password` | that manager's password |
| `FeedUrl` | `https://feed.example.com` |
| `FeedToken` | your `MT5_FEED_TOKEN` |
| `Symbols` | empty = all symbols, or `EURUSD,XAUUSD,GBPUSD` |
| `SymbolSuffixStrip` | e.g. `.r` to map `EURUSD.r` → `EURUSD` |
| `Timeframes` | `1m,5m,15m,30m,1h,4h,1d` |
| `HistoryBars` | M1 bars to seed (1000 ≈ 16h; raise for deeper charts) |

## Run

```powershell
python mt5_bridge.py
```

Expected log:
```
Manager API connected
streaming N symbol(s)
candle history seeded
```
On the B-Trader server, `curl -s https://feed.example.com/health` shows
`received` climbing. Admin **Market Watch**, mobile **Quotes**, and charts go live.

## Run always-on (Windows service)

With [NSSM](https://nssm.cc):
```powershell
nssm install BTraderFeed "C:\Python312\python.exe" "C:\path\mt5_bridge.py"
nssm set BTraderFeed AppDirectory "C:\path"
nssm start BTraderFeed
```
The script auto-reconnects if the manager session drops.

## Notes / verifying the API surface

The `MT5Manager` method names used here (`ManagerAPI.Connect`, `SymbolGetAll`,
`TickLast`, `ChartRequest`, `EnPumpModes.PUMP_MODE_FULL`) follow the official
package. If your installed version names them slightly differently, inspect it
and adjust the small `Mt5Source` class only:

```powershell
python -c "import MT5Manager; help(MT5Manager.ManagerAPI)"
```

All MT5-specific calls are isolated in the `Mt5Source` class — the tick batching,
candle aggregation, HTTP, and reconnect logic don't change.

The bridge needs only **read** access; it never trades. Use a market-data-scoped
manager login where possible.
