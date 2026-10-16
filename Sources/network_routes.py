# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
"""Select active LAN addresses without following a VPN's default route."""
import ipaddress, re, subprocess, socket, sys
from dataclasses import dataclass

@dataclass(frozen=True)
class LANAddress:
    interface: str
    address: str
    network: ipaddress.IPv4Network


def private_ipv4(value):
    try:
        ip = ipaddress.ip_address(value)
        return ip.version == 4 and ip.is_private and not (ip.is_loopback or ip.is_unspecified or ip.is_multicast or ip.is_reserved)
    except (ValueError, TypeError):
        return False


def parse_interfaces(text):
    result = []; interface = None; up = False
    for line in text.splitlines():
        if line and not line[0].isspace():
            interface = line.split(':', 1)[0]
            up = bool(re.search(r'<[^>]*\bUP\b', line)) and bool(re.fullmatch(r'(?:en|bridge)\d+', interface))
        match = re.search(r'\binet (\S+) netmask (\S+)', line)
        if not (up and match and private_ipv4(match[1])): continue
        try:
            mask = str(ipaddress.IPv4Address(int(match[2], 16))) if match[2].startswith('0x') else match[2]
            network = ipaddress.IPv4Network(f'{match[1]}/{mask}', strict=False)
            result.append(LANAddress(interface, match[1], network))
        except ValueError: continue
    inactive = set()
    current = None
    for line in text.splitlines():
        if line and not line[0].isspace(): current = line.split(':', 1)[0]
        elif line.strip() == 'status: inactive': inactive.add(current)
    return [item for item in result if item.interface not in inactive]


def interfaces():
    text = subprocess.check_output(['/sbin/ifconfig', '-a'], text=True, stderr=subprocess.DEVNULL, timeout=3)
    return parse_interfaces(text)

def lan_addresses(peer=None):
    return rank_addresses(interfaces(),peer)


def rank_addresses(addresses, peer=None):
    ip = ipaddress.ip_address(peer) if private_ipv4(peer) else None
    ordered = sorted(addresses, key=lambda x: (not (ip and ip in x.network), x.interface != 'en0', x.interface.startswith('bridge')))
    return list(dict.fromkeys(x.address for x in ordered))[:4]


def interface_for_address(address):
    return next((x.interface for x in interfaces() if x.address == address), None)


def direct_local_address(peer):
    ip=ipaddress.ip_address(peer)
    return next((x.address for x in interfaces() if ip in x.network), None)


def bind_interface(sock, interface):
    if interface and sys.platform == 'darwin':
        # Public Darwin socket option from netinet/in.h. Apply only to the
        # selected LAN socket; never change system routes or VPN configuration.
        sock.setsockopt(socket.IPPROTO_IP, 25, socket.if_nametoindex(interface))


def lan_socket(address, kind=socket.SOCK_STREAM):
    sock=socket.socket(socket.AF_INET,kind)
    try:
        bind_interface(sock,interface_for_address(address))
        sock.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
        sock.bind((address,0))
        # The protocol reserves TCP port + 1 for the UDP benchmark.
        if kind == socket.SOCK_STREAM and sock.getsockname()[1] == 65535:
            sock.close()
            return lan_socket(address,kind)
        sock.setblocking(False)
        return sock
    except BaseException:
        sock.close();raise


def client_socket_factory(address):
    interface=interface_for_address(address)
    def create(info):
        family,kind,protocol,_,_=info
        sock=socket.socket(family,kind,protocol)
        try:bind_interface(sock,interface);return sock
        except BaseException:sock.close();raise
    return create
