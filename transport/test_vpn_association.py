import unittest
from unittest.mock import patch

from vpn_association import discover, parse_connected_services, parse_default_route, service_matches_interface


UUID = "12345678-1234-1234-1234-123456789abc"


class VPNAssociationTests(unittest.TestCase):
    def test_needs_explicit_connected_service_with_matching_tunnel(self):
        listing = f'* (Connected) {UUID} VPN (example) "Example VPN" [VPN:example]'
        self.assertEqual(parse_connected_services(listing), [UUID])
        self.assertEqual(parse_default_route(' gateway: 192.0.2.2\n interface: utun7\n'), 'utun7')
        self.assertTrue(service_matches_interface('Connected\n InterfaceName : utun7\n', 'utun7'))
        self.assertFalse(service_matches_interface('Disconnected\n InterfaceName : utun7\n', 'utun7'))
        self.assertFalse(service_matches_interface('Connected\n InterfaceName : utun8\n', 'utun7'))

    def test_physical_default_route_cannot_be_accepted(self):
        self.assertIsNone(parse_default_route('interface: en0\n'))

    @patch('vpn_association.socket.if_nametoindex', return_value=7)
    @patch('vpn_association.subprocess.run')
    def test_ambiguous_two_services_fail_closed(self, run, _index):
        other = 'abcdefab-cdef-abcd-efab-cdefabcdefab'
        outputs = ['interface: utun7\n', f'* (Connected) {UUID} VPN (a)\n* (Connected) {other} VPN (b)\n',
                   'Connected\n InterfaceName : utun7\n', 'Connected\n InterfaceName : utun7\n']
        run.side_effect = [type('Result', (), {'stdout': text})() for text in outputs]
        self.assertIsNone(discover())


if __name__ == '__main__':
    unittest.main()
