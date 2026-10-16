# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors

"""Optional display metadata for the physically examined 3333 format.

Unknown formats remain unknown. These advertised fields are not authentication.
"""

def parse_peer_metadata(identity):
    if not isinstance(identity, str) or len(identity) > 128:
        return {}
    fields = identity.split('-')
    if len(fields) != 6 or fields[1] not in ('r', 'sr') or fields[4] != '11':
        return {}
    if not fields[5].isascii() or not fields[5].isdecimal():
        return {}
    flags = int(fields[5])
    if not 0 <= flags <= 255:
        return {}
    # Bit meanings are specific to this format, not the other alliance formats.
    brand_bits = flags & 0x18
    brand = {0x08: 'OPPO', 0x10: 'realme'}.get(brand_bits)
    if brand is None:
        return {}
    return {'brand': brand, 'kind': 'tablet' if flags & 0x02 else 'phone'}


def peer_identifier(identity, fallback):
    """Keep one recipient when its Bluetooth address rotates within discovery.

    This is a self-reported identifier, not a trust or authorization decision.
    """
    if not isinstance(identity, str):
        return fallback
    fields = identity.split('-')
    if len(fields) != 6 or fields[1] not in ('r', 'sr') or fields[4] != '11':
        return fallback
    identifier = fields[0].lower()
    if len(identifier) != 12 or any(c not in '0123456789abcdef' for c in identifier) or identifier == '0' * 12:
        return fallback
    return 'mta11:' + identifier
