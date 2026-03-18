#!/usr/bin/env bash
# validate-trace.sh — Programmatic validation of multi-VM Perfetto traces
#
# Runs trace_processor queries and returns PASS/WARN/FAIL with JSON report.
#
# Usage:
#   bash validate-trace.sh <trace.pftrace> [expected_machines]
#
# Environment:
#   TP_SHELL    Path to trace_processor_shell (auto-detected if not set)
#   DURATION    Expected trace duration in seconds (default: 30)
#
# Exit codes:
#   0 = PASS (all checks passed)
#   1 = WARN (non-critical issues)
#   2 = FAIL (critical issues)

set -euo pipefail

TRACE="${1:-}"
EXPECTED_MACHINES="${2:-3}"
DURATION="${DURATION:-30}"

if [[ -z "$TRACE" || ! -f "$TRACE" ]]; then
  echo "Usage: $0 <trace.pftrace> [expected_machines]"
  echo "  expected_machines: number of machines expected (default: 3)"
  exit 2
fi

# Find trace_processor_shell
TP="${TP_SHELL:-}"
if [[ -z "$TP" ]]; then
  for candidate in \
    /tmp/perfetto-src/out/linux/trace_processor_shell \
    /tmp/perfetto-src/out/linux/stripped/trace_processor_shell \
    "$(command -v trace_processor_shell 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      TP="$candidate"
      break
    fi
  done
fi

if [[ -z "$TP" || ! -x "$TP" ]]; then
  echo "FAIL: trace_processor_shell not found. Set TP_SHELL env var."
  exit 2
fi

# Query helper — runs a SQL query against the trace, returns CSV output
query() {
  "$TP" "$TRACE" -q <(echo "$1") 2>/dev/null
}

# State tracking
OVERALL="PASS"  # PASS < WARN < FAIL
CHECKS_PASS=0
CHECKS_WARN=0
CHECKS_FAIL=0
JSON_CHECKS=""

warn() {
  [[ "$OVERALL" == "PASS" ]] && OVERALL="WARN"
  CHECKS_WARN=$((CHECKS_WARN + 1))
}

fail() {
  OVERALL="FAIL"
  CHECKS_FAIL=$((CHECKS_FAIL + 1))
}

pass() {
  CHECKS_PASS=$((CHECKS_PASS + 1))
}

# JSON helper — append a check result
json_check() {
  local name="$1" status="$2" detail="$3"
  [[ -n "$JSON_CHECKS" ]] && JSON_CHECKS+=","
  JSON_CHECKS+="$(printf '\n    {"check":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")"
}

echo "=== Perfetto Multi-VM Trace Validator ==="
echo "  Trace   : $TRACE"
echo "  Size    : $(du -h "$TRACE" | cut -f1)"
echo "  Expected: $EXPECTED_MACHINES machines, ~${DURATION}s duration"
echo ""

# ─── Check 1: Machine count ───────────────────────────────────────────
MACHINE_CSV=$(query "SELECT id, raw_id, release, num_cpus FROM machine ORDER BY id;")
MACHINE_COUNT=$(echo "$MACHINE_CSV" | tail -n +2 | wc -l)

echo "[1/9] Machine count: $MACHINE_COUNT (expected $EXPECTED_MACHINES)"
echo "$MACHINE_CSV" | tail -n +2 | while IFS=',' read -r id raw_id release num_cpus; do
  echo "       machine $id: $release ($num_cpus CPUs)"
done

if [[ "$MACHINE_COUNT" -eq "$EXPECTED_MACHINES" ]]; then
  echo "       PASS"
  pass
  json_check "machine_count" "PASS" "$MACHINE_COUNT machines"
elif [[ "$MACHINE_COUNT" -gt 0 ]]; then
  echo "       WARN: expected $EXPECTED_MACHINES, got $MACHINE_COUNT"
  warn
  json_check "machine_count" "WARN" "expected $EXPECTED_MACHINES got $MACHINE_COUNT"
else
  echo "       FAIL: no machines found"
  fail
  json_check "machine_count" "FAIL" "0 machines"
fi

# ─── Check 2: Sched events per machine ────────────────────────────────
SCHED_CSV=$(query "SELECT machine_id, count(*) as cnt FROM sched_slice JOIN thread USING(utid) GROUP BY machine_id ORDER BY machine_id;")
echo ""
echo "[2/9] Sched events per machine:"
SCHED_OK=true
SCHED_DETAIL=""
echo "$SCHED_CSV" | tail -n +2 | while IFS=',' read -r mid cnt; do
  echo "       machine $mid: $cnt events"
done

while IFS=',' read -r mid cnt; do
  [[ "$mid" == "\"machine_id\"" ]] && continue
  SCHED_DETAIL+="m${mid}=${cnt} "
  if [[ "$cnt" -lt 100 ]]; then
    SCHED_OK=false
  fi
done <<< "$SCHED_CSV"

if $SCHED_OK; then
  echo "       PASS (all machines > 100 events)"
  pass
  json_check "sched_events" "PASS" "${SCHED_DETAIL}"
else
  echo "       FAIL: some machines have < 100 sched events"
  fail
  json_check "sched_events" "FAIL" "${SCHED_DETAIL}"
fi

# ─── Check 3: Thread-process association ──────────────────────────────
ASSOC_CSV=$(query "SELECT machine_id, count(case when upid is not null then 1 end)*100.0/count(*) as pct FROM thread WHERE utid IN (SELECT DISTINCT utid FROM sched_slice) GROUP BY machine_id ORDER BY machine_id;")
echo ""
echo "[3/9] Thread-process association (target: >90%):"
ASSOC_OK=true
ASSOC_DETAIL=""
while IFS=',' read -r mid pct; do
  [[ "$mid" == "\"machine_id\"" ]] && continue
  # Truncate to 1 decimal
  pct_int="${pct%%.*}"
  echo "       machine $mid: ${pct}%"
  ASSOC_DETAIL+="m${mid}=${pct}% "
  if [[ "$pct_int" -lt 90 ]]; then
    ASSOC_OK=false
  fi
done <<< "$ASSOC_CSV"

if $ASSOC_OK; then
  echo "       PASS"
  pass
  json_check "thread_process_assoc" "PASS" "${ASSOC_DETAIL}"
else
  echo "       WARN: some machines below 90% thread-process association"
  warn
  json_check "thread_process_assoc" "WARN" "${ASSOC_DETAIL}"
fi

# ─── Check 4: Trace errors ───────────────────────────────────────────
ERRORS_CSV=$(query "SELECT name, value FROM stats WHERE severity = 'error' AND value > 0;")
ERROR_COUNT=$(echo "$ERRORS_CSV" | tail -n +2 | wc -l)
echo ""
echo "[4/9] Trace errors:"
ERROR_DETAIL=""

if [[ "$ERROR_COUNT" -eq 0 ]]; then
  echo "       PASS (no errors)"
  pass
  json_check "trace_errors" "PASS" "none"
else
  while IFS=',' read -r name value; do
    [[ "$name" == "\"name\"" ]] && continue
    name="${name//\"/}"
    echo "       $name = $value"
    ERROR_DETAIL+="${name}=${value} "
  done <<< "$ERRORS_CSV"
  # These are warnings, not fatal — Perfetto stats errors are often benign
  echo "       WARN: $ERROR_COUNT error stat(s) found"
  warn
  json_check "trace_errors" "WARN" "${ERROR_DETAIL}"
fi

# ─── Check 5: Data loss ──────────────────────────────────────────────
DATALOSS_CSV=$(query "SELECT name, value FROM stats WHERE severity = 'data_loss' AND value > 0;")
DATALOSS_COUNT=$(echo "$DATALOSS_CSV" | tail -n +2 | wc -l)
echo ""
echo "[5/9] Data loss:"
DATALOSS_DETAIL=""

if [[ "$DATALOSS_COUNT" -eq 0 ]]; then
  echo "       PASS (no data loss)"
  pass
  json_check "data_loss" "PASS" "none"
else
  while IFS=',' read -r name value; do
    [[ "$name" == "\"name\"" ]] && continue
    name="${name//\"/}"
    echo "       $name = $value"
    DATALOSS_DETAIL+="${name}=${value} "
  done <<< "$DATALOSS_CSV"
  echo "       WARN: data loss detected"
  warn
  json_check "data_loss" "WARN" "${DATALOSS_DETAIL}"
fi

# ─── Check 6: Clock snapshots per machine ────────────────────────────
CLOCK_CSV=$(query "SELECT machine_id, count(*) as cnt FROM clock_snapshot GROUP BY machine_id ORDER BY machine_id;")
CLOCK_COUNT=$(echo "$CLOCK_CSV" | tail -n +2 | wc -l)
echo ""
echo "[6/9] Clock snapshots per machine:"
CLOCK_DETAIL=""
CLOCK_OK=true

if [[ "$CLOCK_COUNT" -eq 0 ]]; then
  echo "       FAIL: no clock snapshots found"
  fail
  json_check "clock_snapshots" "FAIL" "none"
else
  while IFS=',' read -r mid cnt; do
    [[ "$mid" == "\"machine_id\"" ]] && continue
    echo "       machine $mid: $cnt snapshots"
    CLOCK_DETAIL+="m${mid}=${cnt} "
  done <<< "$CLOCK_CSV"
  # Check all expected machines have snapshots
  MACHINES_WITH_CLOCKS=$CLOCK_COUNT
  if [[ "$MACHINES_WITH_CLOCKS" -lt "$EXPECTED_MACHINES" ]]; then
    echo "       WARN: only $MACHINES_WITH_CLOCKS/$EXPECTED_MACHINES machines have clock snapshots"
    warn
    json_check "clock_snapshots" "WARN" "${CLOCK_DETAIL}"
    CLOCK_OK=false
  fi
  if $CLOCK_OK; then
    echo "       PASS"
    pass
    json_check "clock_snapshots" "PASS" "${CLOCK_DETAIL}"
  fi
fi

# ─── Check 7: Per-machine trace duration ─────────────────────────────
DUR_CSV=$(query "SELECT machine_id, (MAX(ts)-MIN(ts))/1e9 as dur_s FROM sched_slice JOIN thread USING(utid) GROUP BY machine_id ORDER BY machine_id;")
echo ""
echo "[7/9] Per-machine trace duration (target: ~${DURATION}s):"
DUR_OK=true
DUR_DETAIL=""
TOLERANCE=$(echo "$DURATION * 0.5" | bc)  # 50% tolerance

while IFS=',' read -r mid dur; do
  [[ "$mid" == "\"machine_id\"" ]] && continue
  dur_int="${dur%%.*}"
  echo "       machine $mid: ${dur}s"
  DUR_DETAIL+="m${mid}=${dur}s "
  # Check within tolerance
  DIFF=$(echo "$dur - $DURATION" | bc)
  ABS_DIFF=$(echo "${DIFF#-}")
  if (( $(echo "$ABS_DIFF > $TOLERANCE" | bc -l) )); then
    DUR_OK=false
  fi
done <<< "$DUR_CSV"

if $DUR_OK; then
  echo "       PASS (all within 50% of ${DURATION}s)"
  pass
  json_check "trace_duration" "PASS" "${DUR_DETAIL}"
else
  echo "       WARN: some machines outside expected duration"
  warn
  json_check "trace_duration" "WARN" "${DUR_DETAIL}"
fi

# ─── Check 8: Orphan threads ─────────────────────────────────────────
ORPHAN_CSV=$(query "SELECT count(*) as cnt FROM thread WHERE utid IN (SELECT DISTINCT utid FROM sched_slice) AND machine_id IS NULL;")
ORPHAN_COUNT=$(echo "$ORPHAN_CSV" | tail -n +2 | tr -d ' ')
echo ""
echo "[8/9] Orphan threads (sched events but no machine_id):"
echo "       Count: $ORPHAN_COUNT"

if [[ "$ORPHAN_COUNT" -eq 0 ]]; then
  echo "       PASS"
  pass
  json_check "orphan_threads" "PASS" "0"
else
  echo "       FAIL: $ORPHAN_COUNT threads with sched events but no machine_id"
  fail
  json_check "orphan_threads" "FAIL" "$ORPHAN_COUNT"
fi

# ─── Check 9: Clock sync (optional, requires python3+perfetto) ────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOCKSYNC_SCRIPT="$SCRIPT_DIR/clocksync-validate.sh"
echo ""
echo "[9/9] Clock sync validation:"

if ! python3 -c "from perfetto.trace_processor import TraceProcessor" 2>/dev/null; then
  echo "       SKIP (python3 perfetto package not installed)"
  json_check "clock_sync" "SKIP" "perfetto python package not available"
elif [[ ! -f "$CLOCKSYNC_SCRIPT" ]]; then
  echo "       SKIP (clocksync-validate.sh not found)"
  json_check "clock_sync" "SKIP" "script not found"
else
  CLOCKSYNC_EXIT=0
  CLOCKSYNC_OUT=$(bash "$CLOCKSYNC_SCRIPT" "$TRACE" 2>&1) || CLOCKSYNC_EXIT=$?
  # Show per-guest results
  echo "$CLOCKSYNC_OUT" | grep -E "^(---|  )" | sed 's/^/       /'
  CLOCKSYNC_JSON="${TRACE%.pftrace}-clocksync.json"
  if [[ "$CLOCKSYNC_EXIT" -eq 0 ]]; then
    echo "       PASS (all guests clock-aligned)"
    pass
    json_check "clock_sync" "PASS" "see ${CLOCKSYNC_JSON}"
  elif [[ "$CLOCKSYNC_EXIT" -eq 1 ]]; then
    echo "       WARN (marginal clock alignment)"
    warn
    json_check "clock_sync" "WARN" "see ${CLOCKSYNC_JSON}"
  else
    echo "       WARN (clock sync failed for some guests — see ${CLOCKSYNC_JSON})"
    warn  # clock sync failure is a WARN for overall (not blocking)
    json_check "clock_sync" "WARN" "clock sync failed, see ${CLOCKSYNC_JSON}"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────
TOTAL=$((CHECKS_PASS + CHECKS_WARN + CHECKS_FAIL))
echo ""
echo "=== Summary ==="
echo "  PASS: $CHECKS_PASS  WARN: $CHECKS_WARN  FAIL: $CHECKS_FAIL  (total: $TOTAL)"
echo "  Overall: $OVERALL"

# Write JSON report
JSON_FILE="${TRACE%.pftrace}-validation.json"
cat > "$JSON_FILE" << JSONEOF
{
  "trace": "$TRACE",
  "timestamp": "$(date -Iseconds)",
  "expected_machines": $EXPECTED_MACHINES,
  "expected_duration_s": $DURATION,
  "result": "$OVERALL",
  "summary": {"pass": $CHECKS_PASS, "warn": $CHECKS_WARN, "fail": $CHECKS_FAIL},
  "checks": [${JSON_CHECKS}
  ]
}
JSONEOF
echo "  Report: $JSON_FILE"

# Exit code
case "$OVERALL" in
  PASS) exit 0 ;;
  WARN) exit 1 ;;
  FAIL) exit 2 ;;
esac
