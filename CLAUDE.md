# CLAUDE.md

Guidance for working in this repo.

## What this is

A self-maintained OpenLDAP 2.6 LTS Docker image, built from the official Symas
OpenLDAP 2.6 LTS apt packages on Debian 13. Replaces the abandoned
`osixia/openldap`. Same repo conventions as `intechcore/nginx-geoip` and
`intechcore/subversion-ldap-httpd`.

Resilience: not locked into Symas — OpenLDAP source is canonical at openldap.org,
and the previous from-source build (compile a pinned tarball + SHA256) lives in
git history (`90ab985:Dockerfile`). If `repo.symas.com` disappears, restore that
Dockerfile (or vendor the pinned `.deb`s, or fall back to Debian's `slapd`).
See the "Where the binaries come from" section in README.md.

## Layout

- `Dockerfile`: stage `image` installs the pinned Symas packages
  (`symas-openldap-server`/`-clients` at `SYMAS_VERSION`) from the Symas LTS apt
  repo onto a slim Debian runtime. No source compile (keeps multi-arch fast).
  Stage `coverage` (CI only) runs both scripts under kcov, see Coverage below.
  The last stage, `FROM image` plus the build metadata labels, is the published
  image: the release builds the default target, so keep it last.
- `entrypoint.sh` — hybrid bootstrap. Env vars (osixia-compatible) drive
  first-boot config; `/schema`, `/overlays` (cn=config overlay LDIF, applied via
  ldapmodify) and `/bootstrap` LDIF cover the rest. Idempotent across restarts
  (only bootstraps when the config volume is empty). Also hosts the opt-in TLS
  cert watcher (`LDAP_TLS_WATCH`).
- `reload-tls.sh` → `/usr/local/bin/reload-tls` — re-reads slapd's TLS material
  without a restart by re-asserting `olcTLS*` in `cn=config` (for renewals).
- `schema/` — custom schemas baked into the image at `/schema`.
- `examples/letsencrypt/` — certbot DNS-01 sidecar + auto-reload reference.
- `tests/integration/` — `test-integration.sh` (smoke + e2e: full ACL matrix,
  bootstrap, custom schema, TLS/reload/mutual-TLS/cipher, ppolicy incl. expiry,
  CRUD, memberof/refint, the `lastbind`/`unique`/`password-hash`/`rfc2307bis`
  toggles, and a slapcat→slapadd backup round-trip) and
  `test-migration.sh` (2.4→2.6 via osixia/openldap:1.5.0 → slapcat → reimport),
  and `test-arch.sh` (buildx-builds `linux/arm64` and smoke-tests it under QEMU,
  a quick local check; CI runs the full integration test on arm64). Anonymized synthetic
  fixtures under `fixtures/` (people/groups/policies + `overlays/10-ppolicy.ldif`).
- `tests/coverage.sh`: line coverage (see Coverage below). `tests/contract.sh`
  checks that every variable of the README Configuration table appears in a
  test under `tests/`; `tests/contract-allowlist.txt` exempts variables CI
  cannot test, one per line with a reason.
- `.github/workflows/` — `ci.yml` (lint with shellcheck, hadolint, actionlint,
  zizmor, the configuration contract and trivy config; integration tests on
  amd64 and arm64, the 2.4→2.6 migration on amd64; `sonar`: coverage run and
  SonarCloud scan, skipped without `SONAR_TOKEN`; Trivy: CRITICAL fails, HIGH
  goes to a tracking issue),
  release, and `rebuild.yml`, which releases automatically, weekly and on a push
  that changes an image input: a newer pinned OpenLDAP, a new base digest, a
  changed input file since the image revision, or fixable CRITICAL/HIGH
  findings. It never releases a lower OpenLDAP. `.trivyignore` accepts DS-0002
  (root).

## Coverage

- `tests/coverage.sh <coverage image> <out dir>` (or `make coverage`) runs the
  integration and migration tests with `COVERAGE_DIR` set, then merges the kcov
  data (`kcov --merge`) into `<out dir>/coverage.xml` (SonarQube generic format,
  repository paths) and `<out dir>/html/`. CI writes to `build/`, which
  `sonar-project.properties` reads.
- In the `coverage` stage, `/bin/sh` is bash (kcov traces bash only), and
  `tests/coverage/kcov-run.sh` replaces `docker-entrypoint.sh` and `reload-tls`.
  It runs the original from `/opt/coverage/` under kcov, one directory per
  process below `/cov`. `stdbuf -oL` is required: kcov relays the script output
  through a pipe and would hold the log lines back.
- kcov is PID 1 there and slapd its child. kcov writes its data when slapd
  exits, so coverage mode stops containers before `docker rm -f` (the `rmc`
  helper): a SIGKILL loses the data. The cert watcher holds the kcov trace pipe
  open, so `rmc` first sends SIGTERM to every process but PID 1. Test 45
  checks the slapd child instead of PID 1. `COVERAGE_DIR` unset leaves the
  tests unchanged.
- kcov marks some continuation lines of multi-line commands as not covered.

## Key facts

- Binaries live under `/opt/symas/{bin,sbin}` (on `PATH`); `slapd` itself is at
  `/opt/symas/lib/slapd`, symlinked into `sbin`. Stock schema:
  `/opt/symas/etc/openldap/schema`; backend/overlay modules:
  `/opt/symas/lib/openldap`.
- Backends/overlays are loadable modules in the Symas build (not static), so the
  generated `slapd.conf` must `moduleload back_mdb` before `database mdb`.
- The mdb database is defined before monitor so it lands at
  `olcDatabase={1}mdb,cn=config` (osixia-compatible index that overlay LDIFs in
  `/overlays`, e.g. ppolicy, reference). Overlays load before the `/bootstrap`
  data.
- `memberof` + `refint` overlays are enabled by default (osixia parity, toggles
  `LDAP_MEMBEROF`/`LDAP_REFINT`), configured for `groupOfUniqueNames`/
  `uniqueMember`. Loaded in `bootstrap_data` before user `/overlays`; `memberOf`
  is indexed (added at runtime, since the attr is only defined once the module
  loads).
- Optional `lastbind` overlay (`LDAP_LASTBIND`, default off) records
  `authTimestamp` on each bind. Note: this Symas build's `olcLastBindConfig` does
  NOT accept `olcLastBindPrecision`, so the overlay is added bare (writes on
  every successful bind).
- Optional `unique` overlay (`LDAP_UNIQUE`, attrs `LDAP_UNIQUE_ATTRIBUTES`,
  default `mail uid`) rejects duplicate values (one `olcUniqueURI:
  ldap:///?<attr>?sub?` per attribute, enforced even for rootdn writes).
- `LDAP_PASSWORD_HASH` (default `{SSHA}`) sets `olcPasswordHash` via the slapd.conf
  `password-hash` directive (slaptest puts it on the frontend db — NOT the global
  cn=config entry, which breaks startup for module-provided schemes). The
  entrypoint loads the needed module (argon2/pw-pbkdf2/pw-sha2/pw-apr1).
- `LDAP_RFC2307BIS` swaps the `nis` schema include for `rfc2307bis` (same OIDs, so
  it's a replacement). In rfc2307bis `posixGroup` is AUXILIARY (in stock `nis` it
  is STRUCTURAL); Symas's `nis` already has `posixAccount` AUXILIARY.
- The ppolicy module is `moduleload`ed in the generated slapd.conf so its
  `pwdPolicy` schema is available by default (no standalone ppolicy.schema file
  exists in the Symas build); the overlay itself is still opt-in via `/overlays`.
- TLS is hardened by default: `TLSProtocolMin` (1.2) + optional cipher suite
  (`LDAP_TLS_PROTOCOL_MIN`/`LDAP_TLS_CIPHER_SUITE`). Stack is OpenSSL (not
  GnuTLS like osixia), so cipher strings use OpenSSL syntax.
- Default ACLs follow osixia's restrictive model: user reads only its own entry,
  `userPassword` not readable, readonly account reads the tree, rootdn bypasses.
  Two readonly service accounts: `LDAP_READONLY_USER` (no `userPassword`) and the
  optional `LDAP_READONLY_PW_USER` (also reads hashes, for local password
  verification). The pw-reader's read clause is injected into the generated ACLs
  via the `$pw_read` shell var in `bootstrap_config`.
- Data: `/var/lib/ldap`; config: `/etc/ldap/slapd.d` (osixia-compatible paths).
- slapd runs as the `openldap` user (created in the Dockerfile — the Symas
  packages don't add it); the entrypoint starts as root to set up.
- Local admin access uses rootdn binds over `ldapi://` (`cn=admin,cn=config`
  and `cn=admin,<base>`), not SASL EXTERNAL.

## Versioning

- Image tag = bundled OpenLDAP version + build suffix (`2.6.13-1`).
- `OPENLDAP_VERSION` is the upstream version (tag/label); `SYMAS_VERSION` is the
  exact pinned apt revision actually installed (e.g. `2.6.13-3trixie1`).
- renovate tracks new releases via the **`deb` datasource on the Symas apt repo**
  (`renovate.json`): `SYMAS_VERSION` is the full package revision, `OPENLDAP_VERSION`
  is derived from the same package via `extractVersion`, both grouped into one
  non-automerged "openldap version" PR (2.6 line only). `make bump-openldap
  V=<version>` does the same resolution manually. (The old `endoflife.date`
  datasource was dropped — endoflife no longer tracks openldap.)
- Point-release upgrades (2.6.x→2.6.y) are safe in place (mdb format stable); the
  data volume is reused, no slapcat/slapadd. See README "Upgrading".
- `TZ` sets the timezone (entrypoint symlinks `/etc/localtime`); `LANG` selects
  the locale (`C.UTF-8` default; others generated on first boot via `locale-gen`).
  `tzdata` + `locales` are installed in the image.

## Release notes

`.github/scripts/release-notes.sh` writes them from the rebuild reason and the
`[Unreleased]` entries of CHANGELOG.md added since the previous tag, plus a
components table. Write each CHANGELOG entry for users; the raw commits only
go in a collapsed block.

## Common commands

```bash
make build
make test            # integration suite (needs docker compose)
make test-migration  # 2.4 -> 2.6 migration (pulls osixia/openldap:1.5.0)
make test-arch       # build linux/arm64 + smoke-test under QEMU emulation
make coverage        # kcov line coverage of the shell scripts (build/)
make lint            # contract + shellcheck + hadolint
make scan            # trivy
```
