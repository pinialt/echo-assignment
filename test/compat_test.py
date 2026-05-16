"""
Compatibility test for echo-nginx:local against nginx:1.25-bookworm.

Boots both images as separate containers on random host ports (session-scoped
fixture for the default pair, module-scoped fixture for the custom-config
pair) and asserts that the same HTTP requests get matching response status,
headers, and body from each. pytest's non-zero exit on any failed assertion
satisfies the assignment's "exits non-zero on any mismatch" requirement.

Headers that legitimately vary across builds (Date, ETag, Last-Modified,
Connection, Server) are ignored for value comparison but must still be
present in both responses.

Run via: make test
       or: python3 -m pytest test/compat_test.py -v
Env: IMAGE (default echo-nginx:local), UPSTREAM (default nginx:1.25-bookworm)
"""

import gzip
import http.client
import os
import socket
import subprocess
import time
from pathlib import Path

import pytest

# ----- Config -----

UPSTREAM = os.environ.get("UPSTREAM", "nginx:1.25-bookworm")
IMAGE = os.environ.get("IMAGE", "echo-nginx:local")
FIXTURES = Path(__file__).parent / "fixtures"

# Headers we don't compare values for — inherently per-build/per-request.
HEADERS_IGNORE_VALUE = {"date", "etag", "last-modified", "connection", "server"}


# ----- Subprocess + container lifecycle -----

def silent_rm(*names: str) -> None:
    for name in names:
        subprocess.run(
            ["docker", "rm", "-f", name],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("", 0))
        return s.getsockname()[1]


def start_container(image: str, name: str, host_port: int,
                    container_port: int = 80, mounts: list[str] | None = None) -> None:
    cmd = ["docker", "run", "-d", "--name", name, "-p", f"{host_port}:{container_port}"]
    if mounts:
        for m in mounts:
            cmd.extend(["-v", m])
    cmd.append(image)
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)


def wait_ready(port: int, timeout: float = 10) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            conn = http.client.HTTPConnection("localhost", port, timeout=1)
            conn.request("GET", "/")
            conn.getresponse().read()
            conn.close()
            return True
        except Exception:
            time.sleep(0.2)
    return False


def ensure_image_present(image: str) -> None:
    res = subprocess.run(
        ["docker", "images", "--filter", f"reference={image}", "-q"],
        capture_output=True, text=True,
    )
    if not res.stdout.strip():
        pytest.exit(
            f"Image not found locally: {image}  "
            f"(build with `make image`, or pull `{image}`)",
            returncode=2,
        )


# ----- HTTP helpers -----

def fetch(port: int, path: str, method: str = "GET",
          body: bytes | None = None, extra_headers: dict | None = None):
    """Return (status, headers_dict_lowercased, body_bytes)."""
    conn = http.client.HTTPConnection("localhost", port, timeout=10)
    conn.request(method, path, body, headers=extra_headers or {})
    resp = conn.getresponse()
    body_bytes = resp.read()
    headers = {k.lower(): v for k, v in resp.headers.items()}
    conn.close()
    return resp.status, headers, body_bytes


def raw_request(port: int, payload: bytes) -> bytes:
    """Send raw bytes over a TCP socket; return whatever the server replies."""
    s = socket.create_connection(("localhost", port), timeout=5)
    s.sendall(payload)
    chunks = []
    try:
        while True:
            chunk = s.recv(4096)
            if not chunk:
                break
            chunks.append(chunk)
    except socket.timeout:
        pass
    s.close()
    return b"".join(chunks)


# ----- Assertion helper -----

def assert_responses_match(up, ours, body_decoder=None) -> None:
    """Assert two (status, headers, body) tuples agree on status, header set,
    header values (excluding inherently-varying headers), and body bytes.
    pytest's assertion introspection prints the actual differing values on
    failure — no need for custom error messages."""
    s_up, h_up, b_up = up
    s_ours, h_ours, b_ours = ours

    assert s_up == s_ours, "status mismatch"

    assert sorted(h_up) == sorted(h_ours), "header names differ"

    diffs = {
        k: (h_up.get(k), h_ours.get(k))
        for k in h_up
        if k not in HEADERS_IGNORE_VALUE and h_up.get(k) != h_ours.get(k)
    }
    assert not diffs, "header value mismatches"

    if body_decoder:
        b_up, b_ours = body_decoder(b_up), body_decoder(b_ours)
    assert b_up == b_ours, "body bytes differ"


# ----- Fixtures -----

@pytest.fixture(scope="session", autouse=True)
def _check_images_present():
    ensure_image_present(UPSTREAM)
    ensure_image_present(IMAGE)


@pytest.fixture(scope="session")
def default_pair():
    """Default container pair (no custom mounts). Session-scoped — boots once
    per pytest run, reused across all tests that use it."""
    name_up, name_ours = "echo-compat-upstream", "echo-compat-ours"
    silent_rm(name_up, name_ours)
    p_up, p_ours = free_port(), free_port()
    start_container(UPSTREAM, name_up, p_up)
    start_container(IMAGE, name_ours, p_ours)
    if not (wait_ready(p_up) and wait_ready(p_ours)):
        silent_rm(name_up, name_ours)
        pytest.fail("default container pair failed to become ready")
    yield (p_up, p_ours)
    silent_rm(name_up, name_ours)


@pytest.fixture(scope="module")
def custom_config_pair():
    """Container pair with test/fixtures/api.conf mounted into conf.d/.
    Module-scoped — boots once and reused by tests in the same module."""
    name_up, name_ours = "echo-compat-cc-upstream", "echo-compat-cc-ours"
    silent_rm(name_up, name_ours)
    p_up, p_ours = free_port(), free_port()
    mount = [f"{FIXTURES}/api.conf:/etc/nginx/conf.d/api.conf:ro"]
    start_container(UPSTREAM, name_up, p_up, container_port=8081, mounts=mount)
    start_container(IMAGE, name_ours, p_ours, container_port=8081, mounts=mount)
    if not (wait_ready(p_up) and wait_ready(p_ours)):
        silent_rm(name_up, name_ours)
        pytest.fail("custom-config container pair failed to become ready")
    yield (p_up, p_ours)
    silent_rm(name_up, name_ours)


# ----- Tests (default config) -----

def test_get_root(default_pair):
    """GET / — default welcome page."""
    p_up, p_ours = default_pair
    assert_responses_match(fetch(p_up, "/"), fetch(p_ours, "/"))


def test_get_404(default_pair):
    """GET /nonexistent — 404."""
    p_up, p_ours = default_pair
    assert_responses_match(
        fetch(p_up, "/nonexistent"),
        fetch(p_ours, "/nonexistent"),
    )


def test_head(default_pair):
    """HEAD / — headers only, empty body."""
    p_up, p_ours = default_pair
    assert_responses_match(
        fetch(p_up, "/", method="HEAD"),
        fetch(p_ours, "/", method="HEAD"),
    )


def test_gzip_negotiation(default_pair):
    """Accept-Encoding: gzip — both servers must make the same encoding
    decision (both compress, or neither) and bodies must match under that
    decision. Upstream's nginx.conf has `gzip on;` commented out, so by
    default neither server compresses regardless of the request header."""
    p_up, p_ours = default_pair
    headers = {"Accept-Encoding": "gzip"}
    up = fetch(p_up, "/", extra_headers=headers)
    ours = fetch(p_ours, "/", extra_headers=headers)
    enc_up = up[1].get("content-encoding", "")
    enc_ours = ours[1].get("content-encoding", "")

    if enc_up == "gzip" == enc_ours:
        assert_responses_match(up, ours, body_decoder=gzip.decompress)
    elif not enc_up and not enc_ours:
        assert_responses_match(up, ours)
    else:
        pytest.fail(f"encoding mismatch: upstream={enc_up!r} ours={enc_ours!r}")


def test_post_large_body(default_pair):
    """POST / with 1MB body — nginx default config rejects with 405."""
    p_up, p_ours = default_pair
    body = b"x" * (1024 * 1024)
    headers = {"Content-Type": "application/octet-stream"}
    assert_responses_match(
        fetch(p_up, "/", method="POST", body=body, extra_headers=headers),
        fetch(p_ours, "/", method="POST", body=body, extra_headers=headers),
    )


def test_malformed_request(default_pair):
    """Raw socket with broken request line — both servers reply with
    matching status line (typically `HTTP/1.1 400 Bad Request`)."""
    p_up, p_ours = default_pair
    payload = b"INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n"

    def first_line(resp: bytes) -> bytes:
        return resp.split(b"\r\n", 1)[0] if resp else b""

    up = first_line(raw_request(p_up, payload))
    ours = first_line(raw_request(p_ours, payload))
    assert up == ours, f"status line mismatch: upstream={up!r} ours={ours!r}"


# ----- Tests (custom config) -----

def test_get_api(custom_config_pair):
    """conf.d/api.conf mounted into both containers — GET /api returns
    identical responses, exercising `include /etc/nginx/conf.d/*.conf;`."""
    p_up, p_ours = custom_config_pair
    assert_responses_match(fetch(p_up, "/api"), fetch(p_ours, "/api"))
