#!/usr/bin/env bash
# Build nginx from upstream source, apply patches from /build/patches/,
# emit a .deb to /out/.
#
# Invoked by `make build`, which mounts:
#   /build  ← repo's build/ directory (read-only)
#   /out    ← repo's build/out/ directory (writable)
# and passes NGINX_VERSION and DEB_REVISION via env.
#
# Runs in a fresh debian:bookworm-slim container — no pre-baked binaries.

# TODO: Test patch

set -euo pipefail

: "${NGINX_VERSION:?NGINX_VERSION must be set}"
: "${DEB_REVISION:?DEB_REVISION must be set}"

ARCH="$(dpkg --print-architecture)"
DEB_NAME="nginx_${NGINX_VERSION}-${DEB_REVISION}_${ARCH}.deb"
WORK=/tmp/nginx-build
STAGE=/tmp/nginx-stage

log() { echo "==> $*"; }

log "install build deps"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    curl \
    file \
    libpcre2-dev \
    libssl-dev \
    patch \
    xz-utils \
    zlib1g-dev

rm -rf "$WORK" "$STAGE"
mkdir -p "$WORK" "$STAGE"

log "fetch nginx-${NGINX_VERSION} source"
cd "$WORK"
curl -fsSLO "https://nginx.org/download/nginx-${NGINX_VERSION}.tar.gz"
# TODO: pin + verify SHA256 (and/or GPG signature from nginx.org)
tar xzf "nginx-${NGINX_VERSION}.tar.gz"
cd "nginx-${NGINX_VERSION}"

log "apply patches from /build/patches"
shopt -s nullglob
for p in /build/patches/*.patch; do
    echo "    applying $(basename "$p")"
    patch -p1 < "$p"
done
shopt -u nullglob

log "configure"
# Configure args mirror upstream nginx:1.25-bookworm (baseline/upstream-nginx-V.txt).
# Ideally, this would mirror the file automatically, but this is out of the scope for this assignment.
# (baseline isn't required for testing purposes)
./configure \
    --prefix=/etc/nginx \
    --sbin-path=/usr/sbin/nginx \
    --modules-path=/usr/lib/nginx/modules \
    --conf-path=/etc/nginx/nginx.conf \
    --error-log-path=/var/log/nginx/error.log \
    --http-log-path=/var/log/nginx/access.log \
    --pid-path=/var/run/nginx.pid \
    --lock-path=/var/run/nginx.lock \
    --http-client-body-temp-path=/var/cache/nginx/client_temp \
    --http-proxy-temp-path=/var/cache/nginx/proxy_temp \
    --http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
    --http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
    --http-scgi-temp-path=/var/cache/nginx/scgi_temp \
    --user=nginx \
    --group=nginx \
    --with-compat \
    --with-file-aio \
    --with-threads \
    --with-http_addition_module \
    --with-http_auth_request_module \
    --with-http_dav_module \
    --with-http_flv_module \
    --with-http_gunzip_module \
    --with-http_gzip_static_module \
    --with-http_mp4_module \
    --with-http_random_index_module \
    --with-http_realip_module \
    --with-http_secure_link_module \
    --with-http_slice_module \
    --with-http_ssl_module \
    --with-http_stub_status_module \
    --with-http_sub_module \
    --with-http_v2_module \
    --with-http_v3_module \
    --with-mail \
    --with-mail_ssl_module \
    --with-stream \
    --with-stream_realip_module \
    --with-stream_ssl_module \
    --with-stream_ssl_preread_module \
    --with-cc-opt="-g -O2 -ffile-prefix-map=${WORK}/nginx-${NGINX_VERSION}=. -fstack-protector-strong -Wformat -Werror=format-security -Wp,-D_FORTIFY_SOURCE=2 -fPIC" \
    --with-ld-opt='-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -pie'

log "compile (-j$(nproc))"
make -j"$(nproc)"

log "install to staging"
make install DESTDIR="$STAGE"
mkdir -p "$STAGE/var/cache/nginx" "$STAGE/var/log/nginx"

# Strip debug symbols from the binary (matches nginx.org's debian/rules).
# Compiled with `-g`, so the binary carries ~7 MB of debug metadata that
# nginx.org strips before packaging — without this our nginx is 8.45 MB
# vs upstream's 1.56 MB.
log "strip /usr/sbin/nginx"
strip "$STAGE/usr/sbin/nginx"

# Why this `mv` exists: we vendor upstream's conf.d/default.conf (which says
# `root /usr/share/nginx/html;`) but nginx source's `make install` placed the
# docroot at ${prefix}/html (/etc/nginx/html in our case). Without relocation,
# nginx parses the config fine but every `GET /` returns 404 — observed during
# smoke testing. Upstream's .deb has no /etc/nginx/html and the html files at
# /usr/share/nginx/html are owned by the `nginx` package (verified via
# `dpkg-query -S`), so this relocation happens inside their packaging too —
# see the upstream dh_install mapping at
# https://github.com/nginx/pkg-oss/blob/master/debian/debian/nginx.install
# (`html/index.html  usr/share/nginx/html`). nginx.org bypasses `make install`
# and uses dh_install with explicit src→dest pairs; we use `make install`
# plus this `mv` for the same end state.
log "relocate html docroot to /usr/share/nginx/html"
mkdir -p "$STAGE/usr/share/nginx"
mv "$STAGE/etc/nginx/html" "$STAGE/usr/share/nginx/html"

# Why this exists: the assignment requires matching the upstream image's
# filesystem layout exactly. `make install` produces 12+ files upstream
# doesn't ship (`*.default` reference copies, KOI8/Win-1251 charset maps,
# `fastcgi.conf` — observed via `ls /etc/nginx/` diffing our image vs
# upstream), and skips the `/etc/nginx/modules` symlink that upstream's .deb
# registers (visible via `dpkg-query -S /etc/nginx/modules` on the upstream
# image — owned by the `nginx` package). This block prunes the extras and
# adds the symlink so `ls /etc/nginx/` matches upstream.
log "align /etc/nginx with upstream layout"
rm -f \
    "$STAGE/etc/nginx/"*.default \
    "$STAGE/etc/nginx/koi-utf" \
    "$STAGE/etc/nginx/koi-win" \
    "$STAGE/etc/nginx/win-utf" \
    "$STAGE/etc/nginx/fastcgi.conf"
mkdir -p "$STAGE/usr/lib/nginx/modules"
ln -sfn /usr/lib/nginx/modules "$STAGE/etc/nginx/modules"

# Overlay Debian-packaging configs from /build/conf/ on top of source defaults.
# nginx's `make install` ships source's pristine nginx.conf (inline server block,
# no conf.d include) — upstream's .deb ships a packaging-modified version that
# splits the server block into /etc/nginx/conf.d/default.conf and adds
# `include /etc/nginx/conf.d/*.conf;` to nginx.conf. Replicating that here.
log "overlay packaging configs"
install -m 0644 /build/conf/nginx.conf      "$STAGE/etc/nginx/nginx.conf"
install -D -m 0644 /build/conf/default.conf "$STAGE/etc/nginx/conf.d/default.conf"

log "write DEBIAN/control"
INSTALL_SIZE=$(du -sk "$STAGE" | awk '{print $1}')
mkdir -p "$STAGE/DEBIAN"
cat > "$STAGE/DEBIAN/control" <<EOF
Package: nginx
Version: ${NGINX_VERSION}-${DEB_REVISION}
Architecture: ${ARCH}
Maintainer: Paul Sherbaum <pinialtshu@gmail.com>
Installed-Size: ${INSTALL_SIZE}
Depends: libc6, libpcre2-8-0, libssl3, zlib1g
Provides: httpd, nginx-r${NGINX_VERSION}
Section: httpd
Priority: optional
Homepage: https://nginx.org
Description: high performance web server (rebuilt from upstream source)
 nginx [engine x] is an HTTP and reverse proxy server, a mail proxy
 server, and a generic TCP/UDP proxy server. Rebuilt from upstream
 source on debian:bookworm-slim with CVE patches applied.
EOF

# Register the configs as conffiles so dpkg treats them as user-editable
# and preserves local modifications across upgrades (matches upstream .deb).
cat > "$STAGE/DEBIAN/conffiles" <<'EOF'
/etc/nginx/nginx.conf
/etc/nginx/conf.d/default.conf
EOF

# postinst: create the nginx user/group at uid/gid 101 to match upstream image.
cat > "$STAGE/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if ! getent group nginx >/dev/null; then
    groupadd --system --gid 101 nginx
fi
if ! getent passwd nginx >/dev/null; then
    useradd --system --gid nginx --no-create-home --home-dir /nonexistent \
        --comment "nginx user" --shell /usr/sbin/nologin --uid 101 nginx
fi
EOF
chmod 0755 "$STAGE/DEBIAN/postinst"

log "dpkg-deb --build"
dpkg-deb --build --root-owner-group "$STAGE" "/out/${DEB_NAME}"

log "done: /out/${DEB_NAME}"
ls -la "/out/${DEB_NAME}"
