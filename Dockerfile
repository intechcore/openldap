# OpenLDAP — self-maintained image built from the official Symas OpenLDAP 2.6
# LTS packages on Debian 13 (Trixie).
#
# Symas is the company that maintains OpenLDAP upstream; their signed apt
# repository ships the current 2.6 LTS as prebuilt amd64 + arm64 binaries. We
# install a pinned package version (decoupled from Debian's own slapd, tracked
# via renovate) instead of compiling from source — this keeps multi-arch builds
# fast (no QEMU cross-compile) while still using authoritative binaries.
# Bump the pinned version with `make bump-openldap V=<version>`.

FROM debian:trixie-slim

# Upstream OpenLDAP version (used for tags/labels) and the exact Symas apt
# package revision to install (pinned for reproducible builds).
# renovate: openldap
ARG OPENLDAP_VERSION=2.6.13
ARG SYMAS_VERSION=2.6.13-3trixie1

LABEL org.opencontainers.image.title="openldap" \
      org.opencontainers.image.description="OpenLDAP 2.6 LTS directory server from the official Symas packages on Debian 13 — self-maintained replacement for osixia/openldap" \
      org.opencontainers.image.source="https://github.com/intechcore/openldap" \
      org.opencontainers.image.documentation="https://github.com/intechcore/openldap/blob/main/README.md" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.vendor="Intechcore GmbH" \
      org.opencontainers.image.authors="Sergey Grigoriev <s.grigoriev@intechcore.com>" \
      org.opencontainers.image.version="${OPENLDAP_VERSION}"

# Silence debconf's interactive frontend during apt (no TTY in the build). As an
# ARG it applies only to build-time RUN steps and is not persisted in the image.
ARG DEBIAN_FRONTEND=noninteractive

# Add the Symas LTS repo (armored key consumed directly via signed-by, no gnupg
# needed) and install the pinned server + client packages. openssl is kept for
# the self-signed TLS fallback in the entrypoint; the symas packages pull their
# own libssl/libsasl runtime deps. curl is used only to fetch the key and is
# purged afterwards to keep the image slim.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends ca-certificates curl openssl && \
    curl -fsSL https://repo.symas.com/repo/gpg/RPM-GPG-KEY-symas-com-signing-key \
        -o /usr/share/keyrings/symas-key.asc && \
    echo "deb [signed-by=/usr/share/keyrings/symas-key.asc] https://repo.symas.com/repo/deb/main/release26 trixie main" \
        > /etc/apt/sources.list.d/soldap-release26.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        tzdata \
        locales \
        "symas-openldap-server=${SYMAS_VERSION}" \
        "symas-openldap-clients=${SYMAS_VERSION}" && \
    apt-get purge -y curl && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* && \
    groupadd -r openldap && \
    useradd -r -g openldap -d /var/lib/ldap -s /usr/sbin/nologin openldap && \
    ln -s /opt/symas/lib/slapd /opt/symas/sbin/slapd

# Symas layout: slapd in lib/ (symlinked into sbin above), slap* admin tools in
# sbin, ldap* clients in bin.
ENV PATH="/opt/symas/bin:/opt/symas/sbin:${PATH}"

# Default to a UTF-8 locale (always available, no generation needed). Override
# with LANG=<locale> (the entrypoint generates it on first boot if missing), and
# set the zone with TZ=<Area/City>.
ENV LANG=C.UTF-8

# Runtime directories:
#   /container/certs  — mount TLS certs here (compat with the old osixia layout)
#   /schema           — custom schema files (*.schema / *.ldif), baked or mounted
#   /overlays         — cn=config overlay/module LDIFs (e.g. ppolicy), first boot
#   /bootstrap        — initial data LDIF applied on first start (mount only)
#   /etc/ldap/slapd.d — cn=config (kept at the osixia path for volume compat)
#   /var/lib/ldap     — mdb data (kept at the osixia path for volume compat)
RUN mkdir -p /container/certs /schema /overlays /bootstrap /run/slapd \
        /etc/ldap/slapd.d /var/lib/ldap /etc/ldap/certs && \
    chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd /etc/ldap/certs

COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
COPY reload-tls.sh /usr/local/bin/reload-tls
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/reload-tls

# Custom schemas baked into the image (also overridable by mounting /schema).
COPY schema/ /schema/

# 389 = ldap/StartTLS, 636 = ldaps
EXPOSE 389 636

# Liveness over the local ldapi:// socket — a rootDSE base search. Works
# regardless of TLS configuration and needs no credentials.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ["/bin/sh", "-c", "ldapsearch -x -H ldapi://%2Frun%2Fslapd%2Fldapi -b '' -s base -LLL 1.1 >/dev/null 2>&1 || exit 1"]

# Build metadata and the base image the build started from, passed in by the
# release workflow. The weekly rebuild compares the base digest with the
# current upstream one.
ARG GIT_SHA=unknown
ARG BUILD_DATE=unknown
ARG BASE_IMAGE=unknown
ARG BASE_DIGEST=unknown
LABEL org.opencontainers.image.revision="${GIT_SHA}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.base.name="${BASE_IMAGE}" \
      org.opencontainers.image.base.digest="${BASE_DIGEST}"

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["slapd"]
