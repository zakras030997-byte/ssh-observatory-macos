"""Experimental fail-closed lifetime gate for transport-owned sessions.

Not wired to Observatory. The caller must provide trustworthy VPN and Tor
health probes, and each registered close callback must close its owned session.
This component does not attest network traffic or prevent external programs
from bypassing the gate.
"""
from __future__ import annotations

import threading
from collections.abc import Callable


class RouteUnavailable(RuntimeError):
    pass


class SessionGuard:
    def __init__(self, vpn_alive: Callable[[], bool], tor_alive: Callable[[], bool], *, interval: float = 0.2):
        if not 0.05 <= interval <= 5:
            raise ValueError("invalid monitoring interval")
        self._vpn_alive = vpn_alive
        self._tor_alive = tor_alive
        self._interval = interval
        self._lock = threading.Lock()
        self._stopped = threading.Event()
        self._finished = threading.Event()
        self._closed = False
        self._sessions: list[Callable[[], None]] = []
        self._thread: threading.Thread | None = None

    def _healthy(self) -> bool:
        try:
            return self._vpn_alive() is True and self._tor_alive() is True
        except Exception:
            return False

    def start(self) -> None:
        with self._lock:
            if self._closed or self._thread is not None:
                raise RouteUnavailable("guard unavailable")
            if not self._healthy():
                self._closed = True
                self._stopped.set()
                self._finished.set()
                raise RouteUnavailable("VPN or Tor unavailable")
            self._thread = threading.Thread(target=self._watch, name="vpn-tor-route-guard", daemon=True)
            self._thread.start()

    def register(self, close: Callable[[], None]) -> None:
        """Register an owned session only while the guard and route are live."""
        if not callable(close):
            raise TypeError("close callback required")
        with self._lock:
            if self._closed or self._thread is None or not self._healthy():
                raise RouteUnavailable("VPN or Tor unavailable")
            self._sessions.append(close)

    def _watch(self) -> None:
        while not self._stopped.wait(self._interval):
            if not self._healthy():
                self.close()
                return

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            self._closed = True
            self._stopped.set()
            sessions, self._sessions = self._sessions, []
        for close in sessions:
            try:
                close()
            except Exception:
                # A failed cleanup must not prevent revocation of other sessions.
                continue
        self._finished.set()

    def wait(self, timeout: float) -> bool:
        return self._finished.wait(timeout)
