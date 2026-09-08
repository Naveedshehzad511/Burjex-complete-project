//+------------------------------------------------------------------+
//|  BTraderFeed.mq5                                                  |
//|  Pushes an MT5 client terminal's bid/ask to the B-Trader ingest  |
//|  endpoint over HTTPS. NO Manager API — runs on ANY MT5 terminal   |
//|  logged into ANY broker account (a demo is fine for feed-only).   |
//|                                                                    |
//|  This is a drop-in producer for the same /ingest endpoint the     |
//|  Python manager bridge uses, so it needs zero B-Trader changes.   |
//|                                                                    |
//|  ── Terminal setup (REQUIRED) ─────────────────────────────────   |
//|   Tools > Options > Expert Advisors > tick "Allow WebRequest for   |
//|   listed URL" and add the InpFeedHost value (e.g.                  |
//|   https://feed.example.com). Attach the EA to ONE chart;   |
//|   it streams ALL configured symbols via a timer (not just the      |
//|   chart symbol). Keep the terminal running + logged in on a VPS.   |
//|                                                                    |
//|  ── B-Trader setup ───────────────────────────────────────────    |
//|   Admin > Liquidity > add a provider (transport MT5_PUSH); copy    |
//|   its feed token into InpFeedToken. Set the symbol suffix/mapping   |
//|   on that provider so this broker's names (e.g. EURUSD.x) map to    |
//|   your canonical symbols — leave InpStripSuffix empty and let       |
//|   B-Trader do the mapping (recommended).                            |
//+------------------------------------------------------------------+
#property copyright "B-Trader"
#property version   "1.0"
#property strict

input string InpFeedHost    = "https://feed.example.com"; // must be allow-listed in the terminal
input string InpFeedToken   = "";     // Liquidity Provider feed token (or legacy MT5_FEED_TOKEN)
input string InpSymbols     = "";     // comma list e.g. "EURUSD,XAUUSD"; empty = all Market Watch symbols
input int    InpPollMs      = 100;    // how often to sample ticks (ms)
input int    InpFlushMs     = 300;    // how often to POST the accumulated batch (ms)
input int    InpMaxBatch    = 200;    // flush early once this many ticks are queued
input string InpStripSuffix = "";     // optional LOCAL suffix strip (usually leave empty; map in B-Trader)
input bool   InpVerbose     = false;  // log each POST result

string g_symbols[];
double g_lastBid[];
double g_lastAsk[];
long   g_lastMsc[];
string g_url;
string g_batch;
int    g_batchCount;
uint   g_lastFlush;

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpFeedToken) == 0)
   {
      Print("BTraderFeed: InpFeedToken is empty — paste the provider feed token from B-Trader admin.");
      return(INIT_FAILED);
   }
   g_url = InpFeedHost + "/ingest";

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

   g_batch = "";
   g_batchCount = 0;
   g_lastFlush = GetTickCount();
   EventSetMillisecondTimer(InpPollMs);
   PrintFormat("BTraderFeed: streaming %d symbol(s) -> %s", ArraySize(g_symbols), g_url);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

//+------------------------------------------------------------------+
//|  Poll every symbol on a timer (OnTick only fires for the chart    |
//|  symbol, so we can't rely on it for a multi-symbol feed).         |
//+------------------------------------------------------------------+
void OnTimer()
{
   int n = ArraySize(g_symbols);
   for(int i = 0; i < n; i++)
   {
      MqlTick t;
      if(!SymbolInfoTick(g_symbols[i], t)) continue;
      if(t.bid <= 0 || t.ask <= 0) continue;
      // Only queue when the quote actually changed.
      if(t.bid == g_lastBid[i] && t.ask == g_lastAsk[i] && (long)t.time_msc == g_lastMsc[i]) continue;
      g_lastBid[i] = t.bid;
      g_lastAsk[i] = t.ask;
      g_lastMsc[i] = (long)t.time_msc;

      int    digits = (int)SymbolInfoInteger(g_symbols[i], SYMBOL_DIGITS);
      string name   = MapName(g_symbols[i]);
      string obj    = "{\"symbol\":\"" + name + "\",\"bid\":" + DoubleToString(t.bid, digits) +
                      ",\"ask\":" + DoubleToString(t.ask, digits) +
                      ",\"ts\":" + IntegerToString((long)t.time_msc) + "}";
      if(g_batchCount > 0) g_batch += ",";
      g_batch += obj;
      g_batchCount++;

      if(g_batchCount >= InpMaxBatch) Flush();
   }
   if(g_batchCount > 0 && (GetTickCount() - g_lastFlush) >= (uint)InpFlushMs) Flush();
}

//+------------------------------------------------------------------+
//|  POST the queued batch to /ingest.                                |
//+------------------------------------------------------------------+
void Flush()
{
   if(g_batchCount == 0) return;
   string body = "{\"ticks\":[" + g_batch + "]}";
   g_batch = "";
   g_batchCount = 0;
   g_lastFlush = GetTickCount();

   uchar  data[];
   uchar  result[];
   string rheaders;
   StringToCharArray(body, data, 0, StringLen(body), CP_UTF8); // ASCII JSON -> exact bytes, no null
   string headers = "X-Feed-Token: " + InpFeedToken + "\r\nContent-Type: application/json\r\n";

   ResetLastError();
   int code = WebRequest("POST", g_url, headers, 5000, data, result, rheaders);
   if(code == -1)
   {
      int err = GetLastError();
      if(err == 4014 || err == 4060) // 4014 = MQL5 URL-not-allowed; 4060 = legacy MQL4 code
         Print("BTraderFeed: WebRequest blocked (err=", err, ") — add ", InpFeedHost,
               " under Tools>Options>Expert Advisors>\"Allow WebRequest for listed URL\" (tick the box).");
      else
         PrintFormat("BTraderFeed: WebRequest failed err=%d", err);
   }
   else if(code != 200)
   {
      PrintFormat("BTraderFeed: ingest HTTP %d %s", code, CharArrayToString(result));
   }
   else if(InpVerbose)
   {
      Print("BTraderFeed: posted -> ", CharArrayToString(result));
   }
}

//+------------------------------------------------------------------+
void AddSymbol(string s)
{
   int i = ArraySize(g_symbols);
   ArrayResize(g_symbols, i + 1);
   ArrayResize(g_lastBid, i + 1);
   ArrayResize(g_lastAsk, i + 1);
   ArrayResize(g_lastMsc, i + 1);
   g_symbols[i] = s;
   g_lastBid[i] = 0;
   g_lastAsk[i] = 0;
   g_lastMsc[i] = 0;
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
