#!/usr/bin/env python3
"""Huawei discovery/GATT research; never negotiates a transfer.

Requires bleak. Default output omits names, addresses and advertisement payloads.
An FE35 advertisement is a candidate, not proof of Huawei Share compatibility.
"""

import argparse
import asyncio
import json
import os
from pathlib import Path

FE35 = "0000fe35-0000-1000-8000-00805f9b34fb"
HUAWEI_COMPANY = 0x027D
SHARE_SERVICE = "11c8b310-80e4-4276-afc0-f81590b2177f"


async def scan_and_enumerate(args):
    from bleak import BleakClient, BleakScanner

    candidates = {}
    devices = {}
    packets = 0

    def found(device, advertisement):
        nonlocal packets
        packets += 1
        if FE35 not in advertisement.service_data:
            return
        if HUAWEI_COMPANY not in advertisement.manufacturer_data:
            return
        devices[device.address] = device
        previous = candidates.get(device.address)
        label = previous["label"] if previous else f"candidate-{len(candidates) + 1}"
        candidates[device.address] = {
            "label": label,
            "rssi": advertisement.rssi,
            "service_uuids": advertisement.service_uuids,
            "fe35_bytes": len(advertisement.service_data[FE35]),
            "huawei_manufacturer_bytes": len(advertisement.manufacturer_data[HUAWEI_COMPANY]),
        }

    async with BleakScanner(detection_callback=found):
        await asyncio.sleep(args.seconds)
    result = {
        "scan_seconds": args.seconds,
        "advertisement_callbacks": packets,
        "candidates": list(candidates.values()),
        "transfer_attempted": False,
    }

    if args.private_targets:
        # This opt-in file contains local CoreBluetooth endpoint IDs. Keep it
        # outside tracked docs; no advertisement contents or account IDs saved.
        path = Path(args.private_targets)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w") as file:
            json.dump(candidates, file, indent=2)

    if args.connect_target:
        if args.connect_target not in candidates:
            result["gatt"] = {"status": "target_not_seen_in_current_scan"}
        else:
            # Enumerate only the explicitly selected current endpoint. Reads
            # and subscriptions require the separate --inspect-share opt-in.
            try:
                async with BleakClient(devices[args.connect_target], timeout=15) as client:
                    services = [
                        {
                            "uuid": service.uuid,
                            "characteristics": [
                                {"uuid": char.uuid, "properties": char.properties}
                                for char in service.characteristics
                            ],
                        }
                        for service in client.services
                    ]
                    result["gatt"] = {
                        "status": "connected_and_enumerated",
                        "share_service_present": any(s["uuid"] == SHARE_SERVICE for s in services),
                        "services": services,
                    }
                    if args.inspect_share:
                        result["gatt"]["inspection"] = await inspect_share(client, args.notify_only)
            except Exception as error:
                # Backend exception messages may contain names or addresses.
                result["gatt"] = {"status": "failed", "error_type": type(error).__name__}
    return result


async def inspect_share(client, notify_only=False):
    """Inspect only the share service; never write a protocol payload or pair."""
    service = client.services.get_service(SHARE_SERVICE)
    if service is None:
        return {"status": "share_service_absent"}
    observations = []
    for char in service.characteristics:
        if char.uuid not in (
            "00002b00-0000-1000-8000-00805f9b34fb",
            "00002b01-0000-1000-8000-00805f9b34fb",
        ):
            continue
        record = {"characteristic": char.uuid}
        if "read" in char.properties and not notify_only:
            try:
                value = await asyncio.wait_for(client.read_gatt_char(char), 5)
                # Contents can include identity or cryptographic material.
                record["read"] = {"status": "ok", "bytes": len(value)}
            except Exception as error:
                record["read"] = {"status": "failed", "error_type": type(error).__name__}
        if "notify" in char.properties or "indicate" in char.properties:
            lengths = []
            def notified(_, value, lengths=lengths):
                if len(lengths) < 32:
                    lengths.append(len(value))
            try:
                await asyncio.wait_for(client.start_notify(char, notified), 5)
                try:
                    await asyncio.sleep(3)
                finally:
                    await asyncio.wait_for(client.stop_notify(char), 5)
                record["notifications"] = {"status": "subscribed", "message_lengths": lengths}
            except Exception as error:
                record["notifications"] = {"status": "failed", "error_type": type(error).__name__}
        observations.append(record)
    return {"status": "completed", "characteristics": observations, "protocol_payload_written": False}


async def probe(args):
    if not args.advertise:
        return await scan_and_enumerate(args)
    manager, delegate, advertising = await start_probe_advertisement(args.serve_discovery)
    try:
        result = await scan_and_enumerate(args)
        result["probe_advertisement"] = advertising
        return result
    finally:
        manager.stopAdvertising()
        if args.serve_discovery:
            manager.removeAllServices()


async def start_probe_advertisement(serve_discovery=False):
    """Emit a synthetic discovery hint, without serving a transfer endpoint."""
    import secrets
    from Foundation import NSObject
    from CoreBluetooth import (
        CBPeripheralManager, CBUUID, CBMutableService, CBMutableCharacteristic,
        CBAdvertisementDataLocalNameKey, CBAdvertisementDataServiceUUIDsKey,
    )
    from libdispatch import DISPATCH_QUEUE_SERIAL, dispatch_queue_create

    loop = asyncio.get_running_loop()
    ready = loop.create_future()
    started = loop.create_future()
    service_added = loop.create_future()
    observations = {"read_requests": 0, "write_lengths": [], "subscriptions": 0}

    def resolve(future, value):
        if not future.done():
            future.set_result(value)

    class HuaweiProbeDelegate(NSObject):
        def peripheralManagerDidUpdateState_(self, manager):
            loop.call_soon_threadsafe(resolve, ready, manager.state())

        def peripheralManagerDidStartAdvertising_error_(self, manager, error):
            loop.call_soon_threadsafe(resolve, started, None if error is None else int(error.code()))

        def peripheralManager_didAddService_error_(self, manager, service, error):
            loop.call_soon_threadsafe(resolve, service_added, None if error is None else int(error.code()))

        def peripheralManager_didReceiveReadRequest_(self, manager, request):
            observations["read_requests"] += 1
            # No identity, account data or files are served by this experiment.
            request.setValue_(b"")
            manager.respondToRequest_withResult_(request, 0 if request.offset() == 0 else 7)

        def peripheralManager_didReceiveWriteRequests_(self, manager, requests):
            for request in requests:
                if len(observations["write_lengths"]) < 32:
                    observations["write_lengths"].append(len(bytes(request.value() or b"")))
            if requests:
                manager.respondToRequest_withResult_(requests[0], 0)

        def peripheralManager_central_didSubscribeToCharacteristic_(self, manager, central, characteristic):
            observations["subscriptions"] += 1

    delegate = HuaweiProbeDelegate.alloc().init()
    manager = CBPeripheralManager.alloc().initWithDelegate_queue_options_(
        delegate, dispatch_queue_create(b"androp.huawei.research", DISPATCH_QUEUE_SERIAL), None
    )
    try:
        state = await asyncio.wait_for(ready, 8)
        if state != 5:
            return manager, delegate, {"status": "bluetooth_unavailable", "state": state}
        if serve_discovery:
            service = CBMutableService.alloc().initWithType_primary_(CBUUID.UUIDWithString_(SHARE_SERVICE), True)
            chars = [
                CBMutableCharacteristic.alloc().initWithType_properties_value_permissions_(
                    CBUUID.UUIDWithString_(value), 0x3E, None, 3
                )
                for value in ("2B00", "2B01")
            ]
            service.setCharacteristics_(chars)
            manager.addService_(service)
            service_error = await asyncio.wait_for(service_added, 8)
            if service_error is not None:
                return manager, delegate, {"status": "service_registration_failed", "error_code": service_error}
        # Synthetic per-run identifier, never derived from any user's account.
        identifiers = [f"{secrets.randbelow(65536):04X}" for _ in range(3)]
        manager.startAdvertising_({
            CBAdvertisementDataLocalNameKey: "anDrop H Probe",
            CBAdvertisementDataServiceUUIDsKey: [
                CBUUID.UUIDWithString_(value)
                for value in ["FE35", "933E", *identifiers, "0300"]
            ],
        })
        error_code = await asyncio.wait_for(started, 8)
        result = {"status": "started" if error_code is None else "failed", "error_code": error_code}
        if serve_discovery:
            result["research_gatt_server"] = observations
        return manager, delegate, result
    except BaseException:
        manager.stopAdvertising()
        if serve_discovery:
            manager.removeAllServices()
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--private-targets", help="opt-in private endpoint file, preferably under build/")
    parser.add_argument("--connect-target", help="exact endpoint ID to enumerate, only if observed in this scan")
    parser.add_argument("--inspect-share", action="store_true", help="with --connect-target: bounded reads and notification subscriptions on 2B00/2B01; report lengths only")
    parser.add_argument("--notify-only", action="store_true", help="with --inspect-share: skip reads to test subscriptions on a fresh ATT connection")
    parser.add_argument("--advertise", action="store_true", help="macOS only: temporarily advertise a synthetic research peer")
    parser.add_argument("--serve-discovery", action="store_true", help="with --advertise: expose a temporary empty research GATT service; count requests without saving their values")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 60:
        parser.error("--seconds must be between 1 and 60")
    if args.inspect_share and not args.connect_target:
        parser.error("--inspect-share requires --connect-target")
    if args.notify_only and not args.inspect_share:
        parser.error("--notify-only requires --inspect-share")
    if args.serve_discovery and not args.advertise:
        parser.error("--serve-discovery requires --advertise")
    print(json.dumps(asyncio.run(probe(args)), indent=2))


if __name__ == "__main__":
    main()
