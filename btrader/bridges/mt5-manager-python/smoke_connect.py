import json,sys
import MT5Manager
cfg=json.load(open("config.json",encoding="utf-8"))
print("FeedUrl="+cfg.get("FeedUrl",""))
print("Mt5Server="+str(cfg.get("Mt5Server")))
print("Mt5Login="+str(cfg.get("Mt5Login")))
m=MT5Manager.ManagerAPI()
pump=MT5Manager.ManagerAPI.EnPumpModes.PUMP_MODE_FULL
ok=m.Connect(cfg["Mt5Server"], int(cfg["Mt5Login"]), cfg["Mt5Password"], pump, 30000)
print("CONNECT_OK="+str(bool(ok)))
if not ok:
    print("LAST_ERROR="+str(MT5Manager.LastError()))
    sys.exit(3)
print("CONNECTED")
try: m.Disconnect()
except Exception: pass