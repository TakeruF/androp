# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 anDrop contributors
import sys, unittest
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Sources'))
from network_routes import parse_interfaces,rank_addresses,private_ipv4
from engine import local_endpoint

class RouteTests(unittest.TestCase):
    def setUp(self):
        self.text='''lo0: flags=1<UP,LOOPBACK,RUNNING>
    inet 127.0.0.1 netmask 0xff000000
utun4: flags=1<UP,POINTOPOINT,RUNNING>
    inet 10.0.0.2 netmask 0xff000000
en7: flags=1<UP,RUNNING>
    inet 192.168.7.2 netmask 0xffffff00
en0: flags=1<UP,RUNNING>
    inet 192.168.8.2 netmask 0xffffff00
bridge0: flags=1<UP,RUNNING>
    inet 172.16.0.2 netmask 0xffff0000
en2: flags=1<BROADCAST>
    inet 192.168.9.2 netmask 0xffffff00
'''
    def test_vpn_and_down_interfaces_are_excluded(self):
        self.assertEqual(rank_addresses(parse_interfaces(self.text)),['192.168.8.2','192.168.7.2','172.16.0.2'])
    def test_direct_peer_subnet_beats_default_wifi(self):
        self.assertEqual(rank_addresses(parse_interfaces(self.text),'192.168.7.99')[0],'192.168.7.2')
    def test_dormant_hotspot_and_invalid_hint_do_not_replace_local_address(self):
        for hint in ['192.168.49.1','127.0.0.1','bad',None]:self.assertEqual(rank_addresses(parse_interfaces(self.text),hint)[0],'192.168.8.2')
    def test_routing_order_changes_with_live_interfaces(self):
        self.assertEqual(rank_addresses(parse_interfaces(self.text.replace('en0: flags=1<UP,RUNNING>','en0: flags=1<BROADCAST>')))[0],'192.168.7.2')
    def test_endpoint_rejects_internet_loopback_multicast_and_bad_ports(self):
        for host in ['8.8.8.8','127.0.0.1','0.0.0.0','224.0.0.1','::1','bad','240.0.0.1']:
            self.assertFalse(private_ipv4(host))
            with self.assertRaises(ValueError):local_endpoint(host,1234)
        for port in [0,-1,65535,65536]:
            with self.assertRaises(ValueError):local_endpoint('192.168.1.2',port)
    def test_malformed_mask_and_ipv6_are_ignored(self):
        self.assertEqual(parse_interfaces('en0: flags=1<UP>\n inet 10.0.0.1 netmask broken\n inet6 fe80::1 prefixlen 64'),[])

    def test_interface_binding_only_changes_selected_socket(self):
        from unittest.mock import Mock,patch
        from network_routes import bind_interface
        import socket
        sock=Mock()
        with patch('network_routes.sys.platform','darwin'),patch('network_routes.socket.if_nametoindex',return_value=7):bind_interface(sock,'en7')
        sock.setsockopt.assert_called_once_with(socket.IPPROTO_IP,25,7)

    def test_socket_cleanup_when_interface_binding_fails(self):
        from unittest.mock import Mock,patch
        from network_routes import lan_socket
        sock=Mock()
        with patch('network_routes.socket.socket',return_value=sock),patch('network_routes.interface_for_address',return_value='en7'),patch('network_routes.bind_interface',side_effect=OSError('interface removed')):
            with self.assertRaises(OSError):lan_socket('192.168.7.2')
        sock.close.assert_called_once()

    def test_inactive_interface_with_stale_address_is_excluded(self):
        text=self.text.replace('    inet 192.168.8.2 netmask 0xffffff00','    inet 192.168.8.2 netmask 0xffffff00\n    status: inactive')
        self.assertNotIn('192.168.8.2',rank_addresses(parse_interfaces(text)))

    def test_last_tcp_port_is_reselected_to_keep_udp_port_valid(self):
        from unittest.mock import Mock,patch
        from network_routes import lan_socket
        first,second=Mock(),Mock()
        first.getsockname.return_value=('127.0.0.1',65535)
        second.getsockname.return_value=('127.0.0.1',50000)
        with patch('network_routes.socket.socket',side_effect=[first,second]),patch('network_routes.interface_for_address',return_value=None):
            self.assertIs(lan_socket('127.0.0.1'),second)
        first.close.assert_called_once()
