#!/usr/bin/env python3
"""Real loopback CONNECT/TLS regression using only throwaway synthetic data.

Generate an identity with the real CLI. Its root is loaded only into Python's
SSLContext; no OS trust, proxy profile or Core Location setting is changed.
Run `swift build --product location-bridge` first, or set LOCATION_BRIDGE_CLI.
"""
import json
import os
from pathlib import Path
import platform
import selectors
import signal
import socket
import ssl
import struct
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = Path(os.environ.get("LOCATION_BRIDGE_CLI", ROOT / ".build/debug/location-bridge"))
HOSTS = ("gs-loc.apple.com", "gs-loc-cn.apple.com")
SYNTHETIC_WIFI = b"synthetic-radio"  # Deliberately not a real Wi-Fi identifier.
RESPONSE_PREFIX = bytes([0, 1, 0, 0, 0, 1, 0, 0])


def varint(value):
    encoded = bytearray()
    while value > 127:
        encoded.append((value & 127) | 128)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def synthetic_request():
    wifi = b"\x0a" + varint(len(SYNTHETIC_WIFI)) + SYNTHETIC_WIFI
    payload = b"\x12" + varint(len(wifi)) + wifi + b"\xa0\x06\x07"
    strings = (b"en", b"test.location-bridge.invalid", b"synthetic")
    envelope = struct.pack(">H", 1)
    envelope += b"".join(struct.pack(">H", len(item)) + item for item in strings)
    return envelope + struct.pack(">II", 1, len(payload)) + payload


def protobuf_fields(data):
    """Decode the limited protobuf wire types in the synthetic response."""
    offset = 0
    fields = {}

    def integer():
        nonlocal offset
        value = 0
        for shift in range(0, 70, 7):
            if offset >= len(data):
                raise AssertionError("Truncated protobuf integer")
            byte = data[offset]
            offset += 1
            value |= (byte & 127) << shift
            if not byte & 128:
                return value
        raise AssertionError("Oversized protobuf integer")

    while offset < len(data):
        tag = integer()
        number, wire = tag >> 3, tag & 7
        if not number:
            raise AssertionError("Invalid protobuf field zero")
        if wire == 0:
            value = integer()
        elif wire in (1, 2, 5):
            length = integer() if wire == 2 else (8 if wire == 1 else 4)
            if length > len(data) - offset:
                raise AssertionError("Truncated protobuf field")
            value = data[offset:offset + length]
            offset += length
        else:
            raise AssertionError("Unexpected wire type in synthetic response")
        fields.setdefault(number, []).append(value)
    return fields


def receive_header(connection, maximum=65536):
    data = bytearray()
    while not data.endswith(b"\r\n\r\n"):
        if len(data) >= maximum:
            raise AssertionError("Response header exceeds fixture bound")
        try:
            chunk = connection.recv(1)
        except (ConnectionResetError, ssl.SSLEOFError):
            break
        if not chunk:
            break
        data.extend(chunk)
    return bytes(data)


class ServerFixture:
    def __init__(self, directory):
        if not CLI.is_file():
            raise AssertionError("Build location-bridge or set LOCATION_BRIDGE_CLI")
        self.directory = Path(directory) / "identity"
        generated = subprocess.run([str(CLI), "init-identity", "--directory", str(self.directory)], capture_output=True, text=True, timeout=30)
        if generated.returncode:
            raise AssertionError("Real CLI identity generation failed: " + generated.stderr)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            self.port = probe.getsockname()[1]
        self.process = subprocess.Popen([str(CLI), "serve", "--directory", str(self.directory), "--latitude", "0", "--longitude", "0", "--port", str(self.port)], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        self.context.load_verify_locations(cafile=str(self.directory / "root.pem"))
        try:
            self._wait_ready()
        except BaseException:
            self.stop()
            raise

    def _wait_ready(self):
        deadline = time.monotonic() + 10
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                if self.process.poll() is not None:
                    _, errors = self.process.communicate()
                    raise AssertionError("Real CLI service exited before readiness: " + errors)
                if not selector.select(timeout=0.1):
                    continue
                line = self.process.stdout.readline()
                if not line:
                    continue
                event = json.loads(line)
                if event.get("event") == "ready":
                    if event.get("port") != self.port or event.get("address") != "127.0.0.1":
                        raise AssertionError("Unexpected listener boundary")
                    return
        raise AssertionError("Real CLI service readiness timed out")

    def connect(self, host=HOSTS[0], port=443):
        connection = socket.create_connection(("127.0.0.1", self.port), timeout=5)
        connection.settimeout(5)
        connection.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode("ascii"))
        return connection, receive_header(connection)

    def tls(self, host=HOSTS[0]):
        connection, header = self.connect(host)
        if not header.startswith(b"HTTP/1.1 200 "):
            connection.close()
            raise AssertionError("Valid CONNECT was rejected")
        try:
            return self.context.wrap_socket(connection, server_hostname=host)
        except BaseException:
            connection.close()
            raise

    def response(self, host):
        body = synthetic_request()
        request = (f"POST /clls/wloc HTTP/1.1\r\nHost: {host}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode("ascii") + body
        with self.tls(host) as connection:
            connection.sendall(request)
            header = receive_header(connection)
            if not header.startswith(b"HTTP/1.1 200 "):
                raise AssertionError("Synthetic location request did not return HTTP 200")
            lines = header.decode("ascii").split("\r\n")
            fields = dict(line.split(": ", 1) for line in lines[1:] if line)
            count = int(fields["Content-Length"])
            if count > 65545:
                raise AssertionError("Response envelope exceeds its 16-bit payload bound")
            response = bytearray()
            while len(response) < count:
                chunk = connection.recv(count - len(response))
                if not chunk:
                    raise AssertionError("Response ended before Content-Length")
                response.extend(chunk)
            if connection.recv(1):
                raise AssertionError("Unexpected bytes after the single response")
            return bytes(response)

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        try:
            self.process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.communicate()
            raise AssertionError("SIGTERM did not stop the real service")
        if self.process.returncode != 0:
            raise AssertionError("Service did not exit cleanly")


MACOS = platform.mac_ver()[0]
SUPPORTED = bool(MACOS) and int(MACOS.split(".", 1)[0]) >= 15


@unittest.skipUnless(SUPPORTED, "Memory-only PKCS#12 service import requires macOS 15+")
class TLSRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="locationbridge-tls-test-")
        try:
            cls.server = ServerFixture(cls.temporary.name)
        except BaseException:
            cls.temporary.cleanup()
            raise

    @classmethod
    def tearDownClass(cls):
        try:
            cls.server.stop()
        finally:
            cls.temporary.cleanup()

    def test_01_real_tls_and_synthetic_wire_response_for_both_hosts(self):
        responses = [self.server.response(host) for host in HOSTS]
        self.assertEqual(responses[0], responses[1], "Synthetic response must have stable framing/content")
        response = responses[0]
        self.assertEqual(response[:8], RESPONSE_PREFIX)
        self.assertEqual(struct.unpack(">H", response[8:10])[0], len(response) - 10)
        model = protobuf_fields(response[10:])
        self.assertEqual(model[100], [7], "Unknown request wire field must survive")
        self.assertEqual(len(model[2]), 1)
        wifi = protobuf_fields(model[2][0])
        self.assertEqual(wifi[1], [SYNTHETIC_WIFI])
        location = protobuf_fields(wifi[2][0])
        self.assertEqual(location[1], [0])
        self.assertEqual(location[2], [0])
        self.assertEqual(location[3], [10])

    def test_02_unknown_host_and_port_fail_closed(self):
        for host, port in [("example.invalid", 443), (HOSTS[0], 80)]:
            with self.subTest(host=host, port=port):
                connection, header = self.server.connect(host, port)
                with connection:
                    self.assertFalse(header.startswith(b"HTTP/1.1 200 "))

    def test_03_oversized_and_ambiguous_body_framing_fail_closed(self):
        headers = ["Content-Length: 1048577\r\n", "Content-Length: 1\r\nContent-Length: 1\r\n"]
        for header in headers:
            with self.subTest(framing=header.split(":", 1)[0]):
                with self.server.tls() as connection:
                    connection.sendall((f"POST /clls/wloc HTTP/1.1\r\nHost: {HOSTS[0]}\r\n" + header + "\r\n").encode("ascii"))
                    self.assertFalse(receive_header(connection).startswith(b"HTTP/1.1 200 "))

    def test_99_sigterm_closes_listener(self):
        self.server.stop()
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                with socket.create_connection(("127.0.0.1", self.server.port), timeout=0.1):
                    pass
            except OSError:
                return
            time.sleep(0.05)
        self.fail("Listener remained open after clean SIGTERM")


if __name__ == "__main__":
    unittest.main(verbosity=2)
