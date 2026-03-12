# Perfetto Multi-VM Tracing via vsock (Online Relay)

**Target:** Host Linux + AGL QEMU guest, single `.pftrace` file, no offline merge  
**Perfetto version:** v54.0  
**Kernel requirement:** Host needs `vhost_vsock` module; Guest needs `CONFIG_VIRTIO_VSOCKETS=y`  
**Tested on:** Ubuntu (6.14.0-nvidia, aarch64) + AGL Terrific Trout (6.6.84-yocto-standard, virtio-aarch64)

---

## Architecture

```
Host                                    Guest (QEMU)
─────────────────────────────────────   ─────────────────────────────
traced (v54)                            traced_relay (v54)
  ├─ UNIX:/tmp/pf-producer              │  ├─ UNIX:/tmp/perfetto-producer (listen)
  ├─ vsock://ANY:20001 (listen) ◄────── │  └─ vsock://2:20001 (connect to host)
  └─ UNIX:/tmp/pf-consumer              │
                                        traced_probes (v54)
traced_probes (v54)                       └─ UNIX:/tmp/perfetto-producer (connect)
  └─ UNIX:/tmp/pf-producer (connect)
```

Data flow:  
`perfetto CLI → host traced → [SetupDataSource] → relay (vsock) → guest traced_probes → ftrace/procstats → CommitData → relay (vsock) → host traced → output .pftrace`

---

## Step 0: Binaries

```bash
# Download Perfetto v54.0 linux-arm64 (tracebox bundles traced + traced_probes + traced_relay)
wget https://github.com/google/perfetto/releases/download/v54.0/linux-arm64.zip -O /tmp/pf-v54-arm64.zip
unzip /tmp/pf-v54-arm64.zip -d /tmp/pf-v54/
chmod +x /tmp/pf-v54/*

# Copy tracebox to guest (after QEMU is up)
scp -P 2223 /tmp/pf-v54/tracebox root@127.0.0.1:/tmp/tracebox54
```

---

## Step 1: QEMU with vsock

QEMU must be launched with `-device vhost-vsock-device,guest-cid=3`.

```bash
# Host: load vhost_vsock kernel module
sudo modprobe vhost_vsock
ls /dev/vhost-vsock   # should exist, crw-rw---- kvm group

# Make sure your user is in kvm group
sudo usermod -aG kvm $USER  # then re-login

# Example QEMU launch (add vsock to your existing command)
qemu-system-aarch64 \
  -machine virt -cpu cortex-a57 -m 2G -smp 4 \
  -drive file=/tmp/agl-minimal-run.ext4,format=raw \
  -netdev user,id=net0,hostfwd=tcp::2223-:22 \
  -device virtio-net-device,netdev=net0 \
  -device vhost-vsock-device,guest-cid=3 \     # ← ADD THIS
  -nographic
```

**Verify guest vsock:**
```bash
# SSH into guest, check virtio devices
ssh -p 2223 root@127.0.0.1
cat /sys/bus/virtio/devices/virtio0/device   # should be 0x0013 (VIRTIO_ID_VSOCK=19)
ls /dev/vsock                                 # should exist

# Quick connectivity test (python3)
python3 -c "import socket; s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM); s.connect((2,20001)); print('ok'); s.close()"
# Expected: connection refused (host traced not started yet) - but no error about vsock itself
```

**Verify host vsock:**
```bash
# Check QEMU is holding /dev/vhost-vsock
sudo ls -la /proc/$(pgrep qemu)/fd | grep vhost-vsock
```

---

## Step 2: Start Host traced (with relay endpoint)

Must run as **root** for vsock port binding.

```bash
sudo bash << 'EOF'
# Kill any existing
pkill -f "pf-v54/traced" 2>/dev/null
pkill -f "pf-v54/traced_probes" 2>/dev/null
sleep 1

# Remove stale sockets
rm -f /tmp/pf-producer /tmp/pf-consumer

# Start traced - listen on UNIX (local) AND vsock (relay)
PERFETTO_PRODUCER_SOCK_NAME="/tmp/pf-producer,vsock://4294967295:20001" \
PERFETTO_CONSUMER_SOCK_NAME="/tmp/pf-consumer" \
  /tmp/pf-v54/traced --enable-relay-endpoint \
  >> /tmp/traced-live.log 2>&1 &

sleep 1

# Open consumer socket to non-root users
chmod 666 /tmp/pf-consumer

# Start host traced_probes (local)
/tmp/pf-v54/traced_probes \
  --producer-socket /tmp/pf-producer \
  >> /tmp/probes-live.log 2>&1 &

echo "Host traced PID: $(pgrep -f 'pf-v54/traced$')"
echo "Host probes PID: $(pgrep -f 'pf-v54/traced_probes')"
EOF
```

**Verify:**
```bash
# Check vsock is listening
ss --vsock -lnp | grep 20001
# Expected: v_str LISTEN ... *:20001

tail -3 /tmp/traced-live.log
# Expected: Started traced, listening on /tmp/pf-producer,vsock://4294967295:20001 /tmp/pf-consumer
```

---

## Step 3: Start Guest traced_relay + traced_probes

SSH into guest:

```bash
ssh -p 2223 root@127.0.0.1
```

```bash
# Kill any existing
pkill -f tracebox54 2>/dev/null
sleep 1

# Start traced_relay → forwards to host (CID=2 is always the host from guest perspective)
PERFETTO_RELAY_SOCK_NAME="vsock://2:20001" \
  /tmp/tracebox54 traced_relay \
  >> /tmp/relay.log 2>&1 &

sleep 1

# Start traced_probes → connects to local relay
PERFETTO_PRODUCER_SOCK_NAME="/tmp/perfetto-producer" \
  /tmp/tracebox54 traced_probes \
  >> /tmp/probes.log 2>&1 &

echo "relay PID: $(pgrep -f 'tracebox54' | head -1)"
echo "probes PID: $(pgrep -f 'tracebox54' | tail -1)"
```

**Verify vsock connection from host:**
```bash
# On HOST - confirm vsock ESTAB connections to guest CID=3
ss --vsock -np | grep 3:
# Expected: two ESTAB lines (one RelayClient IPC, one SocketRelayHandler)
```

**Verify producers registered on host traced:**
```bash
# On HOST
PERFETTO_CONSUMER_SOCK_NAME=/tmp/pf-consumer \
  /tmp/pf-v54/perfetto --query 2>/dev/null | grep -A3 "PRODUCER PROCESSES"
# Expected: see both local traced_probes AND remote (relay) traced_probes
```

---

## Step 4: Record Trace

**CRITICAL: Must include `trace_all_machines: true`**

This is a Perfetto v54 breaking change. Without it, remote machine (relay) producers are silently filtered out.  
Source: `tracing_service_impl.cc`:
```cpp
} else if (!tracing_session->config.trace_all_machines() && !is_host_machine) {
    // Default in v54: only trace host machine
    return nullptr;
}
```

```bash
# On HOST (as regular user if /tmp/pf-consumer is chmod 666)
PERFETTO_CONSUMER_SOCK_NAME="/tmp/pf-consumer" \
  /tmp/pf-v54/perfetto -c - --txt -o /tmp/multivm.pftrace << 'EOF'
duration_ms: 10000
trace_all_machines: true          # ← REQUIRED for multi-machine tracing in v54+

buffers: { size_kb: 131072 fill_policy: DISCARD }

data_sources: {
  config {
    name: "linux.ftrace"
    ftrace_config {
      ftrace_events: "sched/sched_switch"
      ftrace_events: "sched/sched_wakeup"
      ftrace_events: "power/cpu_frequency"
      buffer_size_kb: 4096
    }
  }
}

data_sources: {
  config {
    name: "linux.process_stats"
    process_stats_config {
      scan_all_processes_on_start: true
      proc_stats_poll_ms: 1000
    }
  }
}
EOF
```

---

## Step 5: Verify Result

```bash
# Quick check via trace_processor_shell
echo "SELECT id, release, num_cpus FROM machine;" | \
  /tmp/pf-v54/trace_processor_shell /tmp/multivm.pftrace

# Expected:
# id  release                num_cpus
# 0   6.14.0-1015-nvidia     20
# 1   6.6.84-yocto-standard  4

echo "SELECT machine_id, COUNT(*) FROM sched_slice ss JOIN thread t ON ss.utid=t.utid GROUP BY t.machine_id;" | \
  /tmp/pf-v54/trace_processor_shell /tmp/multivm.pftrace
# Both machines should have sched events > 0
```

Open in **https://ui.perfetto.dev** → drag and drop `.pftrace` file.

---

## Troubleshooting

### "Wrote 0 bytes" / guest data empty
→ Missing `trace_all_machines: true` in trace config (v54 breaking change)

### traced_relay starts but doesn't connect to host
→ Check: is host traced running as root? (`sudo bash` required for vsock bind)  
→ Check: vsock://2:20001 (CID=2 = VMADDR_CID_HOST, always points to host from guest)  
→ Do NOT use `vsock://4294967295:20001` for guest-side (that's for host-side listen only)

### vsock permission denied
→ Host: `sudo modprobe vhost_vsock`  
→ QEMU user must be in `kvm` group: `ls -la /dev/vhost-vsock` should show `kvm` group  

### "parts.size() == 2" crash in traced
→ Do NOT use `*vsock://` prefix — it's undocumented and crashes traced  
→ Use `vsock://4294967295:20001` (VMADDR_CID_ANY) for host bind

### Consumer socket permission denied
→ `sudo chmod 666 /tmp/pf-consumer` after starting traced as root

### Guest CID shows 4294967295 instead of 3
→ This is a quirk of some kernel versions — the actual connection still works  
→ The assigned CID (3) is what matters; the ioctl may return VMADDR_CID_ANY depending on driver state  
→ Verify actual connectivity: `python3 -c "import socket; s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM); s.settimeout(2); s.connect((2,20001))"` (should fail with ConnectionRefused if host traced not up, NOT with OSError)

---

## Notes on Clock Sync

`traced_relay` does automatic clock synchronization via `SyncClock` IPC (every 30s).  
It correlates `CLOCK_BOOTTIME` between host and guest.  
No manual offset calculation needed — all timestamps in the output `.pftrace` are in the same timebase.

In ui.perfetto.dev, both machines appear in the timeline. The QEMU vCPU threads on the host (e.g., `qemu-system-aar [<vcpu-tid>]`) correspond to guest CPU execution. The QEMU main thread is the event loop, not a vCPU.

---

## File Paths (this setup)

| Path | Description |
|---|---|
| `/tmp/pf-v54/traced` | Host Perfetto traced daemon |
| `/tmp/pf-v54/traced_probes` | Host data source collector |
| `/tmp/pf-v54/perfetto` | CLI for recording/querying |
| `/tmp/pf-v54/trace_processor_shell` | SQL query tool |
| `/tmp/tracebox54` | Guest all-in-one binary (relay + probes) |
| `/tmp/traced-live.log` | Host traced log |
| `/tmp/pf-producer` | Host producer UNIX socket |
| `/tmp/pf-consumer` | Host consumer UNIX socket |
| `/tmp/relay.log` | Guest relay log |
| `/tmp/probes.log` | Guest probes log |
