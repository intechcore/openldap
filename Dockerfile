# OpenLDAP — self-maintained image built from the official openldap.org source.
#
# We compile a pinned OpenLDAP release (the current 2.6 LTS) rather than using
# the distro package, so the server version is decoupled from the Debian
# release and tracked explicitly via renovate. The tarball checksum is pinned
# to detect tampering; bump both with `make bump-openldap V=<version>`.

# renovate: openldap
ARG OPENLDAP_VERSION=2.6.13
ARG OPENLDAP_SHA256=d693b49517a42efb85a1a364a310aed16a53d428d1b46c0d31ef3fba78fcb656

# ─── Stage 1: build OpenLDAP from source ────────────────────────────────────
FROM debian:stable AS builder

ARG OPENLDAP_VERSION
ARG OPENLDAP_SHA256

# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        groff-base \
        libsasl2-dev \
        libssl-dev \
        libltdl-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
RUN curl -fsSLo openldap.tgz \
        "https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-${OPENLDAP_VERSION}.tgz" && \
    printf '%s  openldap.tgz\n' "$OPENLDAP_SHA256" | sha256sum -c - && \
    tar xzf openldap.tgz && \
    rm openldap.tgz

WORKDIR /build/openldap-${OPENLDAP_VERSION}
# mdb is built static (always available); overlays are built as loadable
# modules so they can be enabled later via cn=config without a rebuild.
RUN ./configure \
        --prefix=/opt/openldap \
        --sysconfdir=/opt/openldap/etc \
        --localstatedir=/var \
        --enable-slapd \
        --enable-mdb \
        --enable-crypt \
        --enable-spasswd \
        --enable-modules \
        --enable-overlays=mod \
        --with-tls=openssl \
        --with-cyrus-sasl \
        --disable-bdb --disable-hdb --disable-ndb && \
    make depend && \
    make -j"$(nproc)" && \
    make install && \
    strip /opt/openldap/libexec/slapd /opt/openldap/bin/* /opt/openldap/sbin/* 2>/dev/null || true

# ─── Stage 2: runtime image ─────────────────────────────────────────────────
FROM debian:stable-slim

ARG OPENLDAP_VERSION

LABEL maintainer="Sergey Grigoriev <s.grigoriev@intechcore.com>"
LABEL org.opencontainers.image.title="openldap"
LABEL org.opencontainers.image.description="OpenLDAP 2.6 LTS directory server built from source on Debian 13 — self-maintained replacement for osixia/openldap"
LABEL org.opencontainers.image.source="https://github.com/intechcore/openldap"
LABEL org.opencontainers.image.documentation="https://github.com/intechcore/openldap/blob/main/README.md"
LABEL org.opencontainers.image.licenses="MIT"
LABEL org.opencontainers.image.version="${OPENLDAP_VERSION}"

# Runtime shared libraries for the compiled binaries + openssl CLI for the
# self-signed TLS fallback.
# hadolint ignore=DL3008
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y --no-install-recommends \
        libsasl2-2 \
        libssl3 \
        libltdl7 \
        openssl \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/* && \
    groupadd -r openldap && \
    useradd -r -g openldap -d /var/lib/ldap -s /usr/sbin/nologin openldap

COPY --from=builder /opt/openldap /opt/openldap

# slapd lives in libexec; slap* admin tools in sbin; ldap* clients in bin.
ENV PATH="/opt/openldap/bin:/opt/openldap/sbin:/opt/openldap/libexec:${PATH}"

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
