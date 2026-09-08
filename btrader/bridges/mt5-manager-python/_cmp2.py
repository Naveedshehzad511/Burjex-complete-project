import json,time,datetime as dt,sys,urllib.request
sys.path.insert(0,r"C:\burjex\btrader\bridges\mt5-manager-python")
from mt5_bridge import Mt5Source,load_config
cfg=load_config(r"C:\burjex\btrader\bridges\mt5-manager-python\config.json")
src=Mt5Source(cfg); src.connect()
now=int(time.time()); frm=now-25*60
for sym in ["XAUUSD","XAUUSD.s"]:
  bars=src.m1_bars(sym,frm,now)
  print("SYM",sym,"N",len(bars))
  for t,o,h,l,c,v in bars[-12:]:
    print(f"{t}|{o}|{h}|{l}|{c}")
# also TickLast
for sym in ["XAUUSD","XAUUSD.s","XAUUSD.m.ME8.1"]:
  t=src.last_tick(sym)
  print("TICK",sym,t)
src.disconnect()
