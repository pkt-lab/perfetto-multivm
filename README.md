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

## Contents

| Path | Description |
|---|---|
| `docs/vsock-relay-guide.md` | Full setup guide: QEMU, host traced, guest relay |
| `scripts/start-host-traced.sh` | Start host traced with vsock relay endpoint |
| `scripts/start-guest-relay.sh` | Start guest traced_relay + traced_probes |
| `configs/multivm-basic.pbtxt` | Basic multi-machine trace config |
| `configs/multivm-clocksync-test.pbtxt` | Clock sync precision test config |

## Tested Environments

| Host | Guest | Status |
|---|---|---|
| Linux 6.14 (aarch64, 20 CPUs) | AGL Terrific Trout 6.6.84 (virtio-aarch64, 4 CPUs) via QEMU | ✅ |

## Roadmap

- [ ] Clock sync precision analysis (measure host-guest timestamp offset accuracy)
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
