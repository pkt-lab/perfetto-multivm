# Evaluation: Upstream Perfetto as Central Traced on Linux Guest

**Date**: 2026-03-23
**Status**: Partially successful — 2 of 3 machines verified

## Goal

Test whether **pure upstream Perfetto** on a Linux guest can orchestrate multi-VM
tracing across QNX hypervisor + QNX guest, with zero patched code on the Linux guest.

## Architecture Tested

```
Linux Guest           ← upstream traced + traced_probes + perfetto CLI
  │ TCP:0.0.0.0:20001 (--enable-relay-endpoint)
  │
  ├─ QNX Host         ← QNX-patched: traced_relay + traced_qnx_probes
  │    relay → Linux guest:20001 (direct vdevpeer TCP)
  │    TCP proxy 0.0.0.0:20001 → Linux guest:20001 (for QNX guest)
  │
  └─ QNX Guest        ← QNX-patched: traced_relay + traced_qnx_probes
       relay → host:20001 (via TCP proxy → Linux guest)
```

## Results

### What worked

| Check | Result | Detail |
|-------|--------|--------|
| Linux guest boots with upstream Perfetto | PASS | traced, traced_probes, perfetto CLI all pure upstream |
| Central traced accepts relay connections | PASS | `--enable-relay-endpoint` on TCP:20001 |
| QNX host relay connects and sends data | PASS | Machine 1 registered, 749K sched events |
| Linux local probes capture ftrace | PASS | Machine 0, 8K sched events |
| Thread-process association (Linux) | PASS | 100% |
| Zero data loss (QNX host) | PASS | 0 data loss events |
| Trace captured and downloaded | PASS | 99MB via netcat over SSH tunnel |
| Orphan threads | PASS | 0 orphan threads |

### What didn't work

| Issue | Detail | Impact |
|-------|--------|--------|
| QNX guest relay unstable | Repeated connect/disconnect through vsock→tcp-proxy chain | Only 2/3 machines in trace |
| Clock alignment | No clock snapshots for QNX machine → broken timestamps | Clock sync broken |
| Thread-process (QNX) | 66.7% (vs 100% in host-central topology) | Partial association |

### Key Metrics

| Metric | Linux Guest (m0) | QNX Host (m1) | QNX Guest |
|--------|-----------------|----------------|-----------|
| OS | Linux 6.6 | QNX 8.0.0 | QNX 8.0.0 |
| CPUs | 2 | 1 | 1 |
| Sched events | 8,244 | 749,582 | N/A (not in trace) |
| Processes | 65 | 42 | N/A |
| Clock snapshots | 42 | 0 | N/A |

## Analysis

### Zero patched code on Linux — CONFIRMED

The Linux guest runs only upstream Perfetto binaries (traced, traced_probes,
perfetto CLI, libperfetto.so). No QNX-specific patches are present. QNX kernel
event parsing happens in trace_processor_shell at analysis time, not in the
traced/relay path.

### Clock sync issue

The QNX machine has 0 clock snapshots. The SyncClock RPC between upstream
traced and the QNX-patched relay needs investigation — upstream may handle
the relay clock sync protocol differently.

### QNX guest instability

The QNX guest uses vsock → vdev bridge → tcp-proxy → Linux guest, which
causes connection cycling. Fix: use direct TCP via vdevpeer-net instead of vsock.

## Next Steps

1. **Fix clock sync**: Investigate SyncClock RPC compatibility
2. **QNX guest TCP relay**: Use `PERFETTO_RELAY_SOCK_NAME=<host_ip>:20001` instead of vsock
3. **Thread-process association**: Investigate 66.7% on QNX host
4. **3-machine validation**: Full pass criteria check
