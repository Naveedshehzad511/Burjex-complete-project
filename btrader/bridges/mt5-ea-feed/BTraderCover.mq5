//+------------------------------------------------------------------+
//|  BTraderCover.mq5                                                 |
//|  Executes B-Trader A-book covers on THIS MT5 terminal's account   |
//|  — no Manager API. Polls /bridge/hedges/pending, OrderSends the   |
//|  opens, partial-closes on CLOSE_PENDING, and reports fills back.  |
//|                                                                    |
//|  Covers BOTH ways automatically — the pending queue returns every  |
//|  MT5 hedge regardless of how it was raised:                        |
//|    • STP   — automatic 1:1 client A-book cover (CLIENT_COVER)       |
//|    • Manual — desk cover from Dealing (BROKER_MANUAL)              |
//|    • Auto  — net-hedge sweep (BROKER_AUTO)                         |
//|                                                                    |
//|  ── Terminal setup (REQUIRED) ─────────────────────────────────    |
//|   Tools>Options>Expert Advisors:                                   |
//|     • tick "Allow algorithmic trading"                             |
//|     • tick "Allow WebRequest for listed URL" and add               |
//|         https://api.example.com                            |
//|   Attach to ONE chart, Algo Trading button GREEN. The logged-in    |
//|   account IS your cover account (needs trade permission).          |
//|                                                                    |
//|  ── B-Trader setup ───────────────────────────────────────────    |
//|   This cover venue = the LP provider whose `code` you put in       |
//|   InpProviderCode (scopes /pending to its hedges; empty = legacy   |
//|   unscoped). In admin: give that provider an LP Venue (driver MT5, |
//|   enabled) and a routing rule "book A -> this provider". Covers     |
//|   are ASYNC: the client fills instantly; this EA covers the LP leg.|
//+------------------------------------------------------------------+
#property copyright "B-Trader"
#property version   "1.0"
#property strict

#include <Trade\Trade.mqh>

input string InpApiBase      = "https://api.example.com/v1"; // must be allow-listed (host)
input string InpBridgeToken  = "";     // BRIDGE_TOKEN (X-Bridge-Token)
input string InpTenantId     = "";     // BtTenantId (X-BT-Tenant)
input string InpProviderCode = "";     // LP provider code to scope covers to (empty = legacy/unscoped)
input string InpSymbolSuffix = "";     // append to B-Trader symbol to get THIS broker's name (e.g. "m")
input int    InpPollMs       = 1000;   // how often to poll for pending covers (ms)
input int    InpDeviation    = 30;     // max slippage (points) on cover fills
input int    InpMagic        = 990100; // magic number stamped on cover trades
input bool   InpVerbose      = true;   // log each cover action

CTrade   g_trade;
string   g_pendingUrl;
string   g_headers;
string   g_doneIds[];   // opens already OrderSent this session (avoid double cover)

//+------------------------------------------------------------------+
int OnInit()
{
   if(StringLen(InpBridgeToken) == 0 || StringLen(InpTenantId) == 0)
   {
      Print("BTraderCover: set InpBridgeToken (BRIDGE_TOKEN) and InpTenantId (BtTenantId).");
      return(INIT_FAILED);
   }
   string q = (StringLen(InpProviderCode) > 0) ? ("?provider=" + InpProviderCode) : "";
   g_pendingUrl = InpApiBase + "/bridge/hedges/pending" + q;
   g_headers = "X-Bridge-Token: " + InpBridgeToken + "\r\nX-BT-Tenant: " + InpTenantId +
               "\r\nContent-Type: application/json\r\n";
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpDeviation);
   EventSetMillisecondTimer(InpPollMs);
   PrintFormat("BTraderCover: polling %s (suffix '%s')", g_pendingUrl, InpSymbolSuffix);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }

//+------------------------------------------------------------------+
void OnTimer()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return; // Algo Trading off — do nothing until enabled

   string resp; int code;
   if(!Http("GET", g_pendingUrl, "", resp, code)) return;
   if(code != 200) { if(InpVerbose) Print("BTraderCover: pending HTTP ", code, " ", resp); return; }

   // ── OPENS (STP + manual + auto) ─────────────────────────────────────────
   string arr = ArrOf(resp, "opens");
   int pos = 0; string obj;
   while(NextObj(arr, pos, obj))
   {
      string id = JStr(obj, "id");
      if(id == "" || IsDone(id)) continue;
      string sym  = JStr(obj, "symbolName") + InpSymbolSuffix;
      string side = JStr(obj, "side");
      double vol  = JNum(obj, "volume");
      if(vol <= 0) continue;

      SymbolSelect(sym, true);
      g_trade.SetTypeFillingBySymbol(sym);
      bool ok = (side == "BUY") ? g_trade.Buy(vol, sym) : g_trade.Sell(vol, sym);
      if(ok && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         MarkDone(id); // never OrderSend this hedge twice in one session
         double price  = g_trade.ResultPrice();
         ulong  ticket = g_trade.ResultOrder();
         ReportFill(id, price, ticket);
         if(InpVerbose) PrintFormat("BTraderCover: FILLED %s %s %.2f @ %s #%I64u", sym, side, vol, DoubleToString(price, 8), ticket);
      }
      else
      {
         string why = g_trade.ResultRetcodeDescription();
         ReportReject(id, why);
         PrintFormat("BTraderCover: REJECT %s %s %.2f -> %s", sym, side, vol, why);
      }
   }

   // ── CLOSES (proportional partial close of a cover) ──────────────────────
   arr = ArrOf(resp, "closes");
   pos = 0;
   while(NextObj(arr, pos, obj))
   {
      string id  = JStr(obj, "id");
      string ext = JStr(obj, "externalRef");
      double vol = JNum(obj, "volume");
      if(id == "") continue;
      ulong ticket = (ulong)StringToInteger(ext);
      if(ext == "" || !PositionSelectByTicket(ticket))
      {
         ReportClosed(id, 0); // position already gone — clear the CLOSE_PENDING
         continue;
      }
      double pvol     = PositionGetDouble(POSITION_VOLUME);
      double closeVol = (vol <= 0 || vol >= pvol) ? pvol : vol;
      bool ok = (closeVol >= pvol) ? g_trade.PositionClose(ticket) : g_trade.PositionClosePartial(ticket, closeVol);
      if(ok && g_trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         ReportClosed(id, g_trade.ResultPrice());
         if(InpVerbose) PrintFormat("BTraderCover: CLOSED #%I64u %.2f @ %s", ticket, closeVol, DoubleToString(g_trade.ResultPrice(), 8));
      }
      else PrintFormat("BTraderCover: close failed #%I64u -> %s", ticket, g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//|  Report helpers                                                   |
//+------------------------------------------------------------------+
void ReportFill(const string id, const double price, const ulong ticket)
{
   string body = "{\"fillPrice\":" + DoubleToString(price, 8) + ",\"externalRef\":\"" + IntegerToString((long)ticket) + "\"}";
   string resp; int code;
   Http("POST", InpApiBase + "/bridge/hedges/" + id + "/fill", body, resp, code);
}
void ReportReject(const string id, const string reason)
{
   string r = reason; StringReplace(r, "\"", "'");
   string body = "{\"reason\":\"" + r + "\"}";
   string resp; int code;
   Http("POST", InpApiBase + "/bridge/hedges/" + id + "/reject", body, resp, code);
}
void ReportClosed(const string id, const double price)
{
   string body = "{\"closePrice\":" + DoubleToString(price, 8) + "}";
   string resp; int code;
   Http("POST", InpApiBase + "/bridge/hedges/" + id + "/closed", body, resp, code);
}

//+------------------------------------------------------------------+
//|  HTTP + JSON helpers                                              |
//+------------------------------------------------------------------+
bool Http(const string method, const string url, const string body, string &resp, int &code)
{
   uchar data[]; uchar result[]; string rh;
   if(StringLen(body) > 0) StringToCharArray(body, data, 0, StringLen(body), CP_UTF8);
   ResetLastError();
   code = WebRequest(method, url, g_headers, 5000, data, result, rh);
   if(code == -1)
   {
      int err = GetLastError();
      if(err == 4014 || err == 4060)
         Print("BTraderCover: WebRequest blocked (err=", err, ") — add ", InpApiBase,
               " host under Tools>Options>Expert Advisors>\"Allow WebRequest for listed URL\".");
      else PrintFormat("BTraderCover: WebRequest failed err=%d", err);
      return(false);
   }
   resp = CharArrayToString(result);
   return(true);
}

// Extract the content between "key":[ ... ] (balanced brackets).
string ArrOf(const string body, const string key)
{
   int i = StringFind(body, "\"" + key + "\"");
   if(i < 0) return "";
   i = StringFind(body, "[", i);
   if(i < 0) return "";
   int start = i + 1, depth = 1, j = start, n = StringLen(body);
   while(j < n && depth > 0)
   {
      ushort c = StringGetCharacter(body, j);
      if(c == '[') depth++;
      else if(c == ']') depth--;
      j++;
   }
   return StringSubstr(body, start, j - 1 - start);
}

// Next flat {...} object in an array string.
bool NextObj(const string s, int &pos, string &obj)
{
   int n = StringLen(s);
   while(pos < n && StringGetCharacter(s, pos) != '{') pos++;
   if(pos >= n) return false;
   int start = pos, depth = 0;
   while(pos < n)
   {
      ushort c = StringGetCharacter(s, pos);
      if(c == '{') depth++;
      else if(c == '}') { depth--; if(depth == 0) { pos++; obj = StringSubstr(s, start, pos - start); return true; } }
      pos++;
   }
   return false;
}

string JStr(const string obj, const string key)
{
   int i = StringFind(obj, "\"" + key + "\"");
   if(i < 0) return "";
   i = StringFind(obj, ":", i);
   if(i < 0) return "";
   i++;
   while(i < StringLen(obj) && StringGetCharacter(obj, i) == ' ') i++;
   if(i < StringLen(obj) && StringGetCharacter(obj, i) == '"')
   {
      int start = i + 1;
      int end = StringFind(obj, "\"", start);
      if(end < 0) return "";
      return StringSubstr(obj, start, end - start);
   }
   return "";
}

double JNum(const string obj, const string key)
{
   int i = StringFind(obj, "\"" + key + "\"");
   if(i < 0) return 0;
   i = StringFind(obj, ":", i);
   if(i < 0) return 0;
   i++;
   while(i < StringLen(obj) && StringGetCharacter(obj, i) == ' ') i++;
   // Numbers may arrive JSON-quoted ("volume":"0.1") — read the quoted body.
   if(i < StringLen(obj) && StringGetCharacter(obj, i) == '"')
   {
      int qs = i + 1;
      int qe = StringFind(obj, "\"", qs);
      if(qe < 0) return 0;
      return StringToDouble(StringSubstr(obj, qs, qe - qs));
   }
   int start = i, n = StringLen(obj);
   while(i < n)
   {
      ushort c = StringGetCharacter(obj, i);
      if(c == ',' || c == '}') break;
      i++;
   }
   string v = StringSubstr(obj, start, i - start);
   StringTrimLeft(v); StringTrimRight(v);
   if(v == "null" || v == "") return 0;
   return StringToDouble(v);
}

//+------------------------------------------------------------------+
bool IsDone(const string id)
{
   for(int i = 0; i < ArraySize(g_doneIds); i++) if(g_doneIds[i] == id) return true;
   return false;
}
void MarkDone(const string id)
{
   int k = ArraySize(g_doneIds);
   ArrayResize(g_doneIds, k + 1);
   g_doneIds[k] = id;
   if(k > 5000) { ArrayRemove(g_doneIds, 0, 2500); } // keep the set bounded
}
//+------------------------------------------------------------------+
