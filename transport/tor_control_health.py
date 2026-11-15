"""Read Tor's authenticated circuit status; never log the control cookie."""
from __future__ import annotations

import socket
from pathlib import Path


def circuit_ready(control_socket: Path, cookie_file: Path, timeout: float = 1.0) -> bool:
    try:
        cookie = cookie_file.read_bytes()
        if len(cookie) != 32:
            return False
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(timeout)
            client.connect(str(control_socket))
            stream = client.makefile('rb')
            client.sendall(b'AUTHENTICATE ' + cookie.hex().encode('ascii') + b'\r\n')
            if stream.readline(1024) != b'250 OK\r\n':
                return False
            client.sendall(b'GETINFO status/circuit-established\r\n')
            answer = stream.readline(1024)
            end = stream.readline(1024)
            return answer == b'250-status/circuit-established=1\r\n' and end == b'250 OK\r\n'
    except (OSError, ValueError):
        return False
