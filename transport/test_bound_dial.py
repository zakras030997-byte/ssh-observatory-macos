import unittest
from unittest.mock import patch

from bound_dial import BoundDialError, connect_ipv4


class BoundDialTests(unittest.TestCase):
    @patch("bound_dial.sys.platform", "darwin")
    @patch("bound_dial.socket.if_nametoindex", return_value=7)
    @patch("bound_dial.socket.socket")
    def test_binding_precedes_connect(self, make_socket, name_to_index):
        sock = make_socket.return_value
        sock.getsockopt.return_value = 7
        connect_ipv4("1.1.1.1", 443, "utun7")
        calls = [call[0] for call in sock.method_calls]
        self.assertLess(calls.index("setsockopt"), calls.index("connect"))
        sock.connect.assert_called_once_with(("1.1.1.1", 443))

    @patch("bound_dial.sys.platform", "darwin")
    @patch("bound_dial.socket.if_nametoindex", return_value=7)
    @patch("bound_dial.socket.socket")
    def test_failed_binding_closes_socket_without_connect(self, make_socket, name_to_index):
        sock = make_socket.return_value
        sock.setsockopt.side_effect = OSError("bind failure")
        with self.assertRaises(OSError):
            connect_ipv4("1.1.1.1", 443, "utun7")
        sock.connect.assert_not_called()
        sock.close.assert_called_once()

    @patch("bound_dial.sys.platform", "darwin")
    @patch("bound_dial.socket.socket")
    def test_no_physical_interface_or_dns_name(self, make_socket):
        with self.assertRaises(BoundDialError):
            connect_ipv4("1.1.1.1", 443, "en0")
        with self.assertRaises(BoundDialError):
            connect_ipv4("example.com", 443, "utun7")
        make_socket.assert_not_called()


if __name__ == "__main__":
    unittest.main()
