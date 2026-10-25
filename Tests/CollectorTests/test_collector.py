import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

PATH = Path(__file__).parents[2] / "Sources/SSHObservatory/Resources/collector.py"
spec = importlib.util.spec_from_file_location("collector", PATH)
collector = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collector)


class CollectorTests(unittest.TestCase):
    def fixture(self, text, function):
        with tempfile.TemporaryDirectory() as root:
            p = Path(root) / "fixture"
            p.write_text(text)
            return function(str(p))

    def test_cpu_excludes_double_counted_guest(self):
        self.assertEqual(self.fixture("cpu 100 10 40 200 50 5 5 0 20 2\n", collector.read_cpu), (410, 250))

    def test_cpu_delta_and_first_point(self):
        self.assertIsNone(collector.cpu_percent(None, (100, 50)))
        self.assertEqual(collector.cpu_percent((100, 50), (200, 125)), 25)
        self.assertIsNone(collector.cpu_percent((200, 125), (100, 50)))

    def test_memory_uses_available_not_free(self):
        memory, swap = self.fixture("MemTotal: 1000 kB\nMemAvailable: 600 kB\nMemFree: 100 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n", collector.read_memory)
        self.assertEqual(memory, {"total": 1024000, "available": 614400})
        self.assertEqual(swap["total"], 0)

    def test_network_excludes_loopback(self):
        value = self.fixture(" lo: 1000 0 0 0 0 0 0 0 2000 0\n eth0: 300 0 0 0 0 0 0 0 400 0\n", lambda p: collector.read_network(p, interface="eth0"))
        self.assertEqual(value, (300, 400))

    def test_network_counter_reset_is_gap(self):
        self.assertIsNone(collector.network_rate((100, 100), (20, 50), 3))
        self.assertEqual(collector.network_rate((100, 100), (400, 700), 3), {"receivedBytesPerSecond": 100, "sentBytesPerSecond": 200})

    def test_missing_systemctl_returns_partial_not_exception(self):
        with patch.object(collector.subprocess, "run", side_effect=FileNotFoundError):
            states, error = collector.read_units(["test.service"])
        self.assertTrue(error)
        self.assertEqual(states[0]["state"], "unknown")

    def test_units_reject_shell_characters_before_proc_reads(self):
        with self.assertRaises(ValueError):
            collector.Collector({"nodeID": "test", "units": ["x.service;rm"]})
    def test_wrong_hostname_stops_before_reading_proc(self):
        with patch.object(collector.socket, "gethostname", return_value="unexpected"):
            with self.assertRaisesRegex(ValueError, "hostname mismatch"):
                collector.Collector({"nodeID": "test", "expectedHostname": "expected"})

    def test_stdin_eof_stops_without_sampling(self):
        with patch.object(collector, "Collector"), patch.object(collector.signal, "signal"), patch.object(collector.signal, "setitimer"), \
                patch.object(collector.select, "select", return_value=([collector.sys.stdin], [], [])), \
                patch.object(collector.os, "read", return_value=b""):
            collector.main({"nodeID": "test"})
            collector.Collector.return_value.sample.assert_not_called()

    def test_heartbeat_lease_stops_after_mac_disappears(self):
        with patch.object(collector, "Collector"), patch.object(collector.signal, "signal"), patch.object(collector.signal, "setitimer"), \
                patch.object(collector.time, "monotonic", side_effect=[0, 13]):
            collector.main({"nodeID": "test"})
            collector.Collector.return_value.sample.assert_not_called()

    def test_network_does_not_sum_bridge_and_tunnel(self):
        data = "eth0: 100 0 0 0 0 0 0 0 200 0\nveth0: 100 0 0 0 0 0 0 0 200 0\ntun0: 100 0 0 0 0 0 0 0 200 0\n"
        self.assertEqual(self.fixture(data, lambda p: collector.read_network(p, interface="eth0")), (100, 200))
        with self.assertRaises(ValueError):
            self.fixture(data, lambda p: collector.read_network(p, interface="missing"))

    def test_default_route_uses_lowest_metric(self):
        data = "Iface Destination Gateway Flags RefCnt Use Metric Mask\ntun0 00000000 01010101 0003 0 0 100 00000000\neth0 00000000 01010101 0003 0 0 10 00000000\n"
        self.assertEqual(self.fixture(data, collector.default_interface), "eth0")
        with self.assertRaises(ValueError):
            self.fixture("Iface Destination\n", collector.default_interface)

    def test_disk_keeps_reserved_space_separate(self):
        from types import SimpleNamespace
        value = SimpleNamespace(f_blocks=1000, f_bfree=250, f_bavail=200, f_frsize=1)
        with patch.object(collector.os, "statvfs", return_value=value):
            self.assertEqual(collector.read_disk(), {"total":1000, "available":200, "usedBytes":750, "reservedBytes":50})

    def test_interface_change_resets_rate(self):
        with patch("builtins.open", unittest.mock.mock_open(read_data="boot")), patch.object(collector.socket,"gethostname",return_value="host"):
            c = collector.Collector({"nodeID":"test"})
        with patch.object(collector,"read_cpu",return_value=(100,50)), patch.object(collector,"read_memory",return_value=(None,None)), \
             patch.object(collector,"read_disk",return_value=None), patch.object(collector,"read_units",return_value=([],False)), \
             patch.object(collector,"default_interface",side_effect=["eth0","eth0","eth1"]), \
             patch.object(collector,"read_network",side_effect=[(100,200),(200,300),(5000,5000)]), \
             patch.object(collector.time,"monotonic",side_effect=[1,4,7]):
            self.assertIsNone(c.sample()["network"])
            self.assertEqual(c.sample()["network"]["interface"],"eth0")
            self.assertIsNone(c.sample()["network"])

    def test_alarm_armed_and_cancelled_on_eof(self):
        with patch.object(collector,"Collector"), patch.object(collector.signal,"signal"), \
             patch.object(collector.signal,"setitimer") as alarm, \
             patch.object(collector.select,"select",return_value=([collector.sys.stdin],[],[])), \
             patch.object(collector.os,"read",return_value=b""):
            collector.main({"nodeID":"test"})
        self.assertEqual([c.args[1] for c in alarm.call_args_list],[12,0])

    @unittest.skipUnless(hasattr(collector.signal,"setitimer"),"POSIX timer required")
    def test_independent_alarm_stops_blocked_output(self):
        import subprocess, sys, time
        source = "import os,signal\nfrom unittest.mock import patch\n" + \
            "import importlib.util\ns=importlib.util.spec_from_file_location('c'," + repr(str(PATH)) + ");c=importlib.util.module_from_spec(s);s.loader.exec_module(c)\n" + \
            "class C:\n def __init__(self,cfg): pass\n def sample(self): return {'data':'x'*10000000}\n" + \
            "original=signal.setitimer\ndef timer(kind,seconds): return original(kind,0.3 if seconds else 0)\n" + \
            "with patch.object(c,'Collector',C),patch.object(c.signal,'setitimer',timer): c.main({'nodeID':'test'})\n"
        p = subprocess.Popen([sys.executable,"-B","-c",source],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        try:
            p.wait(timeout=3)  # stdout deliberately unread; write exceeds pipe capacity.
            self.assertEqual(p.returncode,0)
        finally:
            if p.poll() is None: p.kill(); p.wait()
            for f in (p.stdin,p.stdout,p.stderr): f.close()

if __name__ == "__main__":
    unittest.main()
