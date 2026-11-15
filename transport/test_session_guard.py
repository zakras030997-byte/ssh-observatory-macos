import subprocess
import sys
import threading
import unittest

from session_guard import RouteUnavailable, SessionGuard


class SessionGuardTests(unittest.TestCase):
    def test_refuses_start_without_vpn_or_tor(self):
        for vpn, tor in ((False, True), (True, False)):
            guard = SessionGuard(lambda: vpn, lambda: tor, interval=0.05)
            with self.assertRaises(RouteUnavailable):
                guard.start()
            with self.assertRaises(RouteUnavailable):
                guard.register(lambda: None)

    def test_closes_real_owned_process_on_simulated_tor_loss(self):
        vpn, tor = threading.Event(), threading.Event()
        vpn.set(); tor.set()
        guard = SessionGuard(vpn.is_set, tor.is_set, interval=0.05)
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            guard.start()
            guard.register(process.terminate)
            tor.clear()
            self.assertTrue(guard.wait(2))
            process.wait(timeout=2)
            self.assertIsNotNone(process.returncode)
            with self.assertRaises(RouteUnavailable):
                guard.register(lambda: None)
        finally:
            guard.close()
            if process.poll() is None:
                process.terminate(); process.wait(timeout=2)

    def test_exiting_owned_tor_process_closes_owned_ssh_process(self):
        tor = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        ssh = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        guard = SessionGuard(lambda: True, lambda: tor.poll() is None, interval=0.05)
        try:
            guard.start()
            guard.register(lambda: ssh.terminate() if ssh.poll() is None else None)
            tor.terminate(); tor.wait(timeout=2)
            self.assertTrue(guard.wait(2))
            ssh.wait(timeout=2)
            self.assertIsNotNone(ssh.returncode)
        finally:
            guard.close()
            for process in (tor, ssh):
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=2)

    def test_simulated_vpn_loss_closes_all_even_if_one_close_fails(self):
        vpn, tor = threading.Event(), threading.Event()
        vpn.set(); tor.set()
        closed = threading.Event()
        guard = SessionGuard(vpn.is_set, tor.is_set, interval=0.05)
        guard.start()
        def broken():
            raise RuntimeError("fixture")
        guard.register(broken)
        guard.register(closed.set)
        vpn.clear()
        self.assertTrue(closed.wait(2))
        self.assertTrue(guard.wait(2))
        with self.assertRaises(RouteUnavailable):
            guard.register(lambda: None)
        guard.close()

    def test_probe_exception_fails_closed(self):
        called = threading.Event()
        def bad_probe():
            if called.is_set():
                raise OSError("fixture")
            return True
        guard = SessionGuard(bad_probe, lambda: True, interval=0.05)
        guard.start()
        guard.register(called.set)
        called.set()
        self.assertTrue(guard.wait(2))
        with self.assertRaises(RouteUnavailable):
            guard.register(lambda: None)


if __name__ == "__main__":
    unittest.main()
