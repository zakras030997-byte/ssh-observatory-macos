"""Service-owned VPN/Tor runtime; VPN split rules are not security-attested.

Emits newline JSON status frames. Exits and cleans owned processes on EOF of
stdin. VPN association is only a system-state check, not proof that a VPN's
internal split rules actually encrypt each flow. Production use needs an
independent per-path guarantee, safe process-tree cleanup, and peer validation.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import threading
import time

from tor_recovery import TorRecovery
from tor_control_health import circuit_ready
from vpn_association import discover, still_matches


ROOT = Path(__file__).resolve().parent
TOR = Path('/opt/homebrew/bin/tor')
PT = Path('/opt/homebrew/bin/obfs4proxy')
BRIDGES = Path.home() / 'Library/Application Support/TorBrowser-Data/Tor/torrc'


def event(state, *, port=None):
    value = {'state': state, 'observed_at': time.time()}
    if port is not None:
        value['port'] = port
    print(json.dumps(value, separators=(',', ':')), flush=True)


def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def stop(process):
    if process and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=5)


def watch_parent(fd, shutdown):
    try:
        # Do not hold a buffered-reader lock across interpreter shutdown.
        while os.read(fd,4096):
            pass
    except OSError:
        pass
    finally:
        shutdown.set()


def main():
    association = discover()
    if association is None or not TOR.is_file():
        event('unavailable'); return 1
    bridges = []
    if PT.is_file() and BRIDGES.is_file():
        bridges = [x.strip() for x in BRIDGES.read_text().splitlines()
                   if x.strip().lower().startswith('bridge obfs4 ')][:2]
    proxy_port, tor_port = free_port(), free_port()
    if proxy_port == tor_port:
        event('unavailable'); return 1
    shutdown = threading.Event()
    threading.Thread(target=watch_parent,args=(sys.stdin.fileno(),shutdown),daemon=True).start()
    proxy = tor = None
    generation = 0
    last_state = None
    last_event = 0.0
    controller = None
    control = cookie = None
    with tempfile.TemporaryDirectory(prefix='observatory-route-', dir='/private/tmp') as temp:
        def vpn_ok():
            return not shutdown.is_set() and proxy is not None and proxy.poll() is None and still_matches(association)
        def tor_ok():
            return (tor is not None and tor.poll() is None and control is not None and cookie is not None
                    and circuit_ready(control, cookie))
        def revoke():
            nonlocal tor
            stop(tor); tor = None
        def restart(label):
            nonlocal tor, generation, control, cookie
            if not vpn_ok():
                return False
            generation += 1
            data = Path(temp) / str(generation); data.mkdir(mode=0o700)
            control, cookie = data / 'control.sock', data / 'control_auth_cookie'
            config = data / 'torrc'
            fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as f:
                if label != 'default':
                    try:
                        i = int(label.removeprefix('bridge-'))
                        line = bridges[i]
                    except (ValueError, IndexError):
                        return False
                    f.write('UseBridges 1\nClientTransportPlugin obfs4 exec ' + str(PT) + '\n' + line + '\n')
            log = data / 'tor.log'
            tor = subprocess.Popen([str(TOR), '-f', str(config), '--Socks5Proxy', f'127.0.0.1:{proxy_port}',
                                    '--SocksPort', f'127.0.0.1:{tor_port}', '--DataDirectory', str(data),
                                    '--ControlSocket', str(control), '--CookieAuthentication', '1',
                                    '--AvoidDiskWrites', '1', '--Log', f'notice file {log}'],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            end = time.monotonic() + 45
            while time.monotonic() < end and tor.poll() is None and vpn_ok():
                if log.exists() and 'Bootstrapped 100%' in log.read_text(errors='replace'):
                    return True
                time.sleep(0.25)
            stop(tor); tor = None
            return False
        try:
            proxy = subprocess.Popen([sys.executable, '-B', str(ROOT / 'vpn_socks_probe.py'), '--interface', association.interface, '--port', str(proxy_port)], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
            ready, _, _ = select.select([proxy.stdout], [], [], 5)
            if not ready or proxy.stdout.readline().strip() != 'READY':
                event('unavailable'); return 1
            controller = TorRecovery(vpn_ok=vpn_ok, tor_ok=tor_ok, revoke=revoke, restart=restart,
                                     bridges=[f'bridge-{i}' for i in range(len(bridges))], interval=0.25, cooldown=1,
                                     preferred='bridge-1' if len(bridges) > 1 else 'default')
            controller.start()
            while not shutdown.wait(0.25):
                state = 'ready' if controller.allow_new() else 'unavailable'
                now=time.monotonic()
                if state != last_state or now-last_event>=5:
                    event(state, port=tor_port if state == 'ready' else None)
                    last_state = state; last_event=now
                if not still_matches(association) or proxy.poll() is not None:
                    break
        finally:
            # Interrupt an in-flight bootstrap before joining its worker.
            shutdown.set()
            try:
                if controller:
                    controller.stop()
            finally:
                stop(tor); stop(proxy)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
