from __future__ import annotations

import json
import os
import ssl
import subprocess
import tempfile
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


ROOT = Path(os.environ["MAITIX_FIXTURE_ROOT"]).resolve()
GRANTS: dict[str, tuple[str, bytes]] = {}
COMPLETED_GRANTS: set[str] = set()


class FixtureHandler(BaseHTTPRequestHandler):
    server_version = "MaitixBootstrapFixture/1"

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._send(HTTPStatus.OK, b"ok\n", "text/plain")
            return
        assets = {
            "/Suysker/Ticket-bootstrap/releases/download/control-test/control.age": (
                ROOT / "control.age"
            ),
            "/Suysker/Ticket-bootstrap/releases/download/control-test/truncated.age": (
                ROOT / "truncated.age"
            ),
        }
        path = assets.get(self.path)
        if path is None:
            self._send(HTTPStatus.NOT_FOUND, b"not_found\n", "text/plain")
            return
        self._send(HTTPStatus.OK, path.read_bytes(), "application/octet-stream")

    def do_POST(self) -> None:  # noqa: N802
        prefix = "/api/v1/control-hosts/enrollments/"
        if not self.path.startswith(prefix):
            self._send(HTTPStatus.NOT_FOUND, b"not_found\n", "text/plain")
            return
        remainder = self.path[len(prefix) :]
        try:
            grant_id, operation = remainder.rsplit("/", 1)
        except ValueError:
            self._send(HTTPStatus.NOT_FOUND, b"not_found\n", "text/plain")
            return
        if operation not in {"redeem", "complete"}:
            self._send(HTTPStatus.NOT_FOUND, b"not_found\n", "text/plain")
            return
        if grant_id not in {"ok", "truncated"}:
            self._send(HTTPStatus.NOT_FOUND, b"not_found\n", "text/plain")
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > 4096:
            self._send(HTTPStatus.BAD_REQUEST, b"invalid_request\n", "text/plain")
            return
        try:
            request = json.loads(self.rfile.read(length))
        except (UnicodeDecodeError, json.JSONDecodeError):
            self._send(HTTPStatus.BAD_REQUEST, b"invalid_request\n", "text/plain")
            return
        if (
            set(request) != {"protocol", "recipient", "code"}
            or request["protocol"] != "maitix-control-bootstrap-v3"
            or request["code"] != "TEST-CODE"
            or not isinstance(request["recipient"], str)
            or not request["recipient"].startswith("age1")
        ):
            self._send(HTTPStatus.UNAUTHORIZED, b"denied\n", "text/plain")
            return
        recipient = request["recipient"]
        if operation == "complete":
            claimed = GRANTS.get(grant_id)
            if claimed is None or claimed[0] != recipient:
                self._send(HTTPStatus.CONFLICT, b"not_claimed\n", "text/plain")
                return
            COMPLETED_GRANTS.add(grant_id)
            self._send(HTTPStatus.NO_CONTENT, b"", "application/json")
            return
        if grant_id in COMPLETED_GRANTS:
            self._send(HTTPStatus.GONE, b"completed\n", "text/plain")
            return
        claimed = GRANTS.get(grant_id)
        if claimed is not None:
            if claimed[0] != recipient:
                self._send(HTTPStatus.CONFLICT, b"already_claimed\n", "text/plain")
                return
            self._send_seed(claimed[1])
            return
        seed = ROOT / f"seed-{grant_id}.tar.gz"
        with tempfile.NamedTemporaryFile(dir=ROOT, delete=False) as output:
            output_path = Path(output.name)
        try:
            subprocess.run(
                [
                    "age",
                    "--encrypt",
                    "--recipient",
                    recipient,
                    "--output",
                    str(output_path),
                    str(seed),
                ],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            ciphertext = output_path.read_bytes()
        finally:
            output_path.unlink(missing_ok=True)
        GRANTS[grant_id] = (recipient, ciphertext)
        self._send_seed(ciphertext)

    def _send_seed(self, ciphertext: bytes) -> None:
        self._send(
            HTTPStatus.OK,
            ciphertext,
            "application/vnd.maitix.control-seed.v3+age",
        )

    def _send(self, status: HTTPStatus, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        return


def main() -> None:
    server = ThreadingHTTPServer(("0.0.0.0", 443), FixtureHandler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(ROOT / "server.crt", ROOT / "server.key")
    server.socket = context.wrap_socket(server.socket, server_side=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
