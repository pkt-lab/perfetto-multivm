# Evaluation: Upstream Perfetto as Central Traced on Linux Guest

**Date**: 2026-03-23
**Status**: Partially successful — 2 of 3 machines verified

## Goal

Test whether **pure upstream Perfetto** on a Linux guest can orchestrate multi-VM
tracing across QNX hypervisor + QNX guest, with zero qnx-ports code on the Linux guest.

## Architecture Tested

```
Linux Guest (10.10.10.3)          ← upstream traced + traced_probes + perfetto CLI
  │ TCP:0.0.0.0:20001 (--enable-relay-endpoint)
  │
  ├─ QNX Host (10.10.10.1)       ← qnx-ports: traced_relay + traced_qnx_probes
  │    relay → 10.10.10.3:20001 (direct vdevpeer TCP)
  │    TCP proxy 0.0.0.0:20001 → 10.10.10.3:20001 (for QNX guest)
  │
  └─ QNX Guest (10.10.10.2)      ← qnx-ports: traced_relay + traced_qnx_probes
       relay → vsock://2:20001 → vdev bridge → TCP proxy → Linux guest
       (UNSTABLE — repeated connect/disconnect)
```

## Results

### What worked

| Check | Result | Detail |
|-------|--------|--------|
| Linux guest boots with upstream Perfetto | PASS | traced, traced_probes, perfetto CLI all pure upstream |
| Central traced accepts relay connections | PASS | `--enable-relay-endpoint` on TCP:20001 |
| QNX host relay connects and sends data | PASS | Machine 1 registered, 749,582 sched events |
| Linux local probes capture ftrace | PASS | Machine 0, 8,244 sched events |
| Thread-process association (Linux) | PASS | 100% |
| Thread-process association (QNX host) | PARTIAL | 66.7% (vs 100% in host-central topology) |
| Zero data loss (QNX host) | PASS | 0 data loss events |
| Trace captured and downloaded | PASS | 99MB via netcat over SSH tunnel |
| Orphan threads | PASS | 0 orphan threads |

### What didn't work

| Issue | Detail | Impact |
|-------|--------|--------|
| QNX guest relay unstable | Repeated connect/disconnect through vsock→tcp-proxy chain | Only 2/3 machines in trace |
| Clock alignment | QNX host shows 496,326s duration (should be ~30s) — no clock snapshots for machine 1 | Clock sync broken |
| 2 flush failures | `traced_flushes_failed: 2` | Minor data loss possible |
| 141 task state errors | `generic_task_state_invalid_order: 141` | Some QNX events mis-ordered |

### Key Metrics

| Metric | Linux Guest (m0) | QNX Host (m1) | QNX Guest (m2) |
|--------|-----------------|----------------|-----------------|
| OS | 6.6.84-yocto-standard | QNX 8.0.0 | QNX 8.0.0 |
| CPUs | 2 | 1 | 1 |
| Sched events | 8,244 | 749,582 | N/A (not in trace) |
| Processes | 65 | 42 | N/A |
| Thread-process % | 100% | 66.7% | N/A |
| Clock snapshots | 42 | 0 | N/A |

## Analysis

### Zero qnx-ports code on Linux — CONFIRMED

The Linux guest runs:
- `traced` from upstream perfetto `main` branch (commit d8212fcc1d)
- `traced_probes` from upstream
- `perfetto` CLI from upstream
- `libperfetto.so` from upstream

No qnx-ports patches are present. The QNX kernel event parsing happens in
`trace_processor_shell` (qnx-ports), not in traced/relay.

### Clock sync issue

The QNX host has 0 clock snapshots, causing the 496,326s apparent duration.
This is because the SyncClock RPC (used for clock alignment) requires both
sides to participate. In the host-central topology, traced runs the clock
sync protocol with relay clients. The upstream traced may handle SyncClock
differently, or the qnx-main relay may not be sending clock snapshots
correctly to an upstream traced.

**Root cause investigation needed**: Check if upstream `--enable-relay-endpoint`
processes SyncClock the same way as qnx-ports traced.

### QNX guest instability

The QNX guest relay uses: vsock → vdev-virtio-vsock bridge → TCP localhost:20001 → tcp-proxy → 10.10.10.3:20001

The multi-hop path causes connection cycling (connect, disconnect, reconnect
every ~2s). Per the plan, the QNX guest should use direct TCP
(`10.10.10.1:20001` via vdevpeer-net) instead of vsock. This requires a new
QNX guest IFS with `PERFETTO_RELAY_SOCK_NAME=10.10.10.1:20001`.

## Files Created

| File | Purpose |
|------|---------|
| `scripts/tcp-proxy.c` | TCP proxy for QNX host (build with qcc) |
| `scripts/init-linux-central.sh` | Linux guest init for central traced |
| `scripts/build-initrd-linux-central.sh` | Build script for central traced initrd |
| `scripts/start-linux-central.sh` | Deployment script for Linux-central topology |
| `scripts/capture-linux-central.sh` | Trace download script |
| `configs/linux-central-3vm.pbtxt` | Trace config for Linux-central topology |
| `configs/linux-central.conf` | QVM config for Linux central guest |

## Builds

| Binary | Source | Built on | Stripped size |
|--------|--------|----------|--------------|
| Linux traced | upstream main (d8212fcc1d) | GB10 (aarch64) | 18K + 3.2M libperfetto.so |
| Linux traced_probes | upstream main | GB10 | 18K |
| Linux perfetto | upstream main | GB10 | 1.9M |
| QNX traced_relay | qnx-ports qnx-main (e0bf17763f) | AMD (qcc) | 194K |
| QNX traced_qnx_probes | qnx-ports qnx-main | AMD (qcc) | 403K |
| QNX libperfetto.so | qnx-ports qnx-main | AMD (qcc) | 1.1M |
| tcp-proxy | New | AMD (qcc) | 10K |

## Next Steps

1. **Fix clock sync**: Investigate SyncClock RPC between upstream traced and qnx-ports relay
2. **QNX guest TCP relay**: Build new QNX guest IFS with `PERFETTO_RELAY_SOCK_NAME=10.10.10.1:20001`
3. **Thread-process association**: Investigate why QNX host is 66.7% (was 100% in host-central)
4. **3-machine validation**: Once above fixed, validate full 3-machine trace
5. **Pass criteria check**: 3 machines, linux.ftrace + qnx.kernel, clock alignment <150ms
