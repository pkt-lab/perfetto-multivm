# Multi-VM Perfetto Relay Architecture

## System Diagram

```
┌─────────────────────────────────────────────────────┐
│                    gb10 Host (Linux)                  │
│  QEMU 9.2.3 (virt-4.2, cortex-a57, smp 4, 2G)      │
│  SSH: localhost:2241 → QNX HV:22                     │
├─────────────────────────────────────────────────────┤
│              QNX 8.0 HV Host (procnto-smp-instr)     │
│                                                       │
│  io-sock ─── vtnet0 (10.0.2.15, QEMU NAT)           │
│         └── vp0 (10.10.10.1/24, vdevpeer-net)       │
│                    │                                  │
│  traced (--enable-relay-endpoint)                     │
│    ├── Unix: /data/sock/perfetto-producer            │
│    └── TCP: 0.0.0.0:20001                            │
│  traced_qnx_probes ──→ /data/sock/perfetto-producer  │
│  perfetto (consumer) ──→ /data/sock/perfetto-consumer │
│                    │                                  │
│         ┌─────────┴──────────┐                       │
│         │   vdevpeer-net     │                       │
│         │  (patched .so)     │                       │
│         └─────────┬──────────┘                       │
│                   │ vpctl                             │
├───────────────────┼─────────────────────────────────┤
│    QNX Guest (qvm)│                                  │
│                   │                                  │
│  vtnet0 (10.10.10.2/24) ←── vdev-virtio-net (patched)│
│                                                       │
│  ext2 on devb-ram → /ramfs/sock/ (AF_UNIX)           │
│                                                       │
│  traced_relay ──→ TCP 10.10.10.1:20001               │
│    └── local: /ramfs/sock/perfetto-producer          │
│  traced_qnx_probes ──→ /ramfs/sock/perfetto-producer │
└─────────────────────────────────────────────────────┘
```

## Data Flow

```
QNX Guest                          QNX HV Host
─────────                          ───────────

traced_qnx_probes                  traced_qnx_probes
      │                                  │
      ▼                                  ▼
 AF_UNIX socket                    AF_UNIX socket
 /ramfs/sock/                      /data/sock/
 perfetto-producer                 perfetto-producer
      │                                  │
      ▼                                  ▼
 traced_relay ─── TCP 20001 ───→  traced (--enable-relay-endpoint)
                                         │
                                         ▼
                                   perfetto (consumer)
                                   /data/sock/perfetto-consumer
                                         │
                                         ▼
                                   multivm.pftrace
                                   (unified trace, 2 machine IDs)
```

## Network Topology

```
Internet ←→ QEMU NAT ←→ vtnet0 (10.0.2.15)     [HV Host external access]
                              │
                          QNX io-sock
                              │
             SSH:2241 ←→ sshd (port 22)          [Management access]
                              │
                          vp0 (10.10.10.1/24)     [HV Host peer interface]
                              │
                        vdevpeer-net (patched)
                              │
                        vpctl binding
                              │
                   /dev/qvm/qnx-guest/p2p
                              │
                     vdev-virtio-net (patched)
                              │
                        vtnet0 (10.10.10.2/24)    [Guest interface]
```

## Component Details

### Patched Shared Libraries

Both `vdev-virtio-net.so` and `mods-vdevpeer-net.so` require binary patches to fix a feature bit mismatch bug. The guest negotiates features `0x21` (CSUM + MAC) but `peerfeats 0x3` only allows bits 0-1. The patches NOP out the feature comparison branches that reject the MAC bit.

### AF_UNIX on QNX Guest

QNX guest `/dev/shmem` does not support AF_UNIX sockets. The workaround uses ext2 on a RAM disk:
- `devb-ram` creates a block device
- Pre-formatted ext2 image is written to it
- Mounted at `/ramfs/` — AF_UNIX sockets work here

### traced Configuration

The host `traced` listens on both Unix and TCP sockets simultaneously using comma-separated `PERFETTO_PRODUCER_SOCK_NAME`:
```
/data/sock/perfetto-producer,0.0.0.0:20001
```
- Local probes connect via the Unix socket (fast, reliable)
- Remote `traced_relay` connects via TCP port 20001

### Trace Output

The unified trace contains events from both VMs, distinguished by machine ID:
- Machine ID `0`: HV host (QEMU_virt)
- Machine ID `3419721831`: Guest (ARMv8_Foundation_Model)
