import threading
import time
import unittest
import subprocess
import sys

from tor_recovery import TorRecovery


def until(predicate, timeout=2):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.01)
    return False


class TorRecoveryTests(unittest.TestCase):
    def test_stop_refuses_to_race_with_running_restart(self):
        revoked = []
        class StuckWorker:
            def join(self, timeout):
                self.timeout = timeout
            def is_alive(self):
                return True
        recovery = TorRecovery(vpn_ok=lambda: True, tor_ok=lambda: False,
                               revoke=lambda: revoked.append(True), restart=lambda _: False)
        recovery._thread = StuckWorker()
        with self.assertRaises(TimeoutError):
            recovery.stop()
        self.assertEqual(revoked, [])
        self.assertFalse(recovery.allow_new())

    def test_preferred_preconfigured_bridge_is_used_first(self):
        tor = threading.Event(); attempts = []
        def restart(route):
            attempts.append(route); tor.set(); return True
        recovery = TorRecovery(vpn_ok=lambda: True, tor_ok=tor.is_set, revoke=lambda: None,
                               restart=restart, bridges=['bridge-a'], preferred='bridge-a',
                               interval=0.05, cooldown=0.05)
        try:
            recovery.start()
            self.assertTrue(until(recovery.allow_new))
            self.assertEqual(attempts, ['bridge-a'])
        finally:
            recovery.stop()

    def test_restarts_owned_process_after_exit(self):
        processes = []
        def alive():
            return bool(processes) and processes[-1].poll() is None
        def restart(_route):
            processes.append(subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            return True
        recovery = TorRecovery(vpn_ok=lambda: True, tor_ok=alive, revoke=lambda: None,
                               restart=restart, interval=0.05, cooldown=0.05)
        try:
            recovery.start()
            self.assertTrue(until(recovery.allow_new))
            processes[-1].terminate(); processes[-1].wait(timeout=2)
            self.assertTrue(until(lambda: len(processes) == 2 and recovery.allow_new()))
        finally:
            recovery.stop()
            for process in processes:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=2)

    def test_restarts_tor_and_revokes_before_reconnect(self):
        vpn, tor = threading.Event(), threading.Event()
        vpn.set(); events = []
        def restart(route):
            events.append(("restart", route)); tor.set(); return True
        recovery = TorRecovery(vpn_ok=vpn.is_set, tor_ok=tor.is_set,
                               revoke=lambda: events.append(("revoke",)), restart=restart,
                               interval=0.05, cooldown=0.05)
        try:
            recovery.start()
            self.assertTrue(until(recovery.allow_new))
            self.assertEqual(events[:2], [("revoke",), ("restart", "default")])
        finally:
            recovery.stop()

    def test_bridge_is_tried_if_default_fails(self):
        tor = threading.Event(); attempts = []
        def restart(route):
            attempts.append(route)
            if route == "bridge-a":
                tor.set(); return True
            return False
        recovery = TorRecovery(vpn_ok=lambda: True, tor_ok=tor.is_set, revoke=lambda: None,
                               restart=restart, bridges=["bridge-a"], interval=0.05, cooldown=0.05)
        try:
            recovery.start()
            self.assertTrue(until(recovery.allow_new))
            self.assertEqual(attempts[:2], ["default", "bridge-a"])
        finally:
            recovery.stop()

    def test_no_tor_restart_without_vpn(self):
        vpn = threading.Event(); attempts = []; revoked = threading.Event()
        recovery = TorRecovery(vpn_ok=vpn.is_set, tor_ok=lambda: False, revoke=revoked.set,
                               restart=lambda route: attempts.append(route) or False,
                               bridges=["bridge-a"], interval=0.05, cooldown=0.05)
        try:
            recovery.start()
            self.assertTrue(revoked.wait(1))
            time.sleep(0.12)
            self.assertEqual(attempts, [])
            self.assertFalse(recovery.allow_new())
            vpn.set()
            self.assertTrue(until(lambda: bool(attempts)))
        finally:
            recovery.stop()

    def test_failed_revocation_never_restarts(self):
        attempts = []; observed = threading.Event()
        def revoke():
            observed.set(); raise RuntimeError("failure")
        recovery = TorRecovery(vpn_ok=lambda: True, tor_ok=lambda: False, revoke=revoke,
                               restart=lambda route: attempts.append(route) or True,
                               interval=0.05, cooldown=0.05)
        try:
            recovery.start()
            self.assertTrue(observed.wait(1))
            self.assertFalse(recovery.allow_new())
            self.assertEqual(attempts, [])
        finally:
            recovery.stop()


if __name__ == "__main__":
    unittest.main()
