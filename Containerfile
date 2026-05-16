# Modeled after nginx's official 1.25.5 image build:
# https://github.com/nginx/docker-nginx/blob/1.25.5/mainline/debian/Dockerfile
#
# Adapted: the nginx.org apt-install of `nginx` itself is replaced with
# `apt-get install /tmp/*.deb` of our locally-built .deb. The four
# nginx-module-* packages still come from nginx.org's mainline apt repo
# (they're built against the nginx 1.25.5 ABI and nginx.org is the only
# source of prebuilt module binaries for that nginx version — bookworm
# only ships nginx 1.22.x modules).
#
# Our .deb declares `Provides: httpd, nginx-r1.25.5`, which satisfies the
# nginx-module-* packages' `Depends: nginx-r1.25.5` and prevents apt from
# pulling nginx.org's nginx as a transitive dep.

FROM debian:bookworm-slim

LABEL maintainer="NGINX Docker Maintainers <docker-maint@nginx.com>"

ENV NGINX_VERSION=1.25.5
ENV NJS_VERSION=0.8.4
ENV NJS_RELEASE=3~bookworm
ENV PKG_RELEASE=1~bookworm

COPY build/out/*.deb /tmp/

RUN set -x \
    && apt-get update \
    && apt-get install --no-install-recommends --no-install-suggests -y \
        ca-certificates \
    && echo "deb [trusted=yes] https://nginx.org/packages/mainline/debian/ bookworm nginx" \
        > /etc/apt/sources.list.d/nginx.list \
    && apt-get update \
# Install our locally-built nginx .deb + the 4 module packages + helpers in
# one shot. apt picks our deb as the provider of nginx-r1.25.5 because it
# appears first in the args and is a local file (higher selection priority
# than the same-named remote package).
    && apt-get install --no-install-recommends --no-install-suggests -y \
        /tmp/*.deb \
        nginx-module-xslt=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-geoip=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-image-filter=${NGINX_VERSION}-${PKG_RELEASE} \
        nginx-module-njs=${NGINX_VERSION}+${NJS_VERSION}-${NJS_RELEASE} \
        gettext-base \
        curl \
    && rm -rf /var/lib/apt/lists/* /etc/apt/sources.list.d/nginx.list /tmp/*.deb \
# forward request and error logs to docker log collector
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
# create a docker-entrypoint.d directory
    && mkdir /docker-entrypoint.d

# Vendored from upstream docker-nginx 1.25.5 tag (mainline/debian/) — see entrypoint/.
COPY entrypoint/docker-entrypoint.sh /
COPY entrypoint/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d
COPY entrypoint/15-local-resolvers.envsh /docker-entrypoint.d
COPY entrypoint/20-envsubst-on-templates.sh /docker-entrypoint.d
COPY entrypoint/30-tune-worker-processes.sh /docker-entrypoint.d
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
