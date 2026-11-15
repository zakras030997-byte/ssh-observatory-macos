"""Read-only macOS VPN-to-default-interface association for a candidate.

Association is not attestation of encryption or split-routing. This module
must never be the sole authority permitting a protected SSH connection.
"""
from __future__ import annotations

import re
import socket
import subprocess
from dataclasses import dataclass


@dataclass(frozen=True)
class Association:
    interface: str
    index: int
    service_id: str


def parse_default_route(text: str) -> str | None:
    names = re.findall(r"(?m)^\s*interface:\s*(utun[0-9]{1,4})\s*$", text)
    return names[0] if len(names) == 1 else None


def parse_connected_services(text: str) -> list[str]:
    return re.findall(r"(?m)^\s*\*\s*\(Connected\)\s+([0-9A-Fa-f-]{36})\s+VPN\s", text)


def service_matches_interface(status: str, interface: str) -> bool:
    if not status.startswith("Connected\n"):
        return False
    interfaces = re.findall(r"(?m)^\s*InterfaceName\s*:\s*(utun[0-9]{1,4})\s*$", status)
    return interfaces == [interface]


def discover() -> Association | None:
    """Return only an unambiguous active association, without any fallback."""
    def run(args):
        return subprocess.run(args, capture_output=True, text=True, timeout=3, check=True).stdout
    try:
        interface = parse_default_route(run(["/sbin/route", "-n", "get", "default"]))
        if interface is None:
            return None
        services = parse_connected_services(run(["/usr/sbin/scutil", "--nc", "list"]))
        matches = [service for service in services if service_matches_interface(
            run(["/usr/sbin/scutil", "--nc", "status", service]), interface)]
        if len(matches) != 1:
            return None
        index = socket.if_nametoindex(interface)
        return Association(interface=interface, index=index, service_id=matches[0])
    except (OSError, subprocess.SubprocessError):
        return None


def still_matches(initial: Association) -> bool:
    current = discover()
    return current is not None and current == initial
