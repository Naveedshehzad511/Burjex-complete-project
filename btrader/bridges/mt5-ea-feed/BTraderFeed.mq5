//+------------------------------------------------------------------+
//|  BTraderFeed.mq5  v7                                              |
//|  Pushes an MT5 client terminal's bid/ask to the B-Trader ingest  |
//|  endpoint over HTTPS, and repairs chart holes from MT5 history.  |
//|  NO Manager API — runs on ANY MT5 terminal logged into a broker. |
//|                                                                    |
//|  ── Live prices: never late ──────────────────────────────────    |
//|   Every poll sends the ticks that arrived since the last poll.    |
//|   If more are waiting than fit, the OLDER ones are skipped; a     |
//|   tick older than InpMaxTickAgeMs is never sent; and a failed     |
//|   POST is dropped, not retried. There is no queue, so a slow     |
//|   network costs a short pause, never a backlog.                   |
//|   (v6 queued every tick on disk and replayed them oldest-first;   |
//|   one slow spell grew a 33-minute backlog that market-data had to |
//|   reject as stale, and the chart lost an hour of candles.)        |
//|                                                                    |
//|  ── Candle repair ────────────────────────────────────────────    |
//|   On start: the last InpBackfillHours of CLOSED M1…D1 bars. Then  |
//|   every InpRepairEverySec: the last InpRepairWindowMin. Sent to   |
//|   /ingest/candles with "authoritative": MT5's own bar replaces    |
//|   the stored one for every CLOSED bucket, so a hole is filled and |
//|   a bar the server only saw part of (feed down mid-bar) is made   |
//|   whole — the chart matches MT5. The forming bar stays live.      |
//|   Only for a terminal that is ALSO this feed's tick source.       |
//|                                                                    |
//|  ── Terminal setup (REQUIRED) ─────────────────────────────────   |
//|   Tools > Options > Expert Advisors > tick "Allow WebRequest for   |
//|   listed URL" and add the InpFeedHost value. Attach the EA to ONE  |
//|   chart; it streams ALL configured symbols via a timer. Run only   |
//|   ONE copy of this EA (and no other bridge) against a feed host.   |
//+------------------------------------------------------------------+
#property copyright "B-Trader"
#property version   "7.0"
#property strict

input string InpFeedHost          = "https://feed.burjexprime.net"; // must be allow-listed in the terminal
input string InpFeedToken         = "";     // Liquidity Provider feed token (or legacy MT5_FEED_TOKEN)
input string InpSymbols           = "";     // comma list e.g. "EURUSD,XAUUSD"; empty = all Market Watch symbols
input int    InpPollMs            = 100;    // how often to sample and send ticks (ms)
input int    InpMaxTickAgeMs      = 5000;   // never send a tick older than this (market-data would reject it)
input int    InpMaxTicksPerSymbol = 50;     // per poll; when more are waiting only the newest are sent
input int    InpHttpTimeoutMs     = 3000;   // per POST
input bool   InpRepairCandles     = true;   // send MT5 history so chart holes are filled
input int    InpBackfillHours     = 72;     // history sent once on start
input int    InpRepairEverySec    = 300;    // how often the recent window is re-sent
input int    InpRepairWindowMin   = 360;    // recent window re-sent each time (restart the EA for older holes)
input string InpStripSuffix       = "";     // optional LOCAL suffix strip (usually leave empty; map in B-Trader)
input bool   InpVerbose           = false;  // log each POST result

// Timeframes market-data stores (W1 / MN are rolled up from D1 there).
const string          TF_CODE[]   = {"1m", "5m", "15m", "30m", "1h", "4h", "1d"};
const ENUM_TIMEFRAMES TF_PERIOD[] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30, PERIOD_H1, PERIOD_H4, PERIOD_D1};
const int             TF_SEC[]    = {60, 300, 900, 1800, 3600, 14400, 86400};

string g_symbols[];
long   g_cursor[];      // time_msc of the newest tick already handled, per symbol
string g_tickUrl;
string g_candleUrl;
int    g_offsetSec;     // broker server time minus UTC

// Candle repair jobs (symbol index, timeframe index, bar count, attempts).
int    g_jobSym[];
int    g_jobTf[];
int    g_jobBars[];
int    g_jobTry[];
int    g_jobHead;
ulong  g_lastRepair;

// Stats, logged once a minute.
long   g_ticksSent, g_ticksTooOld, g_backlogSkips, g_postsOk, g_postsFailed, g_barsSent;
ulong  g_lastStats, g_lastErrorLog;

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpFeedToken) == 0)
   {
      Print("BTraderFeed: InpFeedToken is empty — paste the provider feed token from B-Trader admin.");
      return(INIT_FAILED);
   }
   string host = InpFeedHost;
   while(StringLen(host) > 0 && StringSubstr(host, StringLen(host) - 1) == "/")
      host = StringSubstr(host, 0, StringLen(host) - 1);
   g_tickUrl   = host + "/ingest";
   g_candleUrl = host + "/ingest/candles";

   // Build the symbol set.
   if(StringLen(InpSymbols) > 0)
   {
      string parts[];
      int n = StringSplit(InpSymbols, ',', parts);
      for(int i = 0; i < n; i++)
      {
         string s = parts[i];
         StringTrimLeft(s);
         StringTrimRight(s);
         if(StringLen(s) == 0) continue;
         SymbolSelect(s, true);   // ensure it streams into Market Watch
         AddSymbol(s);
      }
   }
   else
   {
      int total = SymbolsTotal(true); // Market Watch only
      for(int i = 0; i < total; i++) AddSymbol(SymbolName(i, true));
   }

   if(ArraySize(g_symbols) == 0)
   {
      Print("BTraderFeed: no symbols to stream (add symbols to Market Watch or set InpSymbols).");
      return(INIT_FAILED);
   }

   g_offsetSec = ServerOffsetSec();
   g_jobHead = 0;
   g_lastRepair = GetTickCount64();
   g_lastStats = GetTickCount64();
   if(InpRepairCandles) EnqueueRepair(InpBackfillHours * 60);

   EventSetMillisecondTimer(MathMax(50, InpPollMs));
   PrintFormat("BTraderFeed v7: streaming %d symbol(s) -> %s (server UTC offset %ds, candle repair %s)",
               ArraySize(g_symbols), g_tickUrl, g_offsetSec, InpRepairCandles ? "on" : "off");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   PrintFormat("BTraderFeed v7 stopped (reason %d).", reason);
}

//+------------------------------------------------------------------+
//|  One timer pass: send fresh ticks, then at most one repair job.   |
//|  (OnTick only fires for the chart symbol, so it is not used.)     |
//+------------------------------------------------------------------+
void OnTimer()
{
   SendTicks();

   if(InpRepairCandles)
   {
      ulong now = GetTickCount64();
      if(JobsLeft() == 0 && now - g_lastRepair >= (ulong)InpRepairEverySec * 1000)
      {
         g_offsetSec = ServerOffsetSec();
         EnqueueRepair(InpRepairWindowMin);
         g_lastRepair = now;
      }
      RunRepairJob();
   }

   if(GetTickCount64() - g_lastStats >= 60000)
   {
      PrintFormat("BTraderFeed v7: last 60s ticks_sent=%I64d too_old=%I64d backlog_skips=%I64d posts_ok=%I64d posts_failed=%I64d repair_bars=%I64d",
                  g_ticksSent, g_ticksTooOld, g_backlogSkips, g_postsOk, g_postsFailed, g_barsSent);
      g_ticksSent = g_ticksTooOld = g_backlogSkips = g_postsOk = g_postsFailed = g_barsSent = 0;
      g_lastStats = GetTickCount64();
   }
}

//+------------------------------------------------------------------+
//|  Ticks since the last poll, newest kept, stale ones never sent.   |
//+------------------------------------------------------------------+
void SendTicks()
{
   long   nowMs = (long)TimeTradeServer() * 1000;
   string batch = "";
   int    count = 0;
   int    n = ArraySize(g_symbols);

   for(int i = 0; i < n; i++)
   {
      if(g_cursor[i] <= 0)
      {
         // Start from "now": history is not replayed as live ticks.
         MqlTick cur;
         if(SymbolInfoTick(g_symbols[i], cur)) g_cursor[i] = (long)cur.time_msc;
         continue;
      }

      MqlTick ticks[];
      int got = CopyTicks(g_symbols[i], ticks, COPY_TICKS_INFO, (ulong)g_cursor[i] + 1, InpMaxTicksPerSymbol);
      if(got == InpMaxTicksPerSymbol)
      {
         // More are waiting than one poll may send: take the newest instead, skip the backlog.
         int newest = CopyTicks(g_symbols[i], ticks, COPY_TICKS_INFO, 0, InpMaxTicksPerSymbol);
         if(newest > 0) got = newest;
         g_backlogSkips++;
      }
      if(got <= 0) continue;

      int    digits = (int)SymbolInfoInteger(g_symbols[i], SYMBOL_DIGITS);
      string name   = MapName(g_symbols[i]);
      for(int k = 0; k < got; k++)
      {
         long msc = (long)ticks[k].time_msc;
         if(msc <= g_cursor[i]) continue;
         g_cursor[i] = msc;
         if(ticks[k].bid <= 0 || ticks[k].ask <= 0) continue;
         if(nowMs - msc > InpMaxTickAgeMs) { g_ticksTooOld++; continue; }

         string obj = "{\"symbol\":\"" + name + "\",\"bid\":" + DoubleToString(ticks[k].bid, digits) +
                      ",\"ask\":" + DoubleToString(ticks[k].ask, digits) +
                      ",\"ts\":" + IntegerToString(msc - (long)g_offsetSec * 1000) + "}";
         if(count > 0) batch += ",";
         batch += obj;
         count++;
      }
   }

   if(count == 0) return;
   // A failed batch is dropped on purpose: by the next attempt these prices are old.
   if(Post(g_tickUrl, "{\"ticks\":[" + batch + "]}")) g_ticksSent += count;
}

//+------------------------------------------------------------------+
//|  Candle repair: closed MT5 bars, MT5 is the reference.            |
//+------------------------------------------------------------------+
void EnqueueRepair(const int minutes)
{
   int n = ArraySize(g_symbols);
   for(int i = 0; i < n; i++)
      for(int tf = 0; tf < ArraySize(TF_SEC); tf++)
      {
         int bars = (int)MathMin(6000, MathMax(3, (long)minutes * 60 / TF_SEC[tf] + 1));
         AddJob(i, tf, bars, 0);
      }
}

void AddJob(const int sym, const int tf, const int bars, const int attempts)
{
   int j = ArraySize(g_jobSym);
   ArrayResize(g_jobSym, j + 1);
   ArrayResize(g_jobTf, j + 1);
   ArrayResize(g_jobBars, j + 1);
   ArrayResize(g_jobTry, j + 1);
   g_jobSym[j] = sym;
   g_jobTf[j] = tf;
   g_jobBars[j] = bars;
   g_jobTry[j] = attempts;
}

int JobsLeft()
{
   return ArraySize(g_jobSym) - g_jobHead;
}

void RunRepairJob()
{
   if(JobsLeft() <= 0)
   {
      if(g_jobHead > 0)
      {
         ArrayResize(g_jobSym, 0);
         ArrayResize(g_jobTf, 0);
         ArrayResize(g_jobBars, 0);
         ArrayResize(g_jobTry, 0);
         g_jobHead = 0;
      }
      return;
   }
   int sym = g_jobSym[g_jobHead], tf = g_jobTf[g_jobHead], bars = g_jobBars[g_jobHead], tries = g_jobTry[g_jobHead];
   g_jobHead++;

   MqlRates rates[];
   // Start at 1: the forming bar belongs to market-data's live engine.
   int got = CopyRates(g_symbols[sym], TF_PERIOD[tf], 1, bars, rates);
   if(got <= 0)
   {
      // History may still be downloading; try again later in this pass.
      if(tries < 3) AddJob(sym, tf, bars, tries + 1);
      return;
   }

   int    digits = (int)SymbolInfoInteger(g_symbols[sym], SYMBOL_DIGITS);
   string body = "";
   int    count = 0;
   for(int k = 0; k < got; k++)
   {
      long t = (long)rates[k].time - g_offsetSec;
      // A bar that does not sit on market-data's UTC grid (H4 / D1 of a non-UTC broker) is skipped.
      if(t % TF_SEC[tf] != 0) continue;
      if(count > 0) body += ",";
      body += "{\"t\":" + IntegerToString(t) +
              ",\"o\":" + DoubleToString(rates[k].open, digits) +
              ",\"h\":" + DoubleToString(rates[k].high, digits) +
              ",\"l\":" + DoubleToString(rates[k].low, digits) +
              ",\"c\":" + DoubleToString(rates[k].close, digits) +
              ",\"v\":" + IntegerToString((long)rates[k].tick_volume) + "}";
      count++;
   }
   if(count == 0) return;
   if(Post(g_candleUrl, "{\"symbol\":\"" + MapName(g_symbols[sym]) + "\",\"tf\":\"" + TF_CODE[tf] +
                        "\",\"authoritative\":true,\"bars\":[" + body + "]}"))
      g_barsSent += count;
}

//+------------------------------------------------------------------+
//|  POST JSON; errors are logged at most every 30 s.                 |
//+------------------------------------------------------------------+
bool Post(const string url, const string body)
{
   char   data[];
   char   result[];
   string rheaders;
   StringToCharArray(body, data, 0, StringLen(body), CP_UTF8); // ASCII JSON -> exact bytes, no null
   string headers = "X-Feed-Token: " + InpFeedToken + "\r\nContent-Type: application/json\r\n";

   ResetLastError();
   int code = WebRequest("POST", url, headers, InpHttpTimeoutMs, data, result, rheaders);
   if(code == 200)
   {
      g_postsOk++;
      if(InpVerbose) Print("BTraderFeed: posted -> ", CharArrayToString(result));
      return true;
   }

   g_postsFailed++;
   int err = GetLastError();
   if(GetTickCount64() - g_lastErrorLog >= 30000)
   {
      g_lastErrorLog = GetTickCount64();
      if(code == -1 && (err == 4014 || err == 4060)) // 4014 = MQL5 URL-not-allowed; 4060 = legacy MQL4 code
         Print("BTraderFeed: WebRequest blocked (err=", err, ") — add ", InpFeedHost,
               " under Tools>Options>Expert Advisors>\"Allow WebRequest for listed URL\" (tick the box).");
      else if(code == -1)
         PrintFormat("BTraderFeed: WebRequest failed err=%d (%s)", err, url);
      else
         PrintFormat("BTraderFeed: HTTP %d from %s: %s", code, url, CharArrayToString(result));
   }
   return false;
}

//+------------------------------------------------------------------+
//|  Broker server time minus UTC, rounded to 30 minutes.             |
//+------------------------------------------------------------------+
int ServerOffsetSec()
{
   long diff = (long)(TimeTradeServer() - TimeGMT());
   return (int)(MathRound(diff / 1800.0) * 1800);
}

//+------------------------------------------------------------------+
void AddSymbol(string s)
{
   int i = ArraySize(g_symbols);
   ArrayResize(g_symbols, i + 1);
   ArrayResize(g_cursor, i + 1);
   g_symbols[i] = s;
   g_cursor[i] = 0;
}

//+------------------------------------------------------------------+
//|  Optional local suffix strip. Prefer leaving this empty and       |
//|  mapping on the B-Trader provider (handles suffix + rename).      |
//+------------------------------------------------------------------+
string MapName(string s)
{
   if(StringLen(InpStripSuffix) > 0)
   {
      int sl = StringLen(InpStripSuffix);
      int l  = StringLen(s);
      if(l > sl && StringSubstr(s, l - sl) == InpStripSuffix) return StringSubstr(s, 0, l - sl);
   }
   return s;
}
//+------------------------------------------------------------------+
