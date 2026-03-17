#!/usr/bin/env python3
"""Merge multiple Perfetto traces with machine_id injection.

Perfetto traces are a sequence of length-delimited protobuf TracePacket messages.
Each TracePacket has field 12 (machine_id) as a uint32.

Wire format:
  - Varint: field_number=11 (0x0b), wire_type=2 (length-delimited) => tag = (11 << 3) | 2 = 0x5a
  - Varint: length of TracePacket
  - TracePacket data

To inject machine_id into each TracePacket:
  - TracePacket field 12 is uint32, wire_type=0 (varint) => tag = (12 << 3) | 0 = 0x60
  - Append: 0x60 + varint(machine_id) to each packet's data
"""
import struct
import sys
import os

def read_varint(data, offset):
    """Read a varint from data at offset. Returns (value, new_offset)."""
    result = 0
    shift = 0
    while offset < len(data):
        b = data[offset]
        offset += 1
        result |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return result, offset
        shift += 7
    raise ValueError("Truncated varint")

def encode_varint(value):
    """Encode a varint."""
    result = bytearray()
    while value > 0x7F:
        result.append((value & 0x7F) | 0x80)
        value >>= 7
    result.append(value & 0x7F)
    return bytes(result)

def inject_machine_id(trace_data, machine_id):
    """Inject machine_id into each TracePacket in a Perfetto trace."""
    output = bytearray()
    offset = 0
    packet_count = 0

    # machine_id field: field 12, wire type 0 (varint) => tag = 0x60
    machine_id_bytes = b'\x60' + encode_varint(machine_id)

    while offset < len(trace_data):
        # Read outer message tag (should be field 11, wire type 2 = 0x5a for Trace.packet)
        tag, new_offset = read_varint(trace_data, offset)
        field_num = tag >> 3
        wire_type = tag & 0x07

        if field_num != 1 or wire_type != 2:
            # Skip non-packet fields (copy as-is)
            # For length-delimited (2), read length and skip
            if wire_type == 2:
                length, new_offset = read_varint(trace_data, new_offset)
                output.extend(trace_data[offset:new_offset + length])
                offset = new_offset + length
            else:
                # Unknown wire type, copy raw byte and continue
                output.extend(trace_data[offset:new_offset])
                offset = new_offset
            continue

        # Read packet length
        packet_len, data_start = read_varint(trace_data, new_offset)
        packet_data = trace_data[data_start:data_start + packet_len]

        # Append machine_id field to packet data
        new_packet_data = packet_data + machine_id_bytes

        # Write tag + new length + new data
        output.extend(encode_varint(tag))
        output.extend(encode_varint(len(new_packet_data)))
        output.extend(new_packet_data)

        offset = data_start + packet_len
        packet_count += 1

    return bytes(output), packet_count

def main():
    if len(sys.argv) < 4:
        print("Usage: merge-traces.py output.pftrace file1:machine_id file2:machine_id ...")
        print("Example: merge-traces.py merged.pftrace host.pftrace:1 guest-qnx.pftrace:2 guest-linux.pftrace:3")
        sys.exit(1)

    output_path = sys.argv[1]
    inputs = sys.argv[2:]

    merged = bytearray()

    for spec in inputs:
        parts = spec.rsplit(':', 1)
        if len(parts) != 2:
            print(f"Error: expected file:machine_id, got: {spec}")
            sys.exit(1)

        filepath, mid_str = parts
        machine_id = int(mid_str)

        with open(filepath, 'rb') as f:
            trace_data = f.read()

        injected, packet_count = inject_machine_id(trace_data, machine_id)
        merged.extend(injected)

        print(f"  {os.path.basename(filepath)}: {len(trace_data)} bytes, {packet_count} packets, machine_id={machine_id}")

    with open(output_path, 'wb') as f:
        f.write(merged)

    print(f"\nMerged trace: {len(merged)} bytes -> {output_path}")

if __name__ == '__main__':
    main()
