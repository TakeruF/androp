#!/usr/bin/env python3
"""Bounded, unicast Huawei LAN discovery research using macOS nc.

No pairing, authentication, file transfer, hotspot or system route changes.
Only protocol metadata is printed; peer identities and payloads are omitted.
"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Sources"))
from network_routes import interfaces, private_ipv4

# OpenHarmony communication_dsoftbus: interfaces/kits/lnn/lnn_device_info_struct.h
# TYPE_PC_ID. This declaration alone does not prove the Huawei Share UI classification.
DEVICE_TYPE_PC = 0x0C


def discovery_packet(source, message_id, token):
    if len(message_id) != 2 or len(token) != 2:
        raise ValueError("CoAP message ID and token must each be two bytes")
    payload = {
        "deviceId": json.dumps({"UDID": secrets.token_hex(32).upper()}, separators=(",", ":")),
        "devicename": "anDrop H Probe", "type": DEVICE_TYPE_PC, "hicomversion": "",
        "mode": 1, "deviceHash": "", "serviceData": "",
        "extendServiceData": "osType:2,nbVer:9,rssi:-58,abl:8",
        "wlanIp": source, "capabilityBitmap": [256],
        "coapUri": f"coap://{source}:5684/device_discover", "bType": 5, "seqNo": 1,
    }
    # CON POST; Uri-Path (11), Content-Format (12, application/json = 50).
    return (b"\x42\x02" + message_id + token
            + b"\xbd\x02device_discover\x11\x32\xff"
            + json.dumps(payload, separators=(",", ":")).encode())


def summarize_capture(raw, message_id):
    """nc concatenates datagrams: extract JSON records, not UDP boundaries.

    An ACK and a discovery record are separate observations. Neither establishes
    an authenticated identity, even if a returned name resembles the test phone.
    """
    if len(raw) > 65536:
        raise ValueError("Discovery response exceeded research capture limit")
    summary = {"response_bytes": len(raw), "discovery_records": []}
    ports = set()
    if len(raw) >= 4 and raw[0] >> 6 == 1:
        summary["first_coap_header"] = {
            "type": (raw[0] >> 4) & 3,
            "code": f"{raw[1] >> 5}.{raw[1] & 31:02d}",
            "message_id_matches": raw[2:4] == message_id,
        }
    cursor = 0
    while cursor < len(raw) and len(summary["discovery_records"]) < 16:
        start = raw.find(b"{", cursor)
        if start < 0:
            break
        text = raw[start:].decode("utf-8", errors="replace")
        try:
            value, end = json.JSONDecoder().raw_decode(text)
        except ValueError:
            cursor = start + 1
            continue
        cursor = start + len(text[:end].encode("utf-8"))
        if not isinstance(value, dict) or not {"deviceId", "serviceData", "wlanIp"} <= value.keys():
            continue
        service_data = value.get("serviceData")
        match = re.search(r"(?:^|,)\s*port:(\d+)(?:,|$)", service_data) if isinstance(service_data, str) else None
        port = int(match[1]) if match else 0
        if not 1 <= port <= 65535:
            port = 0
        if port:
            ports.add(port)
        summary["discovery_records"].append({
            "known_fields": sorted(set(value) & {
                "deviceId", "devicename", "type", "mode", "deviceHash", "serviceData",
                "extendServiceData", "wlanIp", "capabilityBitmap", "bType", "bData", "seqNo",
            }),
            "service_port_present": bool(port),
        })
    return summary, sorted(ports)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer-ip", required=True, help="explicit test device WLAN IPv4 address")
    parser.add_argument("--interface", default="en0")
    parser.add_argument("--private-endpoint", type=Path, help="optional mode-0600 file of advertised ports; not identity data")
    args = parser.parse_args()
    if sys.platform != "darwin" or not private_ipv4(args.peer_ip):
        parser.error("Use macOS and a private test-device IPv4 address")
    source = next((x for x in interfaces() if x.interface == args.interface and ipaddress.ip_address(args.peer_ip) in x.network), None)
    if source is None or args.peer_ip == source.address:
        parser.error("Peer must be another device on the selected active LAN subnet")
    message_id = secrets.token_bytes(2)
    packet = discovery_packet(source.address, message_id, secrets.token_bytes(2))
    command = ["/usr/bin/nc", "-u", "-s", source.address, "-p", "5684", "-w", "2", args.peer_ip, "5684"]
    try:
        result = subprocess.run(command, input=packet, capture_output=True, timeout=5)
        raw, status = result.stdout, "exited" if result.returncode == 0 else "transport_failed"
    except subprocess.TimeoutExpired as error:
        # Retransmitted CON responses can keep nc's idle timer alive.
        raw, status = error.stdout or b"", "capture_deadline"
    try:
        summary, ports = summarize_capture(raw, message_id)
    except ValueError:
        summary, ports = {"status": "capture_limit_exceeded"}, []
    summary.update(transport_status=status, authentication_attempted=False, transfer_attempted=False)
    if args.private_endpoint and ports:
        fd = os.open(args.private_endpoint, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump({"ip": args.peer_ip, "advertised_ports": ports}, file, indent=2)
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
