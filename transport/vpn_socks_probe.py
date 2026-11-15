"""Isolated test-only SOCKS5 CONNECT proxy bound to one macOS utun.

Not a production VPN guard: it does not attest VPN ownership, inspect the
provider's split-routing policy, or revoke streams when the tunnel changes.
Never use it as the permanent Observatory route.
"""
import argparse
import ipaddress
import selectors
import socket
import struct
import threading

from bound_dial import connect_ipv4


def read_exact(s, count):
    data = bytearray()
    while len(data) < count:
        part = s.recv(count - len(data))
        if not part:
            raise OSError("unexpected EOF")
        data.extend(part)
    return bytes(data)


def serve_one(client, interface):
    upstream = None
    try:
        client.settimeout(12)
        version, count = read_exact(client, 2)
        methods = read_exact(client, count)
        if version != 5 or b"\x00" not in methods:
            return
        client.sendall(b"\x05\x00")
        version, command, reserved, addrtype = read_exact(client, 4)
        # Accept IPv4 only: never resolve relay names outside the VPN.
        if (version, command, reserved, addrtype) != (5, 1, 0, 1):
            client.sendall(b"\x05\x08\x00\x01" + bytes(6))
            return
        destination = str(ipaddress.IPv4Address(read_exact(client, 4)))
        port = struct.unpack("!H", read_exact(client, 2))[0]
        upstream = connect_ipv4(destination, port, interface, timeout=10)
        client.sendall(b"\x05\x00\x00\x01" + bytes(6))
        client.setblocking(False)
        upstream.setblocking(False)
        with selectors.DefaultSelector() as selector:
            selector.register(client, selectors.EVENT_READ, upstream)
            selector.register(upstream, selectors.EVENT_READ, client)
            while True:
                events = selector.select(30)
                if not events:
                    return
                for key, _ in events:
                    try:
                        data = key.fileobj.recv(16384)
                        if not data:
                            return
                        key.data.setblocking(True)
                        key.data.settimeout(10)
                        key.data.sendall(data)
                        key.data.setblocking(False)
                    except OSError:
                        return
    except (OSError, ValueError):
        pass
    finally:
        if upstream is not None:
            upstream.close()
        client.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--interface", required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    if not 1024 <= args.port <= 65535:
        raise SystemExit("invalid port")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", args.port))
        listener.listen(32)
        print("READY", flush=True)
        while True:
            client, _ = listener.accept()
            threading.Thread(target=serve_one, args=(client, args.interface), daemon=True).start()


if __name__ == "__main__":
    main()
