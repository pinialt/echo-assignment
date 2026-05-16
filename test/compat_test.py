#!/usr/bin/env python3
"""
Compatibility test for echo-nginx:local against nginx:1.25-bookworm.

Boots both images as separate containers on random host ports, issues the
same HTTP requests against each, and asserts response status + headers +
body match. Exits non-zero on any mismatch.

Headers that legitimately vary across builds (Date, ETag, Last-Modified,
Connection, Server) are ignored for value comparison but must still be
present in both responses.

Run via: make test
       or: python3 test/compat_test.py
Env: IMAGE (default echo-nginx:local), UPSTREAM (default nginx:1.25-bookworm)
     NO_COLOR=1 to disable ANSI colors.
"""

import gzip
import http.client
import os
import socket
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

# ----- Config -----

UPSTREAM = os.environ.get("UPSTREAM", "nginx:1.25-bookworm")
IMAGE = os.environ.get("IMAGE", "echo-nginx:local")
NAME_UP = "echo-compat-upstream"
NAME_OURS = "echo-compat-ours"
FIXTURES = Path(__file__).parent / "fixtures"

# Headers we don't compare values for — inherently per-build/per-request.
HEADERS_IGNORE_VALUE = {"date", "etag", "last-modified", "connection", "server"}

PASS = 0
FAIL = 0


# ----- ANSI color helpers (auto-disable when stdout isn't a tty or NO_COLOR is set) -----

USE_COLOR = sys.stdout.isatty() and "NO_COLOR" not in os.environ


def _ansi(code: str, text: str) -> str:
    return f"\033[{code}m{text}\033[0m" if USE_COLOR else text


def green(t: str) -> str: return _ansi("32", t)
def red(t: str) -> str:   return _ansi("31", t)
def cyan(t: str) -> str:  return _ansi("36;1", t)
def yellow(t: str) -> str: return _ansi("33", t)
def dim(t: str) -> str:   return _ansi("2", t)
def bold(t: str) -> str:  return _ansi("1", t)


# ----- Subprocess + container lifecycle -----

def run(cmd, **kw):
    return subprocess.run(cmd, check=True, **kw)


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
    run(cmd, stdout=subprocess.DEVNULL)


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


@contextmanager
def container_pair(container_port: int = 80, mounts: list[str] | None = None):
    """Yield (port_upstream, port_ours) for a fresh, ready container pair.
    Guarantees cleanup on exit. Yields None if either container fails to start."""
    up = "echo-compat-aux-upstream"
    ours = "echo-compat-aux-ours"
    silent_rm(up, ours)
    p_up, p_ours = free_port(), free_port()
    try:
        start_container(UPSTREAM, up, p_up, container_port, mounts)
        start_container(IMAGE, ours, p_ours, container_port, mounts)
        if wait_ready(p_up) and wait_ready(p_ours):
            yield (p_up, p_ours)
        else:
            yield None
    finally:
        silent_rm(up, ours)


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


# ----- Assertion helpers -----

def _short(v) -> str:
    s = repr(v)
    return s if len(s) <= 80 else s[:80] + "…"


def check(name: str, expected, actual, summary: str | None = None) -> None:
    """summary is shown dim on PASS to convey what was compared.
    On FAIL, full expected/actual are printed (truncated to 200 chars)."""
    global PASS, FAIL
    s = summary or f"upstream={_short(expected)}  ours={_short(actual)}"
    if expected == actual:
        PASS += 1
        print(f"  {green('PASS')}  {name:<14}  {dim(s)}")
    else:
        FAIL += 1
        e, a = repr(expected), repr(actual)
        if len(e) > 200:
            e = e[:200] + "…"
        if len(a) > 200:
            a = a[:200] + "…"
        print(f"  {red('FAIL')}  {name:<14}  {dim(s)}")
        print(f"        upstream: {e}")
        print(f"        ours:     {a}")


def info(name: str, msg: str) -> None:
    print(f"  {yellow('INFO')}  {name:<14}  {dim(msg)}")


def section(label: str) -> None:
    print(f"\n{cyan('=== ' + label + ' ===')}")


def compare_responses(label: str, up, ours, body_decoder=None) -> None:
    """Compare two (status, headers, body) tuples on status / header set / header values / body."""
    section(label)
    s_up, h_up, b_up = up
    s_ours, h_ours, b_ours = ours

    check("status code", s_up, s_ours,
          summary=f"upstream={s_up}  ours={s_ours}")

    check("header names", sorted(h_up), sorted(h_ours),
          summary=f"upstream={len(h_up)} headers  ours={len(h_ours)} headers")

    diffs = [
        (k, h_up.get(k), h_ours.get(k))
        for k in h_up
        if k not in HEADERS_IGNORE_VALUE and h_up.get(k) != h_ours.get(k)
    ]
    check("header values", [], diffs,
          summary=f"{len(diffs)} value diffs (excl. {', '.join(sorted(HEADERS_IGNORE_VALUE))})")

    if body_decoder:
        b_up, b_ours = body_decoder(b_up), body_decoder(b_ours)
    check("body bytes", b_up, b_ours,
          summary=f"upstream={len(b_up)} bytes  ours={len(b_ours)} bytes")


# ----- Scenarios (shared pair: take ports, run against them) -----

def scenario_get_root(p_up, p_ours):
    compare_responses("GET / — default welcome page",
                      fetch(p_up, "/"), fetch(p_ours, "/"))


def scenario_get_404(p_up, p_ours):
    compare_responses("GET /nonexistent — 404",
                      fetch(p_up, "/nonexistent"), fetch(p_ours, "/nonexistent"))


def scenario_head(p_up, p_ours):
    compare_responses("HEAD / — headers only, no body",
                      fetch(p_up, "/", method="HEAD"), fetch(p_ours, "/", method="HEAD"))


def scenario_gzip(p_up, p_ours):
    """Both servers must make the same Accept-Encoding decision (either both
    gzip the body, or both ignore the request header) and bodies must match
    under that decision. Upstream's nginx.conf has `gzip on;` commented, so
    the default behavior is "both ignore" — we exercise the negotiation path
    on both ends regardless."""
    headers = {"Accept-Encoding": "gzip"}
    up = fetch(p_up, "/", extra_headers=headers)
    ours = fetch(p_ours, "/", extra_headers=headers)
    enc_up = up[1].get("content-encoding", "")
    enc_ours = ours[1].get("content-encoding", "")

    section("GET / with Accept-Encoding: gzip")
    if enc_up == "gzip" == enc_ours:
        info("encoding", "both compressed (Content-Encoding: gzip) — comparing decoded bodies")
        up = (up[0], up[1], gzip.decompress(up[2]))
        ours = (ours[0], ours[1], gzip.decompress(ours[2]))
    elif not enc_up and not enc_ours:
        info("encoding", "neither compressed (`gzip on;` is off in upstream config) — comparing raw bodies")
    else:
        info("encoding", f"MISMATCH upstream={enc_up!r}  ours={enc_ours!r}")

    s_up, h_up, b_up = up
    s_ours, h_ours, b_ours = ours
    check("status code", s_up, s_ours,
          summary=f"upstream={s_up}  ours={s_ours}")
    check("header names", sorted(h_up), sorted(h_ours),
          summary=f"upstream={len(h_up)} headers  ours={len(h_ours)} headers")
    diffs = [
        (k, h_up.get(k), h_ours.get(k))
        for k in h_up
        if k not in HEADERS_IGNORE_VALUE and h_up.get(k) != h_ours.get(k)
    ]
    check("header values", [], diffs,
          summary=f"{len(diffs)} value diffs")
    check("body bytes", b_up, b_ours,
          summary=f"upstream={len(b_up)} bytes  ours={len(b_ours)} bytes")


def scenario_post_large(p_up, p_ours):
    """1 MB POST against /. nginx default config rejects non-GET/HEAD on /
    with 405 Method Not Allowed; both servers should agree."""
    body = b"x" * (1024 * 1024)
    headers = {"Content-Type": "application/octet-stream"}
    compare_responses(
        "POST / 1MB body — both reject with 405",
        fetch(p_up, "/", method="POST", body=body, extra_headers=headers),
        fetch(p_ours, "/", method="POST", body=body, extra_headers=headers),
    )


def scenario_malformed(p_up, p_ours):
    """Raw socket: send a broken request line, expect a matching 400 status line."""
    section("malformed request — raw socket, expect 400")
    payload = b"INVALID / HTTP/1.1\r\nHost: localhost\r\n\r\n"

    def first_line(resp: bytes) -> bytes:
        return resp.split(b"\r\n", 1)[0] if resp else b""

    up = first_line(raw_request(p_up, payload))
    ours = first_line(raw_request(p_ours, payload))
    check("status line", up, ours,
          summary=f"upstream={up.decode(errors='replace')!r}  ours={ours.decode(errors='replace')!r}")


# ----- Scenarios (standalone: manage their own container pair) -----

def scenario_custom_config():
    """Mount test/fixtures/api.conf into /etc/nginx/conf.d/ on both containers
    and verify they serve the user-defined endpoint identically."""
    mount = f"{FIXTURES}/api.conf:/etc/nginx/conf.d/api.conf:ro"
    with container_pair(container_port=8081, mounts=[mount]) as ports:
        if ports is None:
            global FAIL
            FAIL += 1
            print(f"  {red('FAIL')}  custom-config container pair failed to become ready")
            return
        p_up, p_ours = ports
        compare_responses(
            "GET /api on a user-mounted conf.d/api.conf",
            fetch(p_up, "/api"), fetch(p_ours, "/api"),
        )


SHARED_SCENARIOS = [
    scenario_get_root,
    scenario_get_404,
    scenario_head,
    scenario_gzip,
    scenario_post_large,
    scenario_malformed,
]

STANDALONE_SCENARIOS = [
    scenario_custom_config,
]


# ----- Runner -----

def ensure_image_present(image: str) -> None:
    # `docker image inspect <short-name>` regressed in Docker 29.x;
    # `docker images --filter reference=` works on both short and qualified names.
    res = subprocess.run(
        ["docker", "images", "--filter", f"reference={image}", "-q"],
        capture_output=True, text=True,
    )
    if not res.stdout.strip():
        print(f"{red('ERROR')}: image not found locally: {image}", file=sys.stderr)
        print(f"        (build with `make image`, or pull `{image}`)", file=sys.stderr)
        sys.exit(2)


def safe_run(scenario, *args) -> None:
    """Run a scenario, count any raised exception as a single failure."""
    global FAIL
    try:
        scenario(*args)
    except Exception as e:
        FAIL += 1
        print(f"  {red('FAIL')}  scenario {scenario.__name__} raised {type(e).__name__}: {e}")


def main():
    print(bold(f"Comparing  upstream={UPSTREAM}  vs  ours={IMAGE}"))

    ensure_image_present(UPSTREAM)
    ensure_image_present(IMAGE)

    silent_rm(NAME_UP, NAME_OURS)
    p_up, p_ours = free_port(), free_port()
    start_container(UPSTREAM, NAME_UP, p_up)
    start_container(IMAGE, NAME_OURS, p_ours)

    try:
        if not (wait_ready(p_up) and wait_ready(p_ours)):
            print(f"{red('ERROR')}: a container failed to become ready", file=sys.stderr)
            sys.exit(2)
        for sc in SHARED_SCENARIOS:
            safe_run(sc, p_up, p_ours)
    finally:
        silent_rm(NAME_UP, NAME_OURS)

    for sc in STANDALONE_SCENARIOS:
        safe_run(sc)

    verdict = green("all passed") if FAIL == 0 else red(f"{FAIL} failed")
    print(f"\n{bold('Result:')} {PASS} pass, {FAIL} fail  ({verdict})")
    sys.exit(0 if FAIL == 0 else 1)


if __name__ == "__main__":
    main()
