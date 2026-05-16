#!/usr/bin/env bash
# Drop-in parity audit. Boots our image alongside upstream and runs 12 checks
# (HTTP behavior, manifest, config files, filesystem layout) against the
# nginx:1.25-bookworm baseline. Informational — prints diffs without aborting;
# the operator reads. Expected divergences are called out per section.
#
# Run via `make smoke`. Requires `make build && make image` to have run first.

set -u

IMAGE="${IMAGE:-echo-nginx:local}"
UPSTREAM="${UPSTREAM:-nginx:1.25-bookworm}"
NAME=echo-nginx-smoke
PORT=8080

section() { printf '\n=== %s ===\n' "$*"; }

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

cleanup
docker run -d --name "$NAME" -p "$PORT:80" "$IMAGE" >/dev/null

section "1. Entrypoint logs"
docker logs "$NAME" 2>&1 | head -20
# Expect: "Sourcing /docker-entrypoint.d/15-local-resolvers.envsh"
# Expect: "info: Enabled listen on IPv6 in /etc/nginx/conf.d/default.conf"
# Expect: worker_processes auto (multiple workers spawned)

section "2. HTTP response (status + headers)"
curl -sSI "http://localhost:$PORT/"
# Expect: HTTP 200, Server: nginx/1.25.5

section "3. HTTP body (first 8 lines)"
curl -s "http://localhost:$PORT/" | head -8
# Expect: <!DOCTYPE html> + "Welcome to nginx!"

section "4. nginx -V diff vs upstream baseline"
docker run --rm "$IMAGE" nginx -V 2>&1 | diff baseline/upstream-nginx-V.txt - || true
# Expected divergence only: gcc patch level, OpenSSL version bump, build path

section "5. id nginx diff vs upstream baseline"
docker run --rm "$IMAGE" id nginx | diff baseline/upstream-id-nginx.txt - || true
# Expect: empty diff (uid/gid 101)

section "6. docker inspect Config diff vs upstream baseline"
docker inspect "$IMAGE" --format '{{json .Config}}' \
    | python3 -m json.tool \
    | diff baseline/upstream-config.json - || true
# Expect: empty diff (Cmd, Entrypoint, Env, ExposedPorts, StopSignal, WorkingDir, User)

section "7. nginx.conf byte-for-byte"
diff \
    <(docker run --rm --entrypoint cat "$UPSTREAM" /etc/nginx/nginx.conf) \
    <(docker run --rm --entrypoint cat "$IMAGE"    /etc/nginx/nginx.conf) || true
# Expect: empty diff

section "8. conf.d/default.conf byte-for-byte"
diff \
    <(docker run --rm --entrypoint cat "$UPSTREAM" /etc/nginx/conf.d/default.conf) \
    <(docker run --rm --entrypoint cat "$IMAGE"    /etc/nginx/conf.d/default.conf) || true
# Expect: empty diff

section "9. /etc/nginx recursive layout"
diff \
    <(docker run --rm --entrypoint find "$UPSTREAM" /etc/nginx -mindepth 1 -printf '%y %p\n' | sort) \
    <(docker run --rm --entrypoint find "$IMAGE"    /etc/nginx -mindepth 1 -printf '%y %p\n' | sort) || true
# Expect: empty diff (the `l /etc/nginx/modules` symlink appears in both)

section "10. /usr/sbin diff (binary parity)"
diff \
    <(docker run --rm --entrypoint ls "$UPSTREAM" /usr/sbin/ | sort) \
    <(docker run --rm --entrypoint ls "$IMAGE"    /usr/sbin/ | sort) || true
# Expected divergence: `< nginx-debug` only (deferred — needs second build cycle)

section "11. /usr/share/nginx/html"
diff \
    <(docker run --rm --entrypoint ls "$UPSTREAM" /usr/share/nginx/html/ | sort) \
    <(docker run --rm --entrypoint ls "$IMAGE"    /usr/share/nginx/html/ | sort) || true
# Expect: empty diff (index.html, 50x.html)

section "12. /docker-entrypoint.d"
diff \
    <(docker run --rm --entrypoint ls "$UPSTREAM" /docker-entrypoint.d/ | sort) \
    <(docker run --rm --entrypoint ls "$IMAGE"    /docker-entrypoint.d/ | sort) || true
# Expect: empty diff
