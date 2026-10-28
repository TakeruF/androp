"""Offline OShare 17.2.36 native-P2P research helpers; no device/network I/O.

These are source-derived encodings, NOT evidence of phone interoperability.
Never print dataclass instances: handover messages contain Wi-Fi credentials.
No account identifiers, trusted-device assertions, or auto-approval are emitted.

Primary decoded sources (work/oshare-source/sources):
  k9/c.java: native UUIDs; ble/impl/j.java:282, 1987: GO/approval writes;
  ble/impl/w.java:942, 1050, 2186, 2508: state gate/GO response;
  utils/b0.java:62, 273, 376: ECDH and native AES/CTR (NOT iOS CBC);
  mb/f.java:40-65, mb/d.java:101: TCP framing; pb/a.java:47: args.

Bounded physical experiment (operator must execute separately):
  * Native service is 9999; read9996 marks the connection native. Existing
    Apple advertisements/9898 read do not establish this native path.
  * On the tested OPPO/OShare 17.2.36, native connection and read 9996 (version 3)
    succeeded, but 9989 exposes READ|WRITE (properties 10), no notify bit and no
    CCCD (only custom descriptor 9988). CoreBluetooth setNotifyValue(true) on
    9989 returned isNotifying=false / CBATTErrorDomain 6 (requestNotSupported).
    The Android source registers 9985/9989 locally and sends notifications on
    those same characteristics despite their properties; there is no mux via
    9997. A public macOS API workaround has not been established. This result
    does not establish that every native OShare transport is impossible.
  * The source-derived request 9989 is 11&BTMAC&1; this asks the GATT server to
    be Wi-Fi GO, not a transfer direction. One physical request was acknowledged
    but yielded no handover; P2P stayed disabled. The phone logged
    '5G device should not go' during that trial: its is5GBandAvailable guard
    returned before GO creation. This refers to Wi-Fi 5 GHz, not cellular 5G.
    With no GO reply emitted, that trial does not establish whether an
    unsolicited notification would reach CoreBluetooth without registration.
  * Alternatively an actual phone sender may read a Mac GATT9996, write9985
    approval metadata, then offer its own GO over9986. Native discovery needs
    serviceData3333 AND3334 (o.java:100); public CoreBluetooth cannot simply
    replace this with8881 (which selects Apple's file-only route).
  * Stop after the first real handover/transport evidence. No fabricated MAC,
    account, SSID, accept reply, or HTTP fallback. A TCP command1 offer still
    requires genuine user approval before command2. Two native TCP sessions
    are used: auxiliary session opens with command0/empty/flag1.
"""

from __future__ import annotations

import base64
from dataclasses import dataclass, field
import json
import re
import struct

UUID_BASE = "0000{}-0000-1000-8000-00805f9b34fb"
UUIDS = {name: UUID_BASE.format(short) for name, short in {
    "service": "9999", "native_read": "9996", "approval": "9985",
    "request_go": "9989", "start_wps": "9986", "start": "9990",
    "cancel": "9995", "log": "9984", "discovery": "3333",
    "discovery_name": "3334",
}.items()}
BLE_SEPARATOR = "&"
ARG_SEPARATOR = "&&_&&"
MAX_BLE_BYTES = 4096
MAX_BODY_BYTES = 65536
CTR_IV = b"0102030405060708"


class ProtocolError(ValueError):
    """Invalid/unsupported synthetic or observed framing (never echo payload)."""


def _text(data: bytes, limit: int = MAX_BLE_BYTES) -> str:
    if not isinstance(data, bytes) or len(data) > limit:
        raise ProtocolError("invalid payload size")
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeError as error:
        raise ProtocolError("invalid UTF-8") from error
    if "\x00" in text:
        raise ProtocolError("embedded NUL")
    return text


def _mac(value: str) -> str:
    if not re.fullmatch(r"(?:[0-9A-Fa-f]{12}|(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2})", value):
        raise ProtocolError("invalid MAC format")
    return value.replace(":", "").upper()


@dataclass(frozen=True, repr=False)
class NativeRead:
    mac: str
    version: int
    public_key: str | None = None
    ack_flag: str | None = None
    preview_flag: str | None = None
    proof: dict | None = field(default=None, repr=False)


def parse_native_read(data: bytes) -> NativeRead:
    """Read9996; optional proof is parsed, NOT verified/trusted by this helper."""
    parts = _text(data).split(BLE_SEPARATOR)
    if len(parts) not in (2, 5, 6) or not parts[1].isdigit():
        raise ProtocolError("unsupported native read fields")
    mac = _mac(parts[0])
    version = int(parts[1])
    if not 1 <= version <= 11:
        raise ProtocolError("unsupported native version")
    if len(parts) == 2:
        return NativeRead(mac, version)
    try:
        raw_key = base64.b64decode(parts[2], validate=True)
        proof = json.loads(parts[5]) if len(parts) == 6 else None
    except (ValueError, TypeError) as error:
        raise ProtocolError("invalid key/proof encoding") from error
    if not 32 <= len(raw_key) <= 512 or parts[3:5] != ["1", "1"]:
        raise ProtocolError("unsupported native capability fields")
    if proof is not None and (not isinstance(proof, dict) or set(proof) != {"sign", "salt", "info"}
                              or any(not isinstance(value, str) for value in proof.values())):
        raise ProtocolError("unsupported native proof fields")
    return NativeRead(mac, version, parts[2], parts[3], parts[4], proof)


def encode_go_request(bluetooth_mac: str, random_port: bool = True) -> bytes:
    """j.java:282 exact current client request. Actual local MAC required."""
    return f"11&{_mac(bluetooth_mac)}&{int(random_port)}".encode("ascii")


@dataclass(frozen=True, repr=False)
class GoHandover:
    mac: str
    version: int
    frequency: int
    ssid: str | None = None
    psk: str | None = field(default=None, repr=False)
    port: int = 8959


def parse_go_handover(data: bytes) -> GoHandover:
    """Complete accumulated9989 notification; no secrets in repr/errors."""
    parts = _text(data).split(BLE_SEPARATOR)
    if len(parts) not in (2, 4, 5) or not re.fullmatch(r"[0-9A-Fa-f]{12}3", parts[0]):
        raise ProtocolError("unsupported GO fields")
    if not parts[1].isdigit() or not 2000 <= int(parts[1]) <= 7125:
        raise ProtocolError("invalid GO frequency")
    port = 8959
    if len(parts) == 5:
        if not parts[4].isdigit() or not 1 <= int(parts[4]) <= 65535:
            raise ProtocolError("invalid GO port")
        port = int(parts[4])
    if len(parts) >= 4 and (not 1 <= len(parts[2].encode()) <= 32 or not 8 <= len(parts[3]) <= 63):
        raise ProtocolError("invalid GO credentials")
    return GoHandover(_mac(parts[0][:-1]), 3, int(parts[1]),
                      parts[2] if len(parts) >= 4 else None,
                      parts[3] if len(parts) >= 4 else None, port)


def java_length(text: str) -> int:
    return len(text.encode("utf-16-be")) // 2


def _length_prefix(text: str) -> bytes:
    # Exactly Java's formula, including its decimal-boundary quirk.
    size = java_length(text)
    return f"{size + len(str(size)) + 1}&{text}".encode("utf-8")


@dataclass(frozen=True, repr=False)
class WpsHandover:
    mac_or_ciphertext: str
    frequency: int
    communication_version: int
    bluetooth_mac: str
    ssid_or_ciphertext: str
    psk_or_ciphertext: str = field(repr=False)
    public_key: str | None = field(default=None, repr=False)
    port: int = 8959


def parse_start_wps(data: bytes) -> WpsHandover:
    """Complete9986 write (including length prefix), j.j1()/OShareServer.g().

    Encrypted fields remain encrypted; native_shared_secret/native_ctr can
    decode them with the actual ephemeral server key, never an account key.
    Calling this does not connect, trust, approve, or claim successful receipt.
    """
    text = _text(data)
    prefix, separator, body = text.partition("&")
    if not separator or not prefix.isdigit() or int(prefix) != java_length(text):
        raise ProtocolError("incomplete WPS handover")
    parts = body.split("&")
    if len(parts) not in (7, 10) or not parts[0].endswith("3"):
        raise ProtocolError("unsupported WPS handover fields")
    if not parts[1].isdigit() or not 2000 <= int(parts[1]) <= 7125 or parts[2] != "11":
        raise ProtocolError("unsupported WPS version/frequency")
    peer_key = parts[6] if parts[6] not in ("", "null") else None
    if not peer_key:
        _mac(parts[0][:-1])
    else:
        try:
            if len(base64.b64decode(peer_key, validate=True)) > 512:
                raise ValueError()
        except ValueError as error:
            raise ProtocolError("invalid WPS key") from error
    port = 8959
    if len(parts) == 10:
        if not parts[7].isdigit() or not 1 <= int(parts[7]) <= 65535 or parts[8] not in ("true", "false") or parts[9] not in ("0", "1"):
            raise ProtocolError("unsupported WPS port/flags")
        port = int(parts[7])
    return WpsHandover(parts[0][:-1], int(parts[1]), 11, _mac(parts[3]),
                       parts[4], parts[5], peer_key, port)


def encode_approval_metadata(sender_name: str, mime: str = "text/plain", count: int = 1) -> bytes:
    """Protocol>=6 metadata with empty account/key/avatar/thumbnail/contact.

    This merely requests approval. It MUST NOT be treated as peer acceptance.
    Fields including length: length,count,communication11,name,key,account,
    avatar,mime,filename,thumbnailLength,contactHash. No payload content here.
    """
    for value in (sender_name, mime):
        if not value or any(c in value for c in "&\x00\r\n"):
            raise ProtocolError("invalid approval field")
    if len(sender_name.encode()) > 128 or len(mime.encode()) > 128 or not 1 <= count <= 100:
        raise ProtocolError("approval field too large")
    return _length_prefix("&".join([str(count), "11", sender_name, "", "", "", mime, "", "0", ""]))


def decode_approval_result(data: bytes) -> str:
    # android.util.Base64.DEFAULT emits a trailing LF (and wraps long values).
    if len(data) > 64:
        raise ProtocolError("invalid approval result size")
    try:
        value = base64.b64decode(data.replace(b"\r", b"").replace(b"\n", b""), validate=True)
    except ValueError as error:
        raise ProtocolError("invalid approval result") from error
    if value not in (b"ok", b"no"):
        raise ProtocolError("unsupported approval result")
    return value.decode("ascii")


@dataclass(frozen=True, repr=False)
class NativeCommand:
    command: int
    text: str
    flag: int = 0


def encode_command(command: int, text: str = "", flag: int = 0) -> bytes:
    if not 0 <= command <= 0x7fffffff or flag not in (0, 1):
        raise ProtocolError("invalid command/flag")
    value = text.encode("utf-8", errors="strict")
    if len(value) > MAX_BODY_BYTES - 12:
        raise ProtocolError("command too large")
    return struct.pack(">iiqii", 1001, 4096, len(value) + 12, command, len(value)) + value + struct.pack(">i", flag)


class CommandDecoder:
    """Incremental command-only parser; rejects files/heartbeats/oversize early."""

    def __init__(self):
        self._buffer = bytearray()

    def feed(self, chunk: bytes) -> list[NativeCommand]:
        if len(chunk) + len(self._buffer) > MAX_BODY_BYTES * 2:
            raise ProtocolError("input buffer too large")
        self._buffer.extend(chunk)
        result = []
        while len(self._buffer) >= 16:
            magic, kind, size = struct.unpack_from(">iiq", self._buffer)
            if magic != 1001 or kind != 4096 or not 12 <= size <= MAX_BODY_BYTES:
                raise ProtocolError("unsupported native header")
            if len(self._buffer) < size + 16:
                break
            command, length = struct.unpack_from(">ii", self._buffer, 16)
            if length != size - 12 or command < 0:
                raise ProtocolError("invalid native body length")
            flag, = struct.unpack_from(">i", self._buffer, 24 + length)
            if flag not in (0, 1):
                raise ProtocolError("unsupported native flag")
            text = _text(bytes(self._buffer[24:24 + length]), MAX_BODY_BYTES)
            result.append(NativeCommand(command, text, flag))
            del self._buffer[:size + 16]
        return result

    def finish(self) -> None:
        if self._buffer:
            raise ProtocolError("truncated native frame")


def native_keypair() -> tuple[bytes, str]:
    """Return private PKCS8 DER, public X509 DER/Base64; keep private in RAM."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    key = ec.generate_private_key(ec.SECP256R1())
    private = key.private_bytes(serialization.Encoding.DER, serialization.PrivateFormat.PKCS8,
                                serialization.NoEncryption())
    public = key.public_key().public_bytes(serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    return private, base64.b64encode(public).decode("ascii")


def native_shared_secret(private_der: bytes, peer_public_b64: str) -> bytes:
    """Source-derived Java ECDH TlsPremasterSecret equivalent for P256."""
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    if len(private_der) > 1024 or len(peer_public_b64) > 1024:
        raise ProtocolError("key too large")
    try:
        private = serialization.load_der_private_key(private_der, password=None)
        public = serialization.load_der_public_key(base64.b64decode(peer_public_b64, validate=True))
        if not isinstance(private, ec.EllipticCurvePrivateKey) or not isinstance(public, ec.EllipticCurvePublicKey):
            raise ValueError()
        if private.curve.name != "secp256r1" or public.curve.name != "secp256r1":
            raise ValueError()
        return private.exchange(ec.ECDH(), public)
    except (ValueError, TypeError) as error:
        raise ProtocolError("invalid native EC key") from error


def native_ctr(value: str, shared_secret: bytes, *, decrypt: bool = False) -> str:
    """b0.e/s: raw ECDH bytes AES key, fixed ASCII IV; no IOS key conversion."""
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
    if len(shared_secret) not in (16, 24, 32) or len(value) > MAX_BLE_BYTES:
        raise ProtocolError("invalid native cipher input")
    try:
        raw = base64.b64decode(value, validate=True) if decrypt else value.encode("utf-8")
        context = Cipher(algorithms.AES(shared_secret), modes.CTR(CTR_IV)).encryptor()
        output = context.update(raw) + context.finalize()
        return output.decode("utf-8") if decrypt else base64.b64encode(output).decode("ascii")
    except (ValueError, UnicodeError) as error:
        raise ProtocolError("invalid native cipher encoding") from error
