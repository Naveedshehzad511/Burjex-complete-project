import json, time, datetime as dt, sys, os
sys.path.insert(0, r"C:\burjex\btrader\bridges\mt5-manager-python")
from mt5_bridge import Mt5Source, load_config, clean_symbol

cfg = load_config(r"C:\burjex\btrader\bridges\mt5-manager-python\config.json")
src = Mt5Source(cfg)
src.connect()
names = src.list_symbols()
xau = [n for n in names if "XAU" in n.upper()]
print("XAU_SYMBOLS=", ",".join(xau[:80]))
suffix = cfg.get("SymbolSuffixStrip","")
print("SUFFIX_STRIP=", repr(suffix))
# seed preference simulation
from mt5_bridge import _seed_symbol_set
seed = _seed_symbol_set(cfg, names, suffix)
xau_seed = [s for s in seed if clean_symbol(s, suffix).upper()=="XAUUSD"]
print("SEED_XAU=", xau_seed)

now = int(time.time())
frm = now - 20*60
for sym in sorted(set(xau_seed + [n for n in xau if n.upper() in ("XAUUSD","XAUUSD.S","XAUUSD.ECN") or n.upper().startswith("XAUUSD.")])):
    try:
        bars = src.m1_bars(sym, frm, now)
    except Exception as e:
        print(f"MT5 {sym} ERR {e}")
        continue
    print(f"=== MT5 ChartRequest {sym} count={len(bars)} ===")
    for t,o,h,l,c,v in bars[-8:]:
        iso = dt.datetime.fromtimestamp(int(t), tz=dt.timezone.utc).strftime("%Y-%m-%d %H:%M")
        print(f"{iso} o={o} h={h} l={l} c={c}")
src.disconnect()
