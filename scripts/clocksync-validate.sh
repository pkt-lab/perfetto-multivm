#!/usr/bin/env bash
# clocksync-validate.sh
# Validate clock synchronization in a multi-machine Perfetto trace
# Requires: python3 + perfetto pip package (pip3 install perfetto)
#
# Usage: bash clocksync-validate.sh <trace.pftrace>

set -euo pipefail

TRACE="${1:-}"
if [[ -z "$TRACE" || ! -f "$TRACE" ]]; then
  echo "Usage: $0 <trace.pftrace>"
  exit 1
fi

python3 << PYEOF
from perfetto.trace_processor import TraceProcessor
import statistics, sys

tp = TraceProcessor(trace='$TRACE')

print("=== Perfetto Multi-Machine Clock Sync Validator ===")
print(f"Trace: $TRACE\n")

# Machines
machines = list(tp.query("SELECT id, release, num_cpus FROM machine;"))
for m in machines:
    print(f"  machine [{m.id}]: {m.release} ({m.num_cpus} CPUs)")
if len(machines) < 2:
    print("ERROR: < 2 machines. Set trace_all_machines: true in your trace config.")
    sys.exit(1)
print()

# QEMU vCPU tids
qemu_rows = list(tp.query("SELECT t.tid FROM thread t JOIN process p ON t.upid=p.upid WHERE t.machine_id=0 AND p.name GLOB '*qemu*';"))
vcpu_tids = ",".join(str(r.tid) for r in qemu_rows)
if not vcpu_tids:
    print("No QEMU threads found (is host running QEMU?)")
    sys.exit(0)
print(f"Host QEMU threads: {[r.tid for r in qemu_rows]}")

# Sched events
host_rows = list(tp.query(f"SELECT ss.ts, ss.dur FROM sched_slice ss JOIN thread t ON ss.utid=t.utid WHERE t.machine_id=0 AND t.tid IN ({vcpu_tids});"))
guest_rows = list(tp.query("SELECT ss.ts, ss.dur FROM sched_slice ss JOIN thread t ON ss.utid=t.utid WHERE t.machine_id=1 AND ss.dur > 500000 LIMIT 500;"))
print(f"Host vCPU sched events: {len(host_rows)}")
print(f"Guest sched events > 0.5ms: {len(guest_rows)}")
print()

if not guest_rows:
    print("No guest sched events found."); sys.exit(0)

host = [(r.ts, r.dur) for r in host_rows]
guest = [(r.ts, r.dur) for r in guest_rows]

# Correlation
overlaps, no_overlaps, offsets = 0, 0, []
for g_ts, g_dur in guest:
    g_end = g_ts + g_dur
    matching = [h for h in host if h[0] < g_end and h[0]+h[1] > g_ts]
    if matching:
        overlaps += 1
        offsets.append(min((h[0]-g_ts)/1e6 for h in matching, key=abs))
    else:
        no_overlaps += 1

total = overlaps + no_overlaps
pct = 100 * overlaps // total if total else 0

print("=== Results ===")
print(f"  Overlap rate: {overlaps}/{total} ({pct}%)")
if offsets:
    print(f"  Onset offset (host_vCPU_start - guest_task_start):")
    print(f"    mean={statistics.mean(offsets):+.2f}ms  median={statistics.median(offsets):+.2f}ms")
    print(f"    stdev={statistics.stdev(offsets):.2f}ms")
    s = sorted(offsets)
    print(f"    p5={s[int(0.05*len(s))]:+.2f}ms  p95={s[int(0.95*len(s))]:+.2f}ms")
    print(f"    min={min(offsets):+.2f}ms  max={max(offsets):+.2f}ms")
print()
if pct >= 95:
    print("  ✅ PASS: Clock alignment GOOD (>=95% overlap)")
    print("     Note: non-zero onset offset is QEMU scheduling latency, not clock error.")
elif pct >= 80:
    print("  ⚠️  WARN: Marginal alignment. Check clock sync configuration.")
else:
    print("  ❌ FAIL: Poor alignment. Significant clock offset likely.")
PYEOF
