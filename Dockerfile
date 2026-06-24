# OpenLDAP — self-maintained image built from the official Symas OpenLDAP 2.6
# LTS packages on Debian 13 (Trixie).
#
# Symas is the company that maintains OpenLDAP upstream; their signed apt
# repository ships the current 2.6 LTS as prebuilt amd64 + arm64 binaries. We
# install a pinned package version (decoupled from Debian's own slapd, tracked
# via renovate) instead of compiling from source — this keeps multi-arch builds
# fast (no QEMU cross-compile) while still using authoritative binaries.
# Bump the pinned version with `make bump-openldap V=<version>`.

FROM debian:stable-slim

# Upstream OpenLDAP version (used for tags/labels) and the exact Symas apt
# package revision to install (pinned for reproducible builds).
# renovate: openldap
ARG OPENLDAP_VERSION=2.6.13
ARG SYMAS_VERSION=2.6.13-3trixie1

LABEL maintainer="Sergey Grigoriev <s.grigoriev@intechcore.com>"
LABEL org.opencontainers.image.title="openldap"
LABEL org.opencontainers.image.description="OpenLDAP 2.6 LTS directory server from the official Symas packages on Debian 13 — self-maintained replacement for osixia/openldap"
LABEL org.opencontainers.image.source="https://github.com/intechcore/openldap"
LABEL org.opencontainers.image.documentation="https://github.com/intechcore/openldap/blob/main/README.md"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${OPENLDAP_VERSION}"

# Add the Symas LTS repo (armored key consumed directly via signed-by, no gnupg
# needed) and install the pinned server + client packages. openssl is kept for
# the self-signed TLS fallback in the entrypoint; the symas packages pull their
# own libssl/libsasl runtime deps. curl is used only to fetch the key and is
# purged afterwards to keep the image slim.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl openssl && \
    curl -fsSL https://repo.symas.com/repo/gpg/RPM-GPG-KEY-symas-com-signing-key \
        -o /usr/share/keyrings/symas-key.asc && \
    echo "deb [signed-by=/usr/share/keyrings/symas-key.asc] https://repo.symas.com/repo/deb/main/release26 trixie main" \
        > /etc/apt/sources.list.d/soldap-release26.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
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

# Runtime directories:
#   /container/certs  — mount TLS certs here (compat with the old osixia layout)
#   /schema           — custom schema files (*.schema / *.ldif), baked or mounted
#   /bootstrap        — initial data LDIF applied on first start (mount only)
#   /etc/ldap/slapd.d — cn=config (kept at the osixia path for volume compat)
#   /var/lib/ldap     — mdb data (kept at the osixia path for volume compat)
RUN mkdir -p /container/certs /schema /bootstrap /run/slapd \
        /etc/ldap/slapd.d /var/lib/ldap /etc/ldap/certs && \
    chown -R openldap:openldap /var/lib/ldap /etc/ldap/slapd.d /run/slapd /etc/ldap/certs

COPY entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Custom schemas baked into the image (also overridable by mounting /schema).
COPY schema/ /schema/

# 389 = ldap/StartTLS, 636 = ldaps
EXPOSE 389 636

# Liveness over the local ldapi:// socket — a rootDSE base search. Works
# regardless of TLS configuration and needs no credentials.
HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
    CMD ldapsearch -x -H ldapi://%2Frun%2Fslapd%2Fldapi -b "" -s base -LLL 1.1 >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/docker-entrypoint.sh"]
CMD ["slapd"]
