# perfetto-multivm

Multi-machine Perfetto tracing for QNX Hypervisor — **unified 3-VM traces in a single `.pftrace`**.

## What This Is

Production-ready multi-VM tracing using Perfetto's `traced_relay` architecture. A single `perfetto` CLI command captures QNX kernel scheduling, Linux ftrace, and process data from a QNX hypervisor host and its guest VMs simultaneously.

Verified: 3-VM unified trace (QNX host + QNX guest + Linux guest), 15-30s captures, zero data loss, 100% thread-process association.

```
QNX HV host
├── traced (listens on Unix + TCP:20001)
├── traced_qnx_probes (host kernel scheduler events)
│
├── QNX guest (qvm)
│   ├── traced_relay → TCP 10.10.10.1:20001
│   └── traced_qnx_probes (guest kernel events)
│
└── Linux guest (qvm)
    ├── traced_relay → vsock://2:20001 or TCP 10.10.10.1:20001
    └── traced_probes (ftrace: sched, task events)
```

## Transport Options

| Transport | Guest | Status | How |
|-----------|-------|--------|-----|
| **TCP** | QNX guest | Verified | vdevpeer-net IP routing |
| **TCP** | Linux guest | Verified | vdevpeer-net IP routing |
| **vsock** | Linux guest | Verified | vdev-virtio-vsock plugin |
| **vsock** | QNX guest | In progress | libvsock.so LD_PRELOAD shim |

vsock source code is in the private [pkt-lab/qnx-virtio-vsock](https://github.com/pkt-lab/qnx-virtio-vsock) repository.

## Key Finding: Perfetto v54 Breaking Change

`trace_all_machines: true` is **required** in the trace config starting from v54.
Without it, relay-connected guest producers are silently filtered out and no guest data is recorded.

## Quick Start (3-VM Trace)

```bash
# On QNX HV host (via SSH):

# 1. Start traced with relay endpoint
PERFETTO_PRODUCER_SOCK_NAME=/data/sock/perfetto-producer,0.0.0.0:20001 \
PERFETTO_CONSUMER_SOCK_NAME=/data/sock/perfetto-consumer \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/traced --enable-relay-endpoint &

# 2. Start host probes
PERFETTO_PRODUCER_SOCK_NAME=/data/sock/perfetto-producer \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/traced_qnx_probes &

# 3. Boot guests (they auto-connect via relay)
qvm @/dev/shmem/qnx-guest.conf &
qvm @/dev/shmem/linux-guest.conf &

# 4. Capture unified trace (writes to shmem to avoid /data disk limits)
PERFETTO_CONSUMER_SOCK_NAME=/data/sock/perfetto-consumer \
LD_LIBRARY_PATH=/proc/boot:/data \
/data/perfetto -o /dev/shmem/trace.pftrace \
  -c configs/multivm-3vm.pbtxt --txt
```

## Verified Results

| Metric | TCP (both guests) | vsock (Linux) + TCP (QNX) |
|--------|-------------------|---------------------------|
| File size (15s) | 23.2 MB | 24.0 MB |
| Host sched events | 115,849 | 110,225 |
| Linux guest sched | 383 | 374 |
| QNX guest sched | 84,564 | 88,809 |
| Thread-process assoc | 100% all machines | 100% all machines |
| Data loss | 0 | 0 |

## Contents

| Path | Description |
|------|-------------|
| `configs/multivm-3vm.pbtxt` | 3-VM trace config (separate buffers, QNX + Linux) |
| `configs/multivm-basic.pbtxt` | Basic multi-machine config (trace_all_machines: true) |
| `scripts/validate-trace.sh` | 9-point automated trace quality validation |
| `scripts/clocksync-validate.sh` | Multi-machine clock sync validation |
| `scripts/capture-3vm-trace.sh` | End-to-end 3-VM trace capture + download |
| `scripts/start-3vm-perfetto.sh` | Start full 3-VM tracing stack on HV |
| `scripts/start-host-traced.sh` | Start host traced with relay endpoint |
| `scripts/start-guest-relay.sh` | Start guest traced_relay + probes |
| `scripts/linux-qvm/guest-init-v8.sh` | Linux guest init (low-churn workloads) |
| `scripts/linux-qvm/guest-init-v9.sh` | Linux guest init (vsock auto-detect + TCP fallback) |
| `docs/qnx-hypervisor/ARCHITECTURE.md` | 3-VM system architecture + data flow |
| `docs/qnx-hypervisor/SETUP.md` | Step-by-step QNX HV reproduction guide |
| `docs/qnx-hypervisor/NEXT-PHASES.md` | Phase status: validation, vsock, FVP, ETM |
| `docs/clocksync-analysis.md` | Clock sync precision analysis |

## Related Repositories

| Repository | Branch | Description |
|------------|--------|-------------|
| [pkt-lab/perfetto](https://github.com/pkt-lab/perfetto) | `qnx-main` | QNX Perfetto fork (all patches) |
| [pkt-lab/perfetto](https://github.com/pkt-lab/perfetto) | `qnx-tcp` | TCP transport patches |
| [pkt-lab/perfetto](https://github.com/pkt-lab/perfetto) | `qnx-vsock` | vsock transport patches |
| [pkt-lab/qnx-virtio-vsock](https://github.com/pkt-lab/qnx-virtio-vsock) | `main` | vsock vdev plugin + libvsock (private) |

## Perfetto Fork Patches (pkt-lab/perfetto)

6 patches on top of qnx-ports/perfetto:

| Commit | Description | Needed for |
|--------|-------------|------------|
| `7d356becdc` | Add traced_qnx_probes for QNX SDP7.1 | Both |
| `17ca190325` | Error out on startup tracelog failure | Both |
| `efae914cda` | Populate set_is_idle in GenericKernelProcessTree | Both |
| `5e31b13665` | Fix QNX 8.0 compatibility for traced_qnx_probes | Both |
| `8b3ddc082d` | Fix SCM_RIGHTS failure on TCP for traced_relay | TCP + vsock |
| `b982fdcd82` | Fix QNX guest thread naming and process association | Both |

## Environment

Tested on NVIDIA GB10 (Orin) with QEMU 9.2.3:
- QNX Hypervisor 8.0 host (aarch64, 4 vCPU, 2GB RAM)
- QNX 8.0 guest (1 vCPU, 512MB) via qvm
- Linux AGL 6.6.84 guest (2 vCPU, 512MB) via qvm
- Inter-VM networking: vdevpeer-net (10.10.10.x)

## License

Scripts and configs: MIT
Perfetto: Apache 2.0
