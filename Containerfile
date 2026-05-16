# This is a template file from docker-nginx repo - (https://github.com/nginx/docker-nginx/blob/c90491de22401b512a64fff6d23d3dcb3a861573/Dockerfile-debian.template)
# which they used for nginx image creation.
#
# Adapted: placeholders substituted to match nginx:1.25-bookworm, and the
# nginx.org apt-repo install (GPG keys + remote .debs) replaced with
# installing our locally-built .deb from build/out/.

FROM debian:bookworm-slim

LABEL maintainer="NGINX Docker Maintainers <docker-maint@nginx.com>"

ENV NGINX_VERSION=1.25.5
ENV NJS_VERSION=0.8.4
ENV NJS_RELEASE=3~bookworm
ENV PKG_RELEASE=1~bookworm

# Install our locally-built nginx .deb. The .deb's postinst creates the
# nginx user/group at uid/gid 101 (mirroring the upstream image).
# gettext-base → envsubst (used by /docker-entrypoint.d/20-envsubst-on-templates.sh)
# curl         → present in upstream image
COPY build/out/*.deb /tmp/

RUN set -x \
    && apt-get update \
    && apt-get install --no-install-recommends --no-install-suggests -y \
        ca-certificates \
        curl \
        gettext-base \
        /tmp/*.deb \
    && rm -rf /var/lib/apt/lists/* /tmp/*.deb \
# forward request and error logs to docker log collector
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
# create a docker-entrypoint.d directory
    && mkdir /docker-entrypoint.d

# Vendored from upstream docker-nginx (commit c90491de) — see entrypoint/.
COPY entrypoint/docker-entrypoint.sh /
COPY entrypoint/10-listen-on-ipv6-by-default.sh /docker-entrypoint.d
COPY entrypoint/15-local-resolvers.envsh /docker-entrypoint.d
COPY entrypoint/20-envsubst-on-templates.sh /docker-entrypoint.d
COPY entrypoint/30-tune-worker-processes.sh /docker-entrypoint.d
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

STOPSIGNAL SIGQUIT

CMD ["nginx", "-g", "daemon off;"]
