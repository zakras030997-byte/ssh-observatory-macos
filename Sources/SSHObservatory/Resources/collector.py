"""Read-only Linux telemetry scoped to one SSH session. No writes or listeners.
Stdin EOF or a 12-second heartbeat lease expiry terminates the collector.
"""
import json
import os
import re
import select
import signal
import socket
import subprocess
import sys
import time


def read_cpu(path="/proc/stat"):
    with open(path) as f:
        values = list(map(int, f.readline().split()[1:9]))
    # guest counters are already included in user/nice.
    return sum(values), values[3] + values[4]


def cpu_percent(previous, current):
    if previous is None:
        return None
    total, idle = current[0] - previous[0], current[1] - previous[1]
    if total <= 0 or idle < 0 or idle > total:
        return None
    return round(100.0 * (total - idle) / total, 2)


def read_memory(path="/proc/meminfo"):
    with open(path) as f:
        fields = {p[0].rstrip(":"): int(p[1]) * 1024
                  for line in f if len(p := line.split()) >= 2}
    return ({"total": fields["MemTotal"], "available": fields["MemAvailable"]},
            {"total": fields.get("SwapTotal", 0), "available": fields.get("SwapFree", 0)})


def default_interface(path="/proc/net/route"):
    candidates = []
    with open(path) as f:
        for line in f:
            p = line.split()
            if len(p) >= 8 and p[1] == "00000000" and p[7] == "00000000" and int(p[3], 16) & 1:
                if p[0] != "lo":
                    candidates.append((int(p[6]), p[0]))
    if not candidates:
        raise ValueError("no external IPv4 default route; choose an interface")
    return min(candidates)[1]


def read_network(path="/proc/net/dev", interface=None):
    if not interface or interface == "lo":
        raise ValueError("external interface required")
    with open(path) as f:
        for line in f:
            if ":" not in line:
                continue
            name, rest = line.split(":", 1)
            values = rest.split()
            if name.strip() == interface and len(values) >= 9:
                return int(values[0]), int(values[8])
    raise ValueError("interface unavailable")


def network_rate(previous, current, seconds):
    if previous is None or seconds <= 0:
        return None
    rx, tx = current[0] - previous[0], current[1] - previous[1]
    if rx < 0 or tx < 0:
        return None
    return {"receivedBytesPerSecond": round(rx / seconds, 2),
            "sentBytesPerSecond": round(tx / seconds, 2)}


def read_disk():
    v = os.statvfs("/")
    used = (v.f_blocks - v.f_bfree) * v.f_frsize
    available = v.f_bavail * v.f_frsize
    total = v.f_blocks * v.f_frsize
    reserved = max(0, v.f_bfree - v.f_bavail) * v.f_frsize
    return {"total": total, "available": available, "usedBytes": used, "reservedBytes": reserved}


def read_units(units):
    results, failures = [], False
    deadline = time.monotonic() + 2.0
    for unit in units:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            failures = True
            results.append({"name": unit, "state": "unknown", "restarts": None})
            continue
        try:
            result = subprocess.run(
                ["systemctl", "show", "--no-pager", "--property=ActiveState,LoadState,NRestarts", "--", unit],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=min(0.6, remaining),
                check=False, text=True, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
            values = dict(line.split("=", 1) for line in result.stdout.splitlines() if "=" in line)
            if result.returncode != 0 or values.get("LoadState") != "loaded":
                raise ValueError("unit unavailable")
            restarts = values.get("NRestarts", "")
            results.append({"name": unit, "state": values.get("ActiveState", "unknown"),
                            "restarts": int(restarts) if restarts.isdigit() else None})
        except (OSError, ValueError, subprocess.TimeoutExpired):
            failures = True
            results.append({"name": unit, "state": "unknown", "restarts": None})
    return results, failures


class Collector:
    def __init__(self, config):
        self.node, self.units = config["nodeID"], config.get("units", [])
        if config.get("expectedHostname") and socket.gethostname() != config["expectedHostname"]:
            raise ValueError("hostname mismatch")
        if not isinstance(self.node, str) or not 1 <= len(self.node) <= 128:
            raise ValueError("invalid node")
        if not isinstance(self.units, list) or len(self.units) > 16 or any(
                not isinstance(u, str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.@:-]{0,119}\.service", u)
                for u in self.units):
            raise ValueError("invalid units")
        self.previous_cpu = self.previous_network = self.previous_time = None
        self.interface = config.get("networkInterface")
        if self.interface is not None and (not isinstance(self.interface, str) or self.interface == "lo" or
                not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,63}", self.interface)):
            raise ValueError("invalid interface")
        self.previous_interface = None
        self.sequence = 0
        self.disk, self.states = None, []
        self.slow_at = self.units_at = float("-inf")
        self.disk_error = self.unit_error = False
        with open("/proc/sys/kernel/random/boot_id") as f:
            self.boot = f.read().strip()

    def sample(self):
        now = time.monotonic()
        errors = {}
        cpu = memory = swap = network = load = None
        try:
            counters = read_cpu()
            cpu = cpu_percent(self.previous_cpu, counters)
            self.previous_cpu = counters
        except (OSError, ValueError, IndexError):
            errors["cpu"] = "unavailable"; self.previous_cpu = None
        try:
            memory, swap = read_memory()
        except (OSError, ValueError, KeyError):
            errors["memory"] = "unavailable"
        try:
            interface = self.interface or default_interface()
            if interface != self.previous_interface:
                self.previous_network = None
            counters = read_network(interface=interface)
            network = network_rate(self.previous_network, counters, now - self.previous_time) if self.previous_time else None
            if network is not None:
                network["interface"] = interface
            self.previous_network, self.previous_time = counters, now
            self.previous_interface = interface
        except (OSError, ValueError):
            errors["network"] = "external_interface_unavailable"; self.previous_network = None
        try:
            load = list(os.getloadavg())
        except OSError:
            errors["load"] = "unavailable"
        if now - self.slow_at >= 30:
            self.slow_at = now
            try:
                self.disk = read_disk(); self.disk_error = False
            except OSError:
                self.disk = None; self.disk_error = True
        if self.disk_error:
            errors["disk"] = "unavailable"
        if now - self.units_at >= 15:
            self.units_at = now
            self.states, self.unit_error = read_units(self.units)
        if self.unit_error:
            errors["units"] = "partial"
        try:
            with open("/proc/uptime") as f:
                uptime = float(f.read().split()[0])
        except (OSError, ValueError):
            uptime = now; errors["uptime"] = "monotonic_fallback"
        result = {"schema": 1, "nodeID": self.node, "hostname": socket.gethostname(),
                  "bootID": self.boot, "sequence": self.sequence, "measuredAt": time.time(),
                  "uptime": uptime, "cores": os.cpu_count() or 1,
                  "cpuPercent": cpu, "memory": memory, "swap": swap, "disk": self.disk,
                  "network": network, "load": load, "units": self.states, "errors": errors}
        self.sequence += 1
        return result


def main(config):
    # os._exit avoids trying to flush blocked stdout while terminating. The alarm
    # interrupts synchronous output/reads independently of the sampling loop.
    signal.signal(signal.SIGHUP, lambda *_: os._exit(0))
    signal.signal(signal.SIGALRM, lambda *_: os._exit(0))
    signal.signal(signal.SIGPIPE, signal.SIG_DFL)
    collector = Collector(config)
    last_heartbeat = time.monotonic()
    next_sample = last_heartbeat
    signal.setitimer(signal.ITIMER_REAL, 12)
    try:
        while True:
            now = time.monotonic()
            if now - last_heartbeat > 12:
                return
            readable, _, _ = select.select([sys.stdin], [], [], min(0.25, max(0, next_sample - now)))
            if readable:
                if not os.read(sys.stdin.fileno(), 256):
                    return
                last_heartbeat = time.monotonic()
                signal.setitimer(signal.ITIMER_REAL, 12)
            if time.monotonic() >= next_sample:
                print(json.dumps(collector.sample(), separators=(",", ":"), allow_nan=False), flush=True)
                next_sample += 3.0
                if next_sample < time.monotonic():
                    next_sample = time.monotonic() + 3.0
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)


if __name__ == "__main__":
    main(CONFIG)  # Injected by the Mac bootstrap, never taken from the environment.
