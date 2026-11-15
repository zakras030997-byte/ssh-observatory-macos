"""Tor recovery coordinator used by the protected transport.

Callbacks must be bounded, trusted, and VPN-only. In particular `restart` must
never bypass the verified VPN; a mere Tor process or SOCKS port is not proof.
Bridge identifiers here are labels for preconfigured routes, not bridge data.
"""
from __future__ import annotations

import threading
from collections.abc import Callable, Sequence


class TorRecovery:
    def __init__(self, *, vpn_ok: Callable[[], bool], tor_ok: Callable[[], bool],
                 revoke: Callable[[], None], restart: Callable[[str], bool],
                 bridges: Sequence[str] = (), interval: float = 0.25,
                 cooldown: float = 1.0, preferred: str = "default"):
        if not 0.05 <= interval <= 5 or not 0.05 <= cooldown <= 300:
            raise ValueError("invalid retry timing")
        if len(bridges) > 8 or any(not isinstance(b, str) or not b or len(b) > 80 for b in bridges):
            raise ValueError("invalid bridge list")
        self._vpn_ok, self._tor_ok, self._revoke, self._restart = vpn_ok, tor_ok, revoke, restart
        self._routes = tuple(dict.fromkeys(("default", *bridges)))
        if preferred not in self._routes:
            raise ValueError("preferred route not configured")
        self._current = preferred
        self._interval, self._cooldown = interval, cooldown
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._ready = False
        self._thread: threading.Thread | None = None

    @staticmethod
    def _check(check: Callable[[], bool]) -> bool:
        try:
            return check() is True
        except Exception:
            return False

    def start(self) -> None:
        with self._lock:
            if self._thread is not None or self._stop.is_set():
                raise RuntimeError("recovery already started or stopped")
            self._thread = threading.Thread(target=self._run, name="vpn-tor-recovery", daemon=True)
            self._thread.start()

    def allow_new(self) -> bool:
        with self._lock:
            ready = self._ready and not self._stop.is_set()
        return ready and self._check(self._vpn_ok) and self._check(self._tor_ok)

    def _set_ready(self, ready: bool) -> None:
        with self._lock:
            self._ready = ready

    def _run(self) -> None:
        revoked = False
        while not self._stop.is_set():
            vpn = self._check(self._vpn_ok)
            tor = vpn and self._check(self._tor_ok)
            if vpn and tor:
                self._set_ready(True)
                revoked = False
                self._stop.wait(self._interval)
                continue
            self._set_ready(False)
            if not revoked:
                try:
                    self._revoke()
                except Exception:
                    # Closure was not confirmed. Never start a replacement.
                    self._stop.set()
                    return
                revoked = True
            if not vpn:
                self._stop.wait(self._interval)
                continue
            routes = (self._current,) + tuple(r for r in self._routes if r != self._current)
            for route in routes:
                if self._stop.is_set() or not self._check(self._vpn_ok):
                    break
                try:
                    started = self._restart(route) is True
                except Exception:
                    started = False
                if started and not self._stop.is_set() and self._check(self._vpn_ok) and self._check(self._tor_ok):
                    self._current = route
                    self._set_ready(True)
                    break
            self._stop.wait(self._cooldown)

    def stop(self) -> None:
        self._stop.set()
        self._set_ready(False)
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=5)
            if thread.is_alive():
                # A restart callback is still in flight. Revoking here would
                # race with it and could leave a newly started process alive.
                raise TimeoutError("recovery worker did not stop")
        try:
            self._revoke()
        except Exception:
            pass
