"""Minimal mock of the Network Monitor device API (tests only).

Keys:
  nm_docker_test_key_1234567890   -> enabled device
  nm_docker_disabled_key_12345    -> enabled=false
  anything else                   -> 401
Received payloads are written to $MOCK_DATA_DIR/received.json.
Schedule returned for enabled devices: $MOCK_INTERVAL (60) / $MOCK_OFFSET (10).
"""
import http.server
import json
import os

DEVICES = {
    "nm_docker_test_key_1234567890": {"device_key": "docker-test", "enabled": True},
    "nm_docker_disabled_key_12345": {"device_key": "docker-disabled", "enabled": False},
}
DATA_DIR = os.environ.get("MOCK_DATA_DIR", "/tmp")
INTERVAL = int(os.environ.get("MOCK_INTERVAL", "60"))
OFFSET = int(os.environ.get("MOCK_OFFSET", "10"))
seen = set()


class Handler(http.server.BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _device(self):
        device = DEVICES.get(self.headers.get("X-API-Key", ""))
        if device is None:
            self._send(401, {"error": "unauthorized"})
        return device

    def do_GET(self):
        if self.path != "/api/network/config":
            return self._send(404, {"error": "not found"})
        device = self._device()
        if device:
            self._send(200, {**device, "interval_minutes": INTERVAL, "offset_minutes": OFFSET})

    def do_POST(self):
        if self.path != "/api/network/speedtests":
            return self._send(404, {"error": "not found"})
        if not self._device():
            return
        payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(os.path.join(DATA_DIR, "received.json"), "w") as f:
            json.dump(payload, f)
        if payload.get("result_id") in seen:
            return self._send(200, {"duplicate": True, "id": 7})
        seen.add(payload.get("result_id"))
        self._send(201, {"id": 7})

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("0.0.0.0", 3077), Handler).serve_forever()
