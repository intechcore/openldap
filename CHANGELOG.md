# Changelog

All notable changes to this image are documented here. The image is versioned
after the bundled OpenLDAP release with a build suffix (e.g. `2.6.13-1`).

## [Unreleased]

### Added
- Initial release: OpenLDAP 2.6.13 (LTS) from the official Symas OpenLDAP 2.6
  LTS apt packages on Debian 13 (trixie), as a self-maintained replacement for
  the abandoned `osixia/openldap` image.
- Hybrid bootstrap entrypoint compatible with the osixia env contract
  (`LDAP_DOMAIN`, `LDAP_ORGANISATION`, `LDAP_ADMIN_PASSWORD`,
  `LDAP_CONFIG_PASSWORD`, `LDAP_READONLY_USER*`, `LDAP_TLS*`, `LDAP_LOG_LEVEL`).
- Custom schema loading from `/schema` (`*.schema` and `*.ldif`).
- Overlay/`cn=config` loading from `/overlays` on first boot (e.g. ppolicy);
  the mdb backend is placed at `olcDatabase={1}mdb,cn=config`.
- Initial data bootstrap from `/bootstrap` (`*.ldif`).
- TLS via mounted certificates in `/container/certs`, with a self-signed
  fallback for dev/CI.
- TLS certificate hot-reload without a restart: the `reload-tls` helper and an
  opt-in cert watcher (`LDAP_TLS_WATCH`), plus a Let's Encrypt DNS-01 example
  (certbot sidecar) in `examples/letsencrypt/`.
- Pinned Symas package revision (`SYMAS_VERSION`); renovate tracks new 2.6
  releases and `make bump-openldap` resolves the matching package version.
- Integration suite covering ppolicy (lockout, account disable via
  pwdAccountLockedTime) and CRUD, plus a 2.4→2.6 migration test
  (`test-migration.sh`) that reimports an osixia/openldap:1.5.0 export.
- CI: build + integration + migration tests, hadolint/shellcheck lint, Trivy
  scan, multi-arch (`amd64`/`arm64`) release to ghcr.io.
- `MIGRATION.md` with the slapcat → strip → reimport recipe from osixia.
