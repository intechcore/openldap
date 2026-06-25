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

- `Dockerfile` — single-stage: installs the pinned Symas packages
  (`symas-openldap-server`/`-clients` at `SYMAS_VERSION`) from the Symas LTS apt
  repo onto a slim Debian runtime. No source compile (keeps multi-arch fast).
- `entrypoint.sh` — hybrid bootstrap. Env vars (osixia-compatible) drive
  first-boot config; `/schema`, `/overlays` (cn=config overlay LDIF, applied via
  ldapmodify) and `/bootstrap` LDIF cover the rest. Idempotent across restarts
  (only bootstraps when the config volume is empty). Also hosts the opt-in TLS
  cert watcher (`LDAP_TLS_WATCH`).
- `reload-tls.sh` → `/usr/local/bin/reload-tls` — re-reads slapd's TLS material
  without a restart by re-asserting `olcTLS*` in `cn=config` (for renewals).
- `schema/` — custom schemas baked into the image at `/schema`.
- `examples/letsencrypt/` — certbot DNS-01 sidecar + auto-reload reference.
- `tests/integration/` — `test-integration.sh` (smoke + e2e: auth, readonly,
  bootstrap, custom schema, TLS + reload, ppolicy, CRUD) and
  `test-migration.sh` (2.4→2.6 via osixia/openldap:1.5.0 → slapcat → reimport).
  Anonymized synthetic fixtures under `fixtures/` (people/groups/policies +
  `overlays/10-ppolicy.ldif`).
- `.github/workflows/` — build+test, lint, security (Trivy), release.

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

## Common commands

```bash
make build
make test     # needs docker compose
make lint     # shellcheck + hadolint
make scan     # trivy
```
