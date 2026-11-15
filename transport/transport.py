"""Candidate isolated HY2 → Tor transport; not wired into Observatory.

This module prepares process arguments only.  It never opens a socket, reads a
profile, starts a process, or claims that a route is secure by itself.
The runtime must own both children, verify their identity and health, and stop
SSH whenever either child exits.  Until then this is not a production guard.
"""
from __future__ import annotations

from copy import deepcopy
from pathlib import Path
class UnsafeProfile(ValueError):
    pass


def _loopback(port: int) -> str:
    if type(port) is not int or not 1024 <= port <= 65535:
        raise UnsafeProfile("invalid local port")
    return f"127.0.0.1:{port}"


def client_config(profile: dict, vpn_port: int) -> dict:
    """Create a private single-VPN SOCKS config without a direct route.

    Callers must protect the output as a secret. Unknown config fields are
    rejected rather than copied into the privileged execution path.
    """
    if not isinstance(profile, dict) or set(profile) - {"server", "auth", "tls", "obfs"}:
        raise UnsafeProfile("unsupported VPN profile fields")
    server, auth, tls = profile.get("server"), profile.get("auth"), profile.get("tls")
    if not isinstance(server, str) or not server or any(c.isspace() for c in server):
        raise UnsafeProfile("invalid VPN endpoint")
    if not isinstance(auth, str) or not auth:
        raise UnsafeProfile("missing VPN authentication")
    if not isinstance(tls, dict) or set(tls) - {"sni", "insecure", "pinSHA256"}:
        raise UnsafeProfile("unsupported TLS configuration")
    if tls.get("insecure", False) is not False:
        raise UnsafeProfile("TLS verification must remain enabled")
    if not isinstance(tls.get("sni"), str) or not tls["sni"]:
        raise UnsafeProfile("missing TLS server name")
    obfs = profile.get("obfs")
    if obfs is not None and (not isinstance(obfs, dict) or set(obfs) != {"type", "salamander"}
                             or obfs.get("type") != "salamander"
                             or not isinstance(obfs.get("salamander"), dict)
                             or set(obfs["salamander"]) != {"password"}
                             or not obfs["salamander"]["password"]):
        raise UnsafeProfile("unsupported obfuscation")
    result = {"server": server, "auth": auth, "tls": deepcopy(tls),
              "socks5": {"listen": _loopback(vpn_port)}}
    if obfs is not None:
        result["obfs"] = deepcopy(obfs)
    return result


def tor_arguments(tor_path: str, data_dir: str, vpn_port: int, tor_port: int) -> list[str]:
    if not tor_path.startswith("/") or not data_dir.startswith("/") or vpn_port == tor_port:
        raise UnsafeProfile("invalid isolated transport")
    return [tor_path, "-f", str(Path(data_dir) / "torrc"), "--Socks5Proxy", _loopback(vpn_port), "--SocksPort", _loopback(tor_port),
            "--DataDirectory", data_dir, "--AvoidDiskWrites", "1"]


def ssh_proxy_options(tor_port: int) -> list[str]:
    proxy = _loopback(tor_port)
    return ["-o", f"ProxyCommand=/usr/bin/nc -X 5 -x {proxy} %h %p",
            "-o", "ProxyJump=none", "-o", "BindInterface=none",
            "-o", "StrictHostKeyChecking=yes", "-o", "UpdateHostKeys=no",
            "-o", "ControlMaster=no", "-o", "ControlPath=none"]
