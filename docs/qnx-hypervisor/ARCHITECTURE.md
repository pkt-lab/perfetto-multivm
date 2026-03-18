# Multi-VM Perfetto Relay Architecture

## System Diagram (3-VM: QNX Host + QNX Guest + Linux Guest)

```
┌──────────────────────────────────────────────────────────┐
│                    gb10 Host (Linux x86_64)                │
│  QEMU 9.2.3 (virt-4.2, cortex-a57, smp 4, 2G)           │
│  SSH: localhost:2241 → QNX HV:22                          │
├──────────────────────────────────────────────────────────┤
│              QNX 8.0 HV Host (procnto-smp-instr)          │
│                                                            │
│  io-sock ─── vtnet0 (10.0.2.15, QEMU NAT)                │
│         ├── vp0 (10.10.10.1/24) ←→ Linux guest            │
│         └── vp1 (10.10.10.1/24) ←→ QNX guest              │
│                                                            │
│  traced (--enable-relay-endpoint)                          │
│    ├── Unix: /data/sock/perfetto-producer                 │
│    └── TCP: 0.0.0.0:20001                                 │
│  traced_qnx_probes ──→ /data/sock/perfetto-producer       │
│  perfetto (consumer) ──→ /data/sock/perfetto-consumer      │
│                                                            │
│         ┌───────────────────────────────┐                  │
│         │     vdevpeer-net (patched)    │                  │
│         │   vp0 ←→ Linux   vp1 ←→ QNX  │                  │
│         └───────────┬───────────┬───────┘                  │
│                     │           │                           │
├─────────────────────┼───────────┼──────────────────────────┤
│  Linux Guest (qvm)  │           │  QNX Guest (qvm)         │
│  AGL 6.6.84 kernel  │           │  QNX 8.0 IFS             │
│                     │           │                           │
│  eth0 10.10.10.3/24 │           │  vtnet0 10.10.10.2/24    │
│                     │           │                           │
│  traced_relay ──────┼── TCP ────┼──→ host:20001            │
│  traced_probes      │           │  traced_relay ──→ :20001  │
│  (linux.ftrace)     │           │  traced_qnx_probes       │
│                     │           │  (qnx.kernel)             │
│  Workloads:         │           │                           │
│   cpu_arith, mem,   │           │  ext2 on devb-ram         │
│   io_builtin, net,  │           │  /ramfs/sock/ (AF_UNIX)   │
│   io_periodic       │           │                           │
└─────────────────────┴───────────┴──────────────────────────┘
```

## Data Flow (3-VM Unified Trace)

```
Linux Guest              QNX Guest                   QNX HV Host
────────────             ──────────                  ───────────

traced_probes            traced_qnx_probes           traced_qnx_probes
(linux.ftrace)           (qnx.kernel)                (qnx.kernel)
      │                        │                           │
      ▼                        ▼                           ▼
 /tmp/perfetto-          AF_UNIX socket              AF_UNIX socket
  producer               /ramfs/sock/                /data/sock/
      │                  perfetto-producer           perfetto-producer
      ▼                        │                           │
 traced_relay                  ▼                           │
      │                  traced_relay                      │
      │                        │                           │
      └──── TCP 20001 ────────┘──── TCP 20001 ───→  traced
                                                    (--enable-relay-endpoint)
                                                          │
                                                          ▼
                                                    perfetto (consumer)
                                                    /data/sock/perfetto-consumer
                                                          │
                                                          ▼
                                                    3vm.pftrace
                                                    (unified trace, 3 machine IDs)
```

## Network Topology

```
Internet ←→ QEMU NAT ←→ vtnet0 (10.0.2.15)        [HV Host external access]
                              │
                          QNX io-sock
                              │
             SSH:2241 ←→ sshd (port 22)             [Management access]
                              │
                 ┌────────────┴────────────┐
                 │                         │
           vp0 (10.10.10.1)         vp1 (10.10.10.1)
                 │                         │
           vdevpeer-net              vdevpeer-net
                 │                         │
           Linux guest               QNX guest
           eth0 10.10.10.3          vtnet0 10.10.10.2
```

**Important**: Both vp0 and vp1 share the same subnet (10.10.10.0/24). The HV host needs explicit routes:
```bash
/system/bin/route add -host 10.10.10.2 -iface vp1
/system/bin/route add -host 10.10.10.3 -iface vp0
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

The unified trace contains events from all VMs, distinguished by machine ID:
- Machine ID `0`: QNX HV host (QEMU_virt)
- Machine ID `1`: Linux guest (AGL 6.6.84)
- Machine ID `2`: QNX guest (ARMv8_Foundation_Model)

Machine IDs are assigned by the trace processor based on `trusted_packet_sequence_id` and remote clock domains.

### Separate Trace Buffers

Using a single ring buffer causes data loss: QNX kernel events (~470K sched events/min) overwrite Linux ftrace data. The solution is separate buffers:
- Buffer 0 (128MB): QNX kernel events (`qnx.kernel` data source)
- Buffer 1 (64MB): Linux ftrace + process stats

See `configs/multivm-3vm.pbtxt` for the reference config.

### Thread Naming on QNX

QNX threads don't inherently have names (unlike Linux). Thread-process association is achieved by:
1. Emitting `GenericKernelProcessTree` events on first sched event for each thread
2. Emitting process tree on thread rename (`HandleThreadNamed`)
3. Setting `comm` field on `GenericKernelTaskStateEvent` entries
4. Not skipping processes without `cmdline` in the trace processor

These fixes are in pkt-lab/perfetto branch `qnx-main` (commit `b982fdcd82`).

### Linux Guest Workload Design

The Linux guest init v8 uses in-process workloads to avoid flooding the trace with short-lived processes:
- **cpu_arith**: Shell arithmetic loops (no fork/exec)
- **mem_work**: Shell variable manipulation
- **io_builtin**: `read` builtin for /proc files (no `cat`)
- **net_slow**: One `ping` every 5s
- **io_periodic**: One `dd` every 10s

Previous versions (v6/v7) spawned `seq`, `cat`, `grep`, `wc`, `ps` rapidly, creating thousands of zombie process entries in the trace.
