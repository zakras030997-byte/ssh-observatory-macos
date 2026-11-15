import socket
import threading
import unittest
from unittest.mock import patch

from vpn_socks_probe import serve_one


class SocksProbeTests(unittest.TestCase):
    def test_failed_bound_dial_does_not_fallback(self):
        client, server = socket.socketpair()
        client.settimeout(2)
        with patch("vpn_socks_probe.connect_ipv4", side_effect=OSError("VPN unavailable")) as dial:
            thread = threading.Thread(target=serve_one, args=(server, "utun9999"))
            thread.start()
            client.sendall(b"\x05\x01\x00")
            self.assertEqual(client.recv(2), b"\x05\x00")
            client.sendall(b"\x05\x01\x00\x01\x01\x01\x01\x01\x01\xbb")
            self.assertEqual(client.recv(10), b"")
            thread.join(2)
            self.assertFalse(thread.is_alive())
            dial.assert_called_once_with("1.1.1.1", 443, "utun9999", timeout=10)
        client.close()

    def test_domain_names_do_not_trigger_system_dns(self):
        client, server = socket.socketpair()
        client.settimeout(2)
        with patch("vpn_socks_probe.connect_ipv4") as dial:
            thread = threading.Thread(target=serve_one, args=(server, "utun7"))
            thread.start()
            client.sendall(b"\x05\x01\x00")
            self.assertEqual(client.recv(2), b"\x05\x00")
            client.sendall(b"\x05\x01\x00\x03")
            self.assertEqual(client.recv(2), b"\x05\x08")
            thread.join(2)
            dial.assert_not_called()
        client.close()


if __name__ == "__main__":
    unittest.main()
