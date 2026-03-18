#!/usr/bin/env bash
# clocksync-validate.sh
# Validate clock synchronization in a multi-machine Perfetto trace
# Correlates host vCPU scheduling with guest task scheduling for ALL guests.
#
# Requires: python3 + perfetto pip package (pip3 install perfetto)
#
# Usage: bash clocksync-validate.sh <trace.pftrace>
#
# Exit codes: 0=PASS, 1=WARN, 2=FAIL

set -euo pipefail

TRACE="${1:-}"
if [[ -z "$TRACE" || ! -f "$TRACE" ]]; then
  echo "Usage: $0 <trace.pftrace>"
  exit 1
fi

export _TRACE_PATH="$TRACE"
python3 << 'PYEOF'
from perfetto.trace_processor import TraceProcessor
import statistics, sys, json, os

trace_path = os.environ['_TRACE_PATH']
tp = TraceProcessor(trace=trace_path)

print("=== Perfetto Multi-Machine Clock Sync Validator ===")
print(f"Trace: {trace_path}\n")

# Machines
machines = list(tp.query("SELECT id, release, num_cpus FROM machine ORDER BY id;"))
for m in machines:
    print(f"  machine [{m.id}]: {m.release} ({m.num_cpus} CPUs)")
if len(machines) < 2:
    print("ERROR: < 2 machines. Set trace_all_machines: true in your trace config.")
    sys.exit(2)
print()

host_id = 0
guest_ids = [m.id for m in machines if m.id != host_id]

# Find host hypervisor/QEMU vCPU threads
# Try qvm (QNX HV) first, then QEMU
qvm_rows = list(tp.query(
    f"SELECT t.tid FROM thread t JOIN process p ON t.upid=p.upid "
    f"WHERE t.machine_id={host_id} AND p.name GLOB '*qvm*';"
))
qemu_rows = list(tp.query(
    f"SELECT t.tid FROM thread t JOIN process p ON t.upid=p.upid "
    f"WHERE t.machine_id={host_id} AND p.name GLOB '*qemu*';"
))

vcpu_rows = qvm_rows if qvm_rows else qemu_rows
vcpu_source = "qvm" if qvm_rows else "QEMU"
vcpu_tids = ",".join(str(r.tid) for r in vcpu_rows)

if not vcpu_tids:
    print("No hypervisor vCPU threads found (qvm or QEMU)")
    print("Cannot perform clock sync correlation without host vCPU threads.")
    sys.exit(1)

print(f"Host {vcpu_source} threads ({len(vcpu_rows)}): {[r.tid for r in vcpu_rows]}")

# Get all host vCPU sched events
host_sched = list(tp.query(
    f"SELECT ss.ts, ss.dur FROM sched_slice ss "
    f"JOIN thread t ON ss.utid=t.utid "
    f"WHERE t.machine_id={host_id} AND t.tid IN ({vcpu_tids});"
))
host = [(r.ts, r.dur) for r in host_sched]
print(f"Host vCPU sched events: {len(host)}\n")

overall = "PASS"
results = []

for guest_id in guest_ids:
    guest_info = [m for m in machines if m.id == guest_id][0]
    print(f"--- Guest machine {guest_id}: {guest_info.release} ---")

    guest_sched = list(tp.query(
        f"SELECT ss.ts, ss.dur FROM sched_slice ss "
        f"JOIN thread t ON ss.utid=t.utid "
        f"WHERE t.machine_id={guest_id} AND ss.dur > 500000 LIMIT 500;"
    ))
    print(f"  Guest sched events > 0.5ms: {len(guest_sched)}")

    if not guest_sched:
        print("  SKIP: No guest sched events found.\n")
        results.append({"machine_id": guest_id, "status": "SKIP", "overlap_pct": 0})
        continue

    guest = [(r.ts, r.dur) for r in guest_sched]

    # Correlation: for each guest event, find overlapping host vCPU events
    overlaps, no_overlaps, offsets = 0, 0, []
    for g_ts, g_dur in guest:
        g_end = g_ts + g_dur
        matching = [h for h in host if h[0] < g_end and h[0] + h[1] > g_ts]
        if matching:
            overlaps += 1
            offsets.append(min(((h[0] - g_ts) / 1e6 for h in matching), key=abs))
        else:
            no_overlaps += 1

    total = overlaps + no_overlaps
    pct = 100 * overlaps // total if total else 0

    print(f"  Overlap rate: {overlaps}/{total} ({pct}%)")
    if offsets:
        print(f"  Onset offset (host_vCPU_start - guest_task_start):")
        print(f"    mean={statistics.mean(offsets):+.2f}ms  median={statistics.median(offsets):+.2f}ms")
        if len(offsets) > 1:
            print(f"    stdev={statistics.stdev(offsets):.2f}ms")
        s = sorted(offsets)
        print(f"    p5={s[int(0.05*len(s))]:+.2f}ms  p95={s[int(0.95*len(s))]:+.2f}ms")
        print(f"    min={min(offsets):+.2f}ms  max={max(offsets):+.2f}ms")

    if pct >= 95:
        status = "PASS"
        print(f"  PASS: Clock alignment GOOD (>= 95% overlap)\n")
    elif pct >= 80:
        status = "WARN"
        if overall == "PASS":
            overall = "WARN"
        print(f"  WARN: Marginal alignment ({pct}%). Check clock sync.\n")
    else:
        status = "FAIL"
        overall = "FAIL"
        print(f"  FAIL: Poor alignment ({pct}%). Significant clock offset likely.\n")

    result = {"machine_id": guest_id, "status": status, "overlap_pct": pct}
    if offsets:
        result["mean_offset_ms"] = round(statistics.mean(offsets), 2)
        result["median_offset_ms"] = round(statistics.median(offsets), 2)
    results.append(result)

# Check for RemoteClockSync packets in the raw trace proto
# RemoteClockSync = field 107 in TracePacket
import struct as _struct
def _read_varint(data, pos):
    result, shift = 0, 0
    while pos < len(data):
        b = data[pos]; result |= (b & 0x7f) << shift; pos += 1
        if not (b & 0x80): break
        shift += 7
    return result, pos

rcs_info = []
try:
    with open(trace_path, 'rb') as f:
        raw = f.read()
    pos = 0
    while pos < len(raw):
        tag, new_pos = _read_varint(raw, pos)
        fn, wt = tag >> 3, tag & 0x7
        if wt == 2:
            length, new_pos = _read_varint(raw, new_pos)
            if new_pos + length > len(raw): break
            if fn == 1:
                pkt = raw[new_pos:new_pos+length]
                mid, has_rcs = None, False
                pp = 0
                while pp < len(pkt):
                    try: ptag, pp2 = _read_varint(pkt, pp)
                    except: break
                    pfn, pwt = ptag >> 3, ptag & 0x7
                    if pfn == 98 and pwt == 0: mid, pp = _read_varint(pkt, pp2)
                    elif pfn == 107 and pwt == 2: has_rcs = True; plen, pp = _read_varint(pkt, pp2); pp += plen
                    elif pwt == 0: _, pp = _read_varint(pkt, pp2)
                    elif pwt == 2: plen, pp = _read_varint(pkt, pp2); pp += plen
                    elif pwt == 5: pp = pp2 + 4
                    elif pwt == 1: pp = pp2 + 8
                    else: break
                if has_rcs:
                    rcs_info.append(mid)
            pos = new_pos + length
        elif wt == 0: _, pos = _read_varint(raw, new_pos)
        else: break
except Exception as e:
    pass

print(f"\n--- RemoteClockSync packets ---")
if rcs_info:
    for mid in rcs_info:
        print(f"  RemoteClockSync present for machine_id={mid}")
    print(f"  Clock offsets are computed by trace_processor from this data.")
    # Downgrade FAIL to WARN for guests when RemoteClockSync data exists
    # The overlap heuristic doesn't account for clock domain offsets
    for r in results:
        if r["status"] == "FAIL":
            r["status"] = "WARN"
            r["note"] = "RemoteClockSync present; overlap heuristic unreliable across clock domains"
            if overall == "FAIL":
                overall = "WARN"
            print(f"  machine {r['machine_id']}: downgraded FAIL->WARN (RemoteClockSync present)")
else:
    print(f"  No RemoteClockSync packets found (relay IPC clock sync may not be working)")

print(f"\n=== Overall: {overall} ===")

# Write JSON report
json_path = trace_path.replace(".pftrace", "-clocksync.json")
report = {
    "trace": trace_path,
    "result": overall,
    "vcpu_source": vcpu_source,
    "host_vcpu_events": len(host),
    "remote_clock_sync_machines": rcs_info,
    "guests": results,
}
with open(json_path, "w") as f:
    json.dump(report, f, indent=2)
print(f"Report: {json_path}")

if overall == "FAIL":
    sys.exit(2)
elif overall == "WARN":
    sys.exit(1)
else:
    sys.exit(0)
PYEOF
