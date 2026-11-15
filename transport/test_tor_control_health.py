import io
import unittest
from pathlib import Path
from unittest.mock import MagicMock, patch

from tor_control_health import circuit_ready


class ControlHealthTests(unittest.TestCase):
    @patch('tor_control_health.socket.socket')
    @patch.object(Path, 'read_bytes', return_value=b'x' * 32)
    def test_only_authenticated_established_circuit_is_healthy(self, cookie, create):
        client = create.return_value.__enter__.return_value
        client.makefile.return_value = io.BytesIO(b'250 OK\r\n250-status/circuit-established=1\r\n250 OK\r\n')
        self.assertTrue(circuit_ready(Path('/tmp/ctl'), Path('/tmp/cookie')))
        client.makefile.return_value = io.BytesIO(b'250 OK\r\n250-status/circuit-established=0\r\n250 OK\r\n')
        self.assertFalse(circuit_ready(Path('/tmp/ctl'), Path('/tmp/cookie')))
        client.makefile.return_value = io.BytesIO(b'515 Authentication failed\r\n')
        self.assertFalse(circuit_ready(Path('/tmp/ctl'), Path('/tmp/cookie')))

    @patch.object(Path, 'read_bytes', return_value=b'bad')
    def test_invalid_cookie_fails_closed(self, cookie):
        self.assertFalse(circuit_ready(Path('/tmp/ctl'), Path('/tmp/cookie')))


if __name__ == '__main__':
    unittest.main()
