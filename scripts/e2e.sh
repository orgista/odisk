#!/bin/zsh
# End-to-end run of the real sandboxed Debug app: Health → Speed Test → Details.
# Usage: scripts/e2e.sh [path/to/oDisk.app]   Output: ~/Developer/odisk-build/e2e/{report.json,*.png}
set -u
APP=${1:-$HOME/Developer/odisk-build/DerivedData-deploy-macos/Build/Products/Debug/oDisk.app}
OUT=$HOME/Developer/odisk-build/e2e
BOX=$HOME/Library/Containers/com.orgista.odisk/Data/tmp/e2e
rm -rf "$OUT" && mkdir -p "$OUT"; rm -rf "$BOX"
cat > "$OUT/winid.swift" <<'SW'
import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list where (w["kCGWindowOwnerName"] as? String) == "oDisk" && (w["kCGWindowLayer"] as? Int) == 0 { print(w["kCGWindowNumber"]!); break }
SW
open -n "$APP" --args -ODiskStoreScreenshots ${ODISK_SHOTS:-0} -ODiskE2E YES -ODiskResetOnLaunch YES -showMenuBarExtra NO
STEPS=(1-health 2-benchmark 3-details); [[ ${ODISK_SHOTS:-0} == 1 ]] && STEPS=(1-health 1b-health-external 2-benchmark 3-details)
for step in $STEPS; do
  for i in {1..600}; do [[ -f "$BOX/$step.ready" ]] && break; sleep 0.25; done
  [[ -f "$BOX/$step.ready" ]] || { echo "e2e: timed out waiting for $step"; exit 1; }
  sleep 0.8
  WID=$(swift "$OUT/winid.swift" 2>/dev/null)
  [[ -n "$WID" ]] && screencapture -x -o -l"$WID" "$OUT/$step.png" || echo "e2e: no window for $step"
done
for i in {1..40}; do pgrep -x oDisk >/dev/null || break; sleep 0.25; done
cp "$BOX/report.json" "$OUT/report.json"
python3 - "$OUT/report.json" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); ok=True
d=r.get("drives",[]); print(f"drives: {len(d)}")
for x in d: print(f"  {x['name']} | {x['model']} | {x['connection']} | health={x['health']} temp={x.get('temperatureC')}")
if not d or d[0]["health"] in ("DENIED","loading") or d[0]["health"].startswith("failed"): ok=False; print("FAIL: startup drive health")
b=r.get("benchmark")
if not isinstance(b,list) or len(b)!=4 or any(x["readMBps"]<=0 or x["writeMBps"]<=0 for x in b): ok=False; print("FAIL: benchmark",b)
else:
  for x in b: print(f"  {x['test']:12} read {x['readMBps']:9.1f}  write {x['writeMBps']:9.1f} MB/s")
if r.get("leftoverTestFiles",1)!=0: ok=False; print("FAIL: test file left behind")
print("E2E PASS" if ok else "E2E FAIL"); sys.exit(0 if ok else 1)
PY
