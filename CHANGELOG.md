# Changelog

All notable changes to this image are documented here. The image is versioned
after the bundled OpenLDAP release with a build suffix (e.g. `2.6.13-1`).

## [Unreleased]

### Added
- Weekly `Rebuild` workflow. It releases the next build when the base image
  was rebuilt under the same tag, or when Trivy finds fixable CRITICAL or HIGH
  vulnerabilities in the published image. New labels
  `org.opencontainers.image.base.{name,digest}` record the base image.
- Initial release: OpenLDAP 2.6.13 (LTS) from the official Symas OpenLDAP 2.6
  LTS apt packages on Debian 13 (trixie), as a self-maintained replacement for
  the abandoned `osixia/openldap` image.
- Hybrid bootstrap entrypoint compatible with the osixia env contract
  (`LDAP_DOMAIN`, `LDAP_ORGANISATION`, `LDAP_ADMIN_PASSWORD`,
  `LDAP_CONFIG_PASSWORD`, `LDAP_READONLY_USER*`, `LDAP_TLS*`, `LDAP_LOG_LEVEL`).
- Custom schema loading from `/schema` (`*.schema` and `*.ldif`); the
  `openssh-lpk` schema (`sshPublicKey`) is baked in.
- `memberof` + `refint` overlays enabled by default (osixia parity, toggles
  `LDAP_MEMBEROF` / `LDAP_REFINT`), configured for `groupOfUniqueNames` /
  `uniqueMember`; `memberOf` is indexed.
- Optional `lastbind` overlay (`LDAP_LASTBIND`) recording `authTimestamp` (last
  successful bind / "last login").
- Optional `unique` overlay (`LDAP_UNIQUE`, attributes via
  `LDAP_UNIQUE_ATTRIBUTES`, default `mail uid`) rejecting duplicate values.
- Configurable password hash (`LDAP_PASSWORD_HASH`, default `{SSHA}`):
  `{ARGON2}`, `{PBKDF2-SHA512}`, `{SSHA512}`, … with the matching module loaded
  automatically; existing hashes keep working (lazy migration).
- Optional `rfc2307bis` schema (`LDAP_RFC2307BIS`) loaded in place of `nis`,
  making `posixAccount`/`posixGroup` AUXILIARY so one entry can be both an
  inetOrgPerson and a POSIX account/group (unified web + Linux/SSSD directory).
- ppolicy module (and its `pwdPolicy` schema) loaded by default, so the schema
  is available without activating the overlay.
- TLS hardened by default: minimum TLS 1.2 (`LDAP_TLS_PROTOCOL_MIN`, default
  `3.3`) and an optional `LDAP_TLS_CIPHER_SUITE`.
- Restrictive default ACLs (osixia parity): users read only their own entry,
  `userPassword` hashes are not readable, readonly account reads the tree.
- Optional second read-only account (`LDAP_READONLY_PW_USER`) that may read
  `userPassword` hashes, for services that verify passwords locally; the plain
  `LDAP_READONLY_USER` never sees hashes.
- Overlay/`cn=config` loading from `/overlays` on first boot (e.g. ppolicy);
  the mdb backend is placed at `olcDatabase={1}mdb,cn=config`.
- Initial data bootstrap from `/bootstrap` (`*.ldif`).
- Timezone (`TZ`) and locale (`LANG`, default `C.UTF-8`; others generated on
  first boot) support — `tzdata` and `locales` are installed in the image.
- TLS via mounted certificates in `/container/certs`, with a self-signed
  fallback for dev/CI.
- TLS certificate hot-reload without a restart: the `reload-tls` helper and an
  opt-in cert watcher (`LDAP_TLS_WATCH`), plus a Let's Encrypt DNS-01 example
  (certbot sidecar) in `examples/letsencrypt/`.
- Pinned Symas package revision (`SYMAS_VERSION`); renovate tracks new 2.6
  releases and `make bump-openldap` resolves the matching package version.
- Base-image security updates applied at build time (`apt-get upgrade`) before
  the pinned Symas packages are installed, so the pin is preserved.
- Integration suite (73 cases) covering ppolicy (lockout, history, min-length,
  admin unlock, auto-unlock, disable via pwdAccountLockedTime, pwdMaxAge expiry),
  CRUD, memberof/refint, lastbind, unique, password-hash, rfc2307bis, a full
  access-control matrix (admin / readonly / password-reading readonly / user /
  anonymous, plus unauthenticated-bind rejection), indexed search, binary
  attributes, openssh-lpk, TLS depth (mounted certs, reload-tls renewal +
  non-TLS no-op, mutual-TLS client cert, cipher suite), config-password default,
  plus container behaviour (restart persistence of data + cn=config,
  bootstrap-skip, healthcheck health, non-root slapd, non-TLS mode, CMD override,
  base-DN derivation) and a slapcat → offline slapadd backup round-trip. A
  2.4→2.6 migration test (`test-migration.sh`) reimports an osixia/openldap:1.5.0
  export, and `test-arch.sh` smoke-tests the `linux/arm64` image under emulation.
- CI: build + integration + migration + arm64-smoke tests, hadolint/shellcheck
  lint, Trivy scan, multi-arch (`amd64`/`arm64`) release to ghcr.io.
- `MIGRATION.md` with the slapcat → strip → reimport recipe from osixia.

### Changed
- One `ci.yml` replaces `docker-publish.yml`, `lint.yml` and `security.yml`.
  Lint adds actionlint, zizmor and `trivy config`. The integration tests run
  on amd64 and arm64. Trivy fails on CRITICAL and reports HIGH to a tracking
  issue. All workflows set their token permissions and keep no credentials in
  the checkout. Releases are created with `gh release create`.
- Symas pin back to `2.6.13-3trixie1`. Symas removed 2.6.15 from its
  trixie repository on 2026-09-17, so `2.6.15-1trixie1` no longer installs.
- Base image `debian:stable-slim` → `debian:trixie-slim`, so an automatic
  rebuild never moves to the next Debian release.
