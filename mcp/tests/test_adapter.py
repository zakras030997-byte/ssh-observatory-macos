from contextlib import contextmanager
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

SOURCE = Path(__file__).resolve().parents[1] / 'adapter.py'
spec = importlib.util.spec_from_file_location('observatory_adapter', SOURCE)
adapter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(adapter)


@contextmanager
def app_server(response, mode=0o600):
    with tempfile.TemporaryDirectory(prefix='omcp-', dir='/tmp') as raw:
        directory = Path(raw).resolve()
        directory.chmod(0o700)
        path = directory / 'hub.sock'
        listener = socket.socket(socket.AF_UNIX)
        try:
            listener.bind(str(path)); path.chmod(mode)
        except BaseException:
            listener.close()
            raise
        listener.listen(1); listener.settimeout(2)
        observations = []
        def serve():
            try:
                connection, _ = listener.accept()
                with connection:
                    connection.settimeout(2)
                    data = bytearray()
                    while b'\n' not in data:
                        part = connection.recv(4096)
                        if not part:
                            return
                        data.extend(part)
                    request = json.loads(data)
                    observations.append(request)
                    reply = response(request)
                    connection.sendall(reply if isinstance(reply, bytes) else json.dumps(reply).encode() + b'\n')
            except (socket.timeout, OSError):
                pass
        thread = threading.Thread(target=serve)
        thread.start()
        try:
            yield path, observations
        finally:
            listener.close(); thread.join(timeout=3)


def ok(request):
    return {'id': request['id'], 'ok': True, 'result': {'connected': True}}


class DummyIPC:
    def __init__(self):
        self.calls = []
        self.error = None
    def call(self, method, params):
        self.calls.append((method, params))
        if self.error:
            raise adapter.IPCError(self.error)
        return {'method': method, 'params': params}


def initialize(server, version='2025-06-18'):
    reply = server.dispatch({'jsonrpc': '2.0', 'id': 1, 'method': 'initialize',
        'params': {'protocolVersion': version, 'capabilities': {},
                   'clientInfo': {'name': 'fixture', 'version': '1'}}})
    server.dispatch({'jsonrpc': '2.0', 'method': 'notifications/initialized'})
    return reply


class IPCTests(unittest.TestCase):
    def test_real_unix_request_and_kernel_peer_identity(self):
        with app_server(ok) as (path, seen):
            result = adapter.AppIPC(path).call('hub.status', {})
            self.assertEqual(result, {'connected': True})
            self.assertEqual(seen[0]['version'], 1)
            self.assertEqual(seen[0]['method'], 'hub.status')
            self.assertEqual(set(seen[0]), {'version', 'id', 'method', 'params'})

    def test_app_offline_is_safe(self):
        with tempfile.TemporaryDirectory(dir='/tmp') as raw:
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(Path(raw).resolve() / 'missing.sock').call('hub.status', {})
            self.assertEqual(raised.exception.code, 'app_offline')
            self.assertNotIn(raw, raised.exception.message)

    def test_world_accessible_socket_is_rejected_before_request(self):
        with app_server(ok, mode=0o666) as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('hub.status', {})
            self.assertEqual(raised.exception.code, 'unsafe_socket')
            self.assertEqual(seen, [])

    def test_group_writable_parent_is_rejected(self):
        with app_server(ok) as (path, seen):
            path.parent.chmod(0o770)
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('hub.status', {})
            self.assertEqual(raised.exception.code, 'unsafe_socket')
            self.assertEqual(seen, [])

    def test_symlink_parent_is_rejected(self):
        with app_server(ok) as (path, seen):
            alias = path.parent / 'alias'; alias.symlink_to(path.parent, target_is_directory=True)
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(alias / 'hub.sock').call('hub.status', {})
            self.assertEqual(raised.exception.code, 'unsafe_socket')

    def test_different_kernel_peer_uid_is_rejected(self):
        with app_server(ok) as (path, seen):
            with patch.object(adapter, 'peer_uid', return_value=os.getuid() + 1):
                with self.assertRaises(adapter.IPCError) as raised:
                    adapter.AppIPC(path).call('hub.status', {})
                self.assertEqual(raised.exception.code, 'ipc_unauthorized')

    def test_mismatched_reply_id_is_rejected(self):
        with app_server(lambda r: {'id': 'different', 'ok': True, 'result': {}}) as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('hub.status', {})
            self.assertEqual(raised.exception.code, 'ipc_invalid')

    def test_oversize_reply_is_rejected(self):
        with app_server(lambda r: b'x' * (adapter.MAX_REPLY + 1)) as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('hub.status', {})
            self.assertEqual(raised.exception.code, 'ipc_oversize')

    def test_error_never_exposes_app_message(self):
        secret = 'private credential must not escape'
        with app_server(lambda r: {'id': r['id'], 'ok': False, 'error': {'code': 'unavailable', 'message': secret}}) as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('hub.status', {})
            self.assertNotIn(secret, str(raised.exception))
            self.assertNotIn(secret, raised.exception.message)

    def test_native_route_conflict_has_safe_actionable_code(self):
        with app_server(lambda r: {'id': r['id'], 'ok': False, 'error': {'code': 'home_route_conflict', 'message': 'private details'}}) as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('home.connect', {'route': 'lan'})
            self.assertEqual(raised.exception.code, 'home_route_conflict')
            self.assertNotIn('private details', raised.exception.message)

    def test_accidentally_returned_credentials_are_blocked(self):
        with app_server(lambda r: {'id': r['id'], 'ok': True, 'result': {'nested': {'session_token': 'DO_NOT_EXPORT'}}}) as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('home.status', {})
            self.assertEqual(raised.exception.code, 'ipc_unsafe_response')

    def test_multiple_response_frames_are_rejected(self):
        with app_server(lambda r: json.dumps(ok(r)).encode() + b'\n{}\n') as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('hub.status', {})
            self.assertEqual(raised.exception.code, 'ipc_invalid')

    def test_truncated_response_is_rejected(self):
        with app_server(lambda r: b'{"id":') as (path, seen):
            with self.assertRaises(adapter.IPCError) as raised:
                adapter.AppIPC(path).call('hub.status', {})
            self.assertEqual(raised.exception.code, 'ipc_invalid')


class ProtocolTests(unittest.TestCase):
    def setUp(self):
        self.ipc = DummyIPC()
        self.server = adapter.MCPServer(self.ipc)

    def test_both_protocol_versions_initialize(self):
        for version in adapter.SUPPORTED_VERSIONS:
            s = adapter.MCPServer(self.ipc)
            self.assertEqual(initialize(s, version)['result']['protocolVersion'], version)

    def test_unsupported_version_negotiates_supported_version(self):
        self.assertEqual(initialize(self.server, '2099-01-01')['result']['protocolVersion'], adapter.SUPPORTED_VERSIONS[0])

    def test_tools_not_available_before_initialized(self):
        result = self.server.dispatch({'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'})
        self.assertEqual(result['error']['code'], -32002)

    def test_unknown_method_is_protocol_error(self):
        initialize(self.server)
        result = self.server.dispatch({'jsonrpc': '2.0', 'id': 2, 'method': 'ssh.execute', 'params': {'command': 'anything'}})
        self.assertEqual(result['error']['code'], -32601)
        self.assertEqual(self.ipc.calls, [])

    def test_list_has_only_the_fifteen_allowed_tools(self):
        initialize(self.server)
        result = self.server.dispatch({'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'})
        tools = result['result']['tools']
        self.assertEqual({t["name"] for t in tools}, {"observatory_status","observatory_nodes","observatory_telemetry","observatory_connect","observatory_inspect","observatory_ssh_exec","observatory_ssh_open","observatory_ssh_read","observatory_ssh_write","observatory_ssh_close","observatory_sftp_transfer","observatory_home_status","observatory_home_connect","observatory_home_overview","observatory_home_audit"})
        self.assertFalse(any('apply' in t['name'] or 'shell' in t['name'] or 'key' in t['name'] for t in tools))
        for t in tools:
            self.assertFalse(t['inputSchema']['additionalProperties'])
            self.assertEqual(t['annotations']['readOnlyHint'], t['name'] not in ['observatory_connect', 'observatory_home_connect', 'observatory_ssh_exec', 'observatory_ssh_open', 'observatory_ssh_read', 'observatory_ssh_write', 'observatory_ssh_close', 'observatory_sftp_transfer'])

    def call(self, name, arguments):
        return self.server.dispatch({'jsonrpc': '2.0', 'id': 9, 'method': 'tools/call',
            'params': {'name': name, 'arguments': arguments}})

    def test_home_default_route_is_lan(self):
        initialize(self.server)
        out = self.call('observatory_home_connect', {})
        self.assertFalse(out['result']['isError'])
        self.assertEqual(self.ipc.calls, [('home.connect', {'route': 'lan'})])

    def test_fixed_inspection_is_forwarded_as_typed_data(self):
        initialize(self.server)
        self.call('observatory_inspect', {'node_id': 'node-kz', 'check': 'services'})
        self.assertEqual(self.ipc.calls, [('node.inspect', {'node_id': 'node-kz', 'check': 'services'})])

    def test_argument_injection_is_rejected_before_ipc(self):
        initialize(self.server)
        cases = [
            ('observatory_connect', {'node_id': 'kz; echo token'}),
            ('observatory_connect', {'node_id': '$(id)'}),
            ('observatory_connect', {'node_id': '../../ssh'}),
            ('observatory_connect', {'node_id': 'kz', 'command': 'sudo something'}),
            ('observatory_inspect', {'node_id': 'kz', 'check': 'shell'}),
            ('observatory_home_connect', {'route': 'http://example.invalid'}),
            ('observatory_home_overview', {'token': 'secret'}),
        ]
        for name, params in cases:
            self.assertEqual(self.call(name, params)['error']['code'], -32602)
        self.assertEqual(self.ipc.calls, [])

    def test_tool_call_notification_cannot_connect(self):
        initialize(self.server)
        self.assertIsNone(self.server.dispatch({'jsonrpc': '2.0', 'method': 'tools/call',
            'params': {'name': 'observatory_connect', 'arguments': {'node_id': 'kz'}}}))
        self.assertEqual(self.ipc.calls, [])

    def test_app_offline_is_tool_error_not_traceback(self):
        initialize(self.server); self.ipc.error = 'app_offline'
        out = self.call('observatory_status', {})
        self.assertTrue(out['result']['isError'])
        text = out['result']['content'][0]['text']
        self.assertEqual(json.loads(text)['error']['code'], 'app_offline')
        self.assertNotIn('Traceback', text)

    def test_stdio_outputs_jsonrpc_only(self):
        frames = [
            {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2024-11-05', 'capabilities': {}, 'clientInfo': {'name': 'fixture', 'version': '1'}}},
            {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
            {'jsonrpc': '2.0', 'id': 2, 'method': 'ping'},
            {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/list'},
        ]
        p = subprocess.run([sys.executable, '-B', str(SOURCE)], input=b''.join(json.dumps(v).encode() + b'\n' for v in frames), capture_output=True, timeout=5)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stderr, b'')
        replies = [json.loads(line) for line in p.stdout.splitlines()]
        self.assertEqual([v['id'] for v in replies], [1, 2, 3])

    def test_server_entry_has_no_startup_output(self):
        p = subprocess.run([sys.executable, '-B', str(SOURCE.with_name('server.py'))], input=b'', capture_output=True, timeout=5)
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'')
        self.assertEqual(p.stderr, b'')

    def test_oversize_stdio_frame_is_drained_then_ping_works(self):
        data = b'x' * (adapter.MAX_REQUEST + 50) + b'\n' + b'{"jsonrpc":"2.0","id":2,"method":"ping"}\n'
        output = io.BytesIO()
        adapter.run_stdio(io.BytesIO(data), output, self.server)
        lines = [json.loads(v) for v in output.getvalue().splitlines()]
        self.assertEqual(lines[0]['error']['code'], -32600)
        self.assertEqual(lines[1]['result'], {})

    def test_duplicate_json_keys_and_nonfinite_numbers_are_parse_errors(self):
        data = b'{"jsonrpc":"2.0","id":1,"id":2,"method":"ping"}\n{"jsonrpc":"2.0","id":NaN,"method":"ping"}\n'
        output = io.BytesIO(); adapter.run_stdio(io.BytesIO(data), output, self.server)
        self.assertTrue(all(json.loads(v)['error']['code'] == -32700 for v in output.getvalue().splitlines()))


if __name__ == '__main__':
    unittest.main()
