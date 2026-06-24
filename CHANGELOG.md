# Changelog

All notable changes to this image are documented here. The image is versioned
after the bundled OpenLDAP release with a build suffix (e.g. `2.6.13-1`).

## [Unreleased]

### Added
- Initial release: OpenLDAP 2.6.13 (LTS) built from official openldap.org
  source on Debian 13 (trixie), as a self-maintained replacement for the
  abandoned `osixia/openldap` image.
- Hybrid bootstrap entrypoint compatible with the osixia env contract
  (`LDAP_DOMAIN`, `LDAP_ORGANISATION`, `LDAP_ADMIN_PASSWORD`,
  `LDAP_CONFIG_PASSWORD`, `LDAP_READONLY_USER*`, `LDAP_TLS*`, `LDAP_LOG_LEVEL`).
- Custom schema loading from `/schema` (`*.schema` and `*.ldif`).
- Initial data bootstrap from `/bootstrap` (`*.ldif`).
- TLS via mounted certificates in `/container/certs`, with a self-signed
  fallback for dev/CI.
- Pinned source version + tarball SHA256; renovate tracks new 2.6 releases.
- CI: build + integration tests, hadolint/shellcheck lint, Trivy scan,
  multi-arch (`amd64`/`arm64`) release to ghcr.io.
- `MIGRATION.md` with slapcat/slapadd migration from osixia.
