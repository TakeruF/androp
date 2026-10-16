# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

"""macOS live advertisement delivery for presence expiry (Bleak 3.0.2)."""
from CoreBluetooth import CBUUID, CBCentralManagerScanOptionAllowDuplicatesKey
from bleak.backends.corebluetooth.scanner import BleakScannerCoreBluetooth


class LiveScannerCoreBluetooth(BleakScannerCoreBluetooth):
    async def start(self):
        await super().start()
        # Bleak installs its callbacks, then starts with Apple's default duplicate
        # filtering. Update this scan to deliver ongoing advertisements as well.
        # Keep this adapter local; do not patch the installed Bleak package.
        try:
            services=[CBUUID.UUIDWithString_(value) for value in self._service_uuids] if self._service_uuids else None
            self._manager.central_manager.scanForPeripheralsWithServices_options_(
                services, {CBCentralManagerScanOptionAllowDuplicatesKey: True})
        except BaseException:
            await super().stop()
            raise
