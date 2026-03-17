# perfetto-multivm

Multi-machine Perfetto tracing via vsock relay — **online, single `.pftrace`, no offline merge**.

## What This Is

Demonstrates Perfetto's `traced_relay` architecture for cross-VM tracing. A single `perfetto` CLI command captures scheduling, process, and ftrace data from both a host Linux system and one or more QEMU guests simultaneously.

```
Host traced ◄──vsock──► Guest traced_relay ◄──UNIX──► Guest traced_probes
     │                                                        │
  consumers                                             ftrace / procstats
  .pftrace out                                         (guest kernel data)
```

## Quick Start

See [`docs/vsock-relay-guide.md`](docs/vsock-relay-guide.md) for full setup.

```bash
# 1. Host: start traced with relay endpoint (as root)
sudo bash scripts/start-host-traced.sh /path/to/perfetto-v54

# 2. Guest: start relay + probes
bash scripts/start-guest-relay.sh /tmp/tracebox54

# 3. Host: record (MUST include trace_all_machines: true)
PERFETTO_CONSUMER_SOCK_NAME=/tmp/pf-consumer \
  perfetto -c configs/multivm-basic.pbtxt --txt -o out.pftrace
```

## Key Finding: Perfetto v54 Breaking Change

`trace_all_machines: true` is **required** in the trace config starting from v54.  
Without it, remote machine (relay-connected) producers are silently filtered out and no guest data is recorded.

Source: `src/tracing/service/tracing_service_impl.cc`:
```cpp
} else if (!tracing_session->config.trace_all_machines() && !is_host_machine) {
    // Default in v54: only trace host machine
    return nullptr;
}
```

## Architectures

### A: Standalone Guest Trace (virtio-blk)

Linux ARM64 guest inside QNX Hypervisor captures its own trace and writes it
to a virtio-blk device — no host connectivity required.

```
AMD host (x86_64)
└── QEMU (aarch64)
    └── QNX Hypervisor 8.0
        └── Linux 6.1 ARM64 guest
            ├── traced + traced_probes
            └── /dev/vda ──► /data/linux-trace.img (on QNX HV)
```

See [`docs/linux-qvm/README.md`](docs/linux-qvm/README.md) for full setup.

### B: Cross-VM Relay (vsock/TCP)

Host `traced` with relay endpoint collects from guest `traced_relay` + `traced_probes`
into a single merged `.pftrace`. Requires vsock or TCP connectivity.

```
Host traced ◄──vsock──► Guest traced_relay ◄──UNIX──► Guest traced_probes
     │                                                        │
  consumers                                             ftrace / procstats
  .pftrace out                                         (guest kernel data)
```

See [`docs/vsock-relay-guide.md`](docs/vsock-relay-guide.md) for full setup.

## Contents

| Path | Description |
|---|---|
| `docs/linux-qvm/README.md` | Linux ARM64 QVM guest tracing (Arch A, standalone) |
| `docs/vsock-relay-guide.md` | Cross-VM relay setup guide (Arch B) |
| `scripts/linux-qvm/build-initrd.sh` | Build initrd with Perfetto + virtio_blk.ko |
| `scripts/linux-qvm/guest-init.sh` | Guest init: capture trace → write to /dev/vda |
| `scripts/linux-qvm/boot-and-capture.sh` | Boot QVM guest and extract trace (from AMD host) |
| `scripts/build-and-boot-hyp.sh` | Automated: build + patch + boot QNX HV on QEMU |
| `scripts/start-host-traced.sh` | Start host traced with vsock relay endpoint |
| `scripts/start-guest-relay.sh` | Start guest traced_relay + traced_probes |
| `configs/linux-guest-ftrace.pbtxt` | Perfetto config for Linux QVM guest (Arch A) |
| `configs/multivm-basic.pbtxt` | Basic multi-machine trace config (Arch B) |
| `configs/multivm-clocksync-test.pbtxt` | Clock sync precision test config |

## Tested Environments

| Architecture | Host | Guest | Status |
|---|---|---|---|
| A (virtio-blk) | QNX 8.0 HV (aarch64 QEMU on x86_64) | Linux 6.1.0-42-arm64 (QVM) | ✅ 17KB trace |
| B (vsock relay) | Linux 6.14 (aarch64, 20 CPUs) | AGL Terrific Trout 6.6.84 via QEMU | ✅ |
| HV boot | x86_64 Linux (AMD Ryzen) | QNX 8.0 HV (aarch64 TCG) | ✅ SSH + qvm |
| HV boot | aarch64 Linux (NVIDIA GB10) | QNX 8.0 HV (aarch64 TCG) | ✅ SSH + qvm (⚠️ qvm blocked) |

## Roadmap

- [x] Clock sync precision analysis (mean offset +1.51ms, 100% vCPU correlation)
- [x] Linux ARM64 QVM guest with virtio-blk trace output (Arch A)
- [ ] Architecture B: QNX HV `traced_relay` → AMD host `traced` via TCP
- [ ] Linux + Android dual-VM test
- [ ] Multi-hypervisor support: QNX Hypervisor, Xen, pKVM
- [ ] Automated clock correlation script

## Requirements

- Perfetto v54.0+ binaries ([releases](https://github.com/google/perfetto/releases))
- QEMU with `-device vhost-vsock-device,guest-cid=<N>`
- Host: `vhost_vsock` kernel module, user in `kvm` group
- Guest: `CONFIG_VIRTIO_VSOCKETS=y`, `/dev/vsock` present

## License

Scripts and configs: MIT  
Perfetto: Apache 2.0
