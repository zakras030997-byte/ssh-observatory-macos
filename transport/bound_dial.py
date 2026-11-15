"""Experimental macOS interface-bound TCP dialer, NOT a VPN verifier.

Do not deploy: a utun interface may implement split routing, and a bound
socket alone does not establish that the tunnel encrypts a given flow.  A
trusted per-flow VPN verifier and active-connection revocation are still needed.
"""
from __future__ import annotations

import ipaddress
import re
import socket
import sys


class BoundDialError(OSError):
    pass


def connect_ipv4(destination: str, port: int, interface: str, *, timeout: float = 8.0):
    """Connect one public IPv4 TCP socket pinned to the specified utun.

    No DNS lookup, alternate interface, unbound retry, or direct fallback is
    performed.  Caller owns the returned socket and must close it when the VPN
    path changes. This function does not identify the owner of the interface.
    """
    if sys.platform != "darwin":
        raise BoundDialError("macOS is required")
    try:
        address = ipaddress.IPv4Address(destination)
    except ipaddress.AddressValueError as error:
        raise BoundDialError("destination must be an IPv4 literal") from error
    if not address.is_global or type(port) is not int or not 1 <= port <= 65535:
        raise BoundDialError("invalid destination")
    if not isinstance(interface, str) or not re.fullmatch(r"utun[0-9]{1,4}", interface):
        raise BoundDialError("not a tunnel interface")
    if not isinstance(timeout, (int, float)) or not 0 < timeout <= 30:
        raise BoundDialError("invalid timeout")

    try:
        index = socket.if_nametoindex(interface)
    except OSError as error:
        raise BoundDialError("tunnel interface unavailable") from error
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        # IP_BOUND_IF is 25 in the macOS SDK. Never silently skip this step.
        sock.setsockopt(socket.IPPROTO_IP, 25, index)
        if sock.getsockopt(socket.IPPROTO_IP, 25) != index:
            raise BoundDialError("interface binding not confirmed")
        sock.settimeout(timeout)
        sock.connect((str(address), port))
        return sock
    except Exception:
        sock.close()
        raise
