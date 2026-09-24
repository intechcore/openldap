# openldap

[![CI](https://github.com/intechcore/openldap/actions/workflows/ci.yml/badge.svg)](https://github.com/intechcore/openldap/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/intechcore/openldap)](https://github.com/intechcore/openldap/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/intechcore/openldap/badge)](https://scorecard.dev/viewer/?uri=github.com/intechcore/openldap)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=intechcore_openldap&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=intechcore_openldap)

Self-maintained OpenLDAP **2.6 LTS** directory server, built from the official
[Symas](https://www.symas.com/symas-openldap-packages) OpenLDAP 2.6 LTS packages
on Debian 13 (trixie). Symas maintains OpenLDAP upstream, so these are
authoritative binaries — and using prebuilt packages keeps multi-arch builds
fast (no QEMU cross-compile).

Drop-in replacement for the abandoned `osixia/openldap` image: the same
environment variables drive first-boot setup, and the standard data/config
paths (`/var/lib/ldap`, `/etc/ldap/slapd.d`) are preserved so existing volumes
keep working.

## Quick Start

```yaml
# docker-compose.yml
services:
  openldap:
    # renovate: image=ghcr.io/intechcore/openldap
    image: ghcr.io/intechcore/openldap:2.6.15-2
    environment:
      LDAP_ORGANISATION: "Example Inc."
      LDAP_DOMAIN: "example.org"
      LDAP_ADMIN_PASSWORD: "change-me"
      LDAP_CONFIG_PASSWORD: "change-me-too"
      LDAP_READONLY_USER: "true"
      LDAP_READONLY_USER_PASSWORD: "readonly-pw"
      LDAP_TLS: "true"
      TZ: "Europe/Berlin"
    ports:
      - "389:389"
      - "636:636"
    volumes:
      - ./certs:/container/certs:ro          # TLS certs (optional)
      - ./bootstrap:/bootstrap:ro            # initial data LDIF (optional)
      - ./schema:/schema:ro                  # custom schemas (optional)
      - openldap-config:/etc/ldap/slapd.d
      - openldap-data:/var/lib/ldap

volumes:
  openldap-config:
  openldap-data:
```

## Features

- OpenLDAP 2.6.13 (LTS) from official Symas packages — version decoupled from Debian's `slapd`
- `cn=config` (dynamic) backend, `mdb` data store
- First-boot bootstrap driven by environment variables (osixia-compatible)
- Custom schema loading from `/schema` (`*.schema` and `*.ldif`); `openssh-lpk`
  (`sshPublicKey`) baked in; optional `rfc2307bis` (`LDAP_RFC2307BIS`) for unified
  web + Linux/SSSD accounts
- `memberof` + `refint` overlays enabled by default (osixia parity), plus
  `/overlays` for more (e.g. ppolicy)
- Initial data load from `/bootstrap` (`*.ldif`)
- TLS via mounted certs, with a self-signed fallback for dev/CI
- Health check over the local `ldapi://` socket
- Multi-arch: `linux/amd64`, `linux/arm64`

## Configuration

All variables are read **only on first boot** (empty config volume). Subsequent
starts reuse the persisted `cn=config`.

| Variable | Default | Description |
|---|---|---|
| `LDAP_ORGANISATION` | `Example Inc.` | `o:` of the base entry |
| `LDAP_DOMAIN` | `example.org` | Domain → base DN (`example.org` → `dc=example,dc=org`) |
| `LDAP_BASE_DN` | derived from domain | Override the computed base DN |
| `LDAP_ADMIN_PASSWORD` | `admin` | Password for `cn=admin,<base>` |
| `LDAP_CONFIG_PASSWORD` | = admin password | Password for `cn=admin,cn=config` |
| `LDAP_READONLY_USER` | `false` | Create a read-only bind account (no `userPassword` access) |
| `LDAP_READONLY_USER_USERNAME` | `readonly` | Read-only account CN |
| `LDAP_READONLY_USER_PASSWORD` | `readonly` | Read-only account password |
| `LDAP_READONLY_PW_USER` | `false` | Create a 2nd read-only account that **can** read `userPassword` |
| `LDAP_READONLY_PW_USERNAME` | `readpw` | Password-reading account CN |
| `LDAP_READONLY_PW_PASSWORD` | `readpw` | Password-reading account password |
| `LDAP_MEMBEROF` | `true` | Enable the memberof overlay (reverse `memberOf`) |
| `LDAP_REFINT` | `true` | Enable the refint overlay (referential integrity) |
| `LDAP_LASTBIND` | `false` | Enable the lastbind overlay (`authTimestamp` last-login) |
| `LDAP_UNIQUE` | `false` | Enable the unique overlay (reject duplicate attribute values) |
| `LDAP_UNIQUE_ATTRIBUTES` | `mail uid` | Attributes the unique overlay enforces |
| `LDAP_PASSWORD_HASH` | `{SSHA}` | Hash for new passwords (`{ARGON2}`, `{PBKDF2-SHA512}`, `{SSHA512}`, …) |
| `LDAP_RFC2307BIS` | `false` | Load the rfc2307bis schema instead of `nis` (POSIX as AUXILIARY) |
| `LDAP_TLS` | `false` | Enable `ldaps://` + StartTLS |
| `LDAP_TLS_CRT_FILENAME` | `ldap.crt` | Cert filename in `/container/certs` |
| `LDAP_TLS_KEY_FILENAME` | `ldap.key` | Key filename |
| `LDAP_TLS_CA_CRT_FILENAME` | `ca.crt` | CA cert filename |
| `LDAP_TLS_DH_PARAM_FILENAME` | `dhparam.pem` | DH params filename |
| `LDAP_TLS_VERIFY_CLIENT` | `demand` | `never`/`allow`/`try`/`demand` |
| `LDAP_TLS_PROTOCOL_MIN` | `3.3` | Minimum TLS version (`3.3`=1.2, `3.4`=1.3) |
| `LDAP_TLS_CIPHER_SUITE` | _(OpenSSL default)_ | OpenSSL cipher string |
| `LDAP_TLS_WATCH` | `false` | Watch the cert file and hot-reload slapd on renewal |
| `LDAP_TLS_WATCH_INTERVAL` | `3600` | Cert-watch poll interval (seconds) |
| `LDAP_LOG_LEVEL` | `256` | slapd log level |
| `TZ` | _(UTC)_ | Container timezone, e.g. `Europe/Berlin` (affects log timestamps) |
| `LANG` | `C.UTF-8` | Locale; non-default locales are generated on first boot |

### TLS

Mount certificates into `/container/certs` (filenames configurable via the
variables above). If `LDAP_TLS=true` and no certificate is found, a self-signed
cert is generated at startup — convenient for dev/CI, **not** for production.

#### Renewals / Let's Encrypt

slapd reads its TLS material once at startup and does not watch the files. Two
ways to apply a renewed certificate without recreating the container:

- **`reload-tls`** — run `docker exec <container> reload-tls` (e.g. from a
  certbot deploy hook). It tells the running slapd to re-read its cert files.
- **`LDAP_TLS_WATCH=true`** — the image polls the cert file every
  `LDAP_TLS_WATCH_INTERVAL` seconds and reloads automatically when it changes,
  so any external renewer just has to rewrite the mounted cert.

A complete Let's Encrypt setup (certbot DNS-01 sidecar + auto-reload, no docker
socket) is in [`examples/letsencrypt/`](examples/letsencrypt/).

## Overlays

The **memberof** and **refint** overlays are enabled by default (matching
osixia, configured for `groupOfUniqueNames`/`uniqueMember`): `memberof`
maintains the reverse `memberOf` attribute, `refint` cleans DN references on
delete/rename. Disable either with `LDAP_MEMBEROF=false` / `LDAP_REFINT=false`.

Set `LDAP_LASTBIND=true` to also enable the **lastbind** overlay, which records
the time of each successful bind in the operational `authTimestamp` attribute (a
"last login" timestamp; note it writes on every successful bind).

Set `LDAP_UNIQUE=true` to enable the **unique** overlay, which rejects writes
that would duplicate a value of the attributes in `LDAP_UNIQUE_ATTRIBUTES`
(default `mail uid`) — e.g. two accounts can't share an email address.

Drop additional `cn=config` LDIF files into `/overlays` to enable more overlays
on first boot (applied before the data load). The data backend is
`olcDatabase={1}mdb,cn=config`. Example — the **ppolicy** password-policy overlay:

```ldif
# /overlays/10-ppolicy.ldif
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: ppolicy

dn: olcOverlay=ppolicy,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcPPolicyConfig
olcOverlay: ppolicy
olcPPolicyDefault: cn=default,ou=policies,dc=example,dc=org
olcPPolicyHashCleartext: TRUE
```

## Access control

The default ACLs match osixia's restrictive model:

- `userPassword` — self can change it, anonymous may use it to authenticate
  (bind), nobody can read the hash.
- Everything else — a user reads **only its own entry**; the optional readonly
  account (`LDAP_READONLY_USER`) reads the whole tree; everyone else is denied.

Two read-only service accounts are available: `LDAP_READONLY_USER` reads all
entries but **never** the password hashes (the right choice for services that
authenticate via an LDAP bind), while `LDAP_READONLY_PW_USER` additionally reads
`userPassword` — only for services that verify passwords by reading the hash
locally (e.g. some Dovecot/Postfix setups). Both are read-only (no writes).

The `cn=admin,<base>` rootdn bypasses ACLs for administration. Tighten or widen
by mounting your own `cn=config` ACL LDIF into `/overlays`.

### Password hashing

`LDAP_PASSWORD_HASH` sets the scheme used for **new and changed** passwords.
Default `{SSHA}`. Available schemes: built-in `{SSHA}` / `{SHA}` / `{SMD5}` /
`{MD5}` / `{CRYPT}`, plus `{ARGON2}`, `{PBKDF2-SHA512}` / `{PBKDF2-SHA256}`,
`{SSHA512}` / `{SSHA256}` (the matching module is loaded automatically).

Switching schemes is a **lazy migration**: existing hashes keep verifying, and
each password is re-hashed with the new scheme the next time it is set (via
`ldappasswd`, or a cleartext write when ppolicy's `olcPPolicyHashCleartext` is
on). You can switch back to `{SSHA}` the same way. Notes: `LDAP_PASSWORD_HASH` is
read only on first boot (change it on a running server with an `olcPasswordHash`
`ldapmodify`); bind-based clients (Spring, Apache `mod_ldap`, …) don't care about
the scheme, but any client that reads the hash to verify locally must understand
it; `{ARGON2}` costs more CPU/RAM per bind than `{SSHA}`.

## Directory layout

| Path | Purpose |
|---|---|
| `/var/lib/ldap` | mdb data (persist) |
| `/etc/ldap/slapd.d` | `cn=config` (persist) |
| `/container/certs` | mounted TLS material |
| `/schema` | custom schemas (baked or mounted) |
| `/overlays` | first-boot overlay/`cn=config` LDIF (mount) |
| `/bootstrap` | first-boot data LDIF (mount) |

## Building Locally

```bash
make build                       # build openldap:2.6.13
make test                        # build + integration tests (needs docker compose)
make test-migration              # build + 2.4 -> 2.6 migration test
make test-arch                   # build linux/arm64 + smoke-test under emulation
make coverage                    # line coverage of the shell scripts, see below
make contract                    # every documented variable has a test
make lint                        # contract + shellcheck + hadolint
make scan                        # build + trivy scan
make bump-openldap V=2.6.14      # bump version + resolve Symas package revision
```

### Test coverage

`make coverage` measures the line coverage of `entrypoint.sh` and `reload-tls.sh`.
It builds the `coverage` stage of the Dockerfile, which runs both scripts under
[kcov](https://github.com/SimonKagstrom/kcov). Then it runs the integration and
migration tests against that image and merges the results of all containers:

```bash
docker build --target coverage -t openldap:coverage .
./tests/coverage.sh openldap:coverage build
```

The report goes to `build/coverage.xml` (SonarQube format) and `build/html/`. The
`sonar` CI job runs the same script and sends the report to SonarCloud. The tests
switch to coverage mode when `COVERAGE_DIR` names a host directory. Without it
they behave as before.

`make contract` runs `tests/contract.sh`. It checks that every variable in the
Configuration table above appears in a test under `tests/`. If CI cannot test a
variable, list it in `tests/contract-allowlist.txt` with a reason.

## Releasing

Run the **Release** workflow (`workflow_dispatch`). It builds and tests amd64
and arm64 on separate jobs, pushes exactly the tested images, derives
the version from `slapd -VV`, and pushes multi-arch tags
`<version>-<n>`, `<version>`, and `latest` to `ghcr.io/intechcore/openldap`.

### Verify an image

Each release carries signed attestations. The build provenance proves which workflow of this
repository built the image, and from which commit:

```sh
gh attestation verify oci://ghcr.io/intechcore/openldap:2.6.15-2 --owner intechcore
```

The SBOM (SPDX) lists the packages in the image. It belongs to the image of one platform, so
check it on the digest of that platform, from `docker buildx imagetools inspect`:

```sh
docker buildx imagetools inspect ghcr.io/intechcore/openldap:2.6.15-2
gh attestation verify oci://ghcr.io/intechcore/openldap@sha256:<platform digest> \
  --owner intechcore --predicate-type https://spdx.dev/Document/v2.3
```

### Automatic Rebuilds

The image builds on `debian:trixie-slim` and installs its packages with apt. Debian ships security fixes as package updates and rebuilds the base image under the same tag. Renovate sees neither.

The `Rebuild` workflow checks the published `latest` image every Monday. It releases the next build (`2.6.13-4 → 2.6.13-5`) in two cases:

- The upstream base image digest differs from the `org.opencontainers.image.base.digest` label of the published image.
- Trivy finds fixable CRITICAL or HIGH vulnerabilities in the published image.

A rebuild runs without the layer cache, so apt installs current packages. The release notes state the reason. The rebuild releases the current `main`, so merged changes go out with it.

The base stays on the Debian 13 codename on purpose. `stable-slim` moves to the next Debian release without notice. Move to Debian 14 by changing `FROM`.

## Where the binaries come from (and resilience)

The image installs the official **Symas** OpenLDAP 2.6 LTS packages (Symas
employs the OpenLDAP core team and is the project's commercial steward). We are
**not locked in**, because OpenLDAP itself is open source:

- **Canonical source** — [openldap.org](https://www.openldap.org/software/download/)
  (mirrored). The pinned version + a tarball SHA256 are all that's needed to
  build from scratch.
- **From-source fallback** — the previous build compiled OpenLDAP from that
  source on Debian; it is preserved in git history and can be restored if
  `repo.symas.com` ever goes away. (Trade-off: slower multi-arch builds — the
  reason we moved to prebuilt packages.)
- **Other options** — Debian's own `slapd` package (lags upstream), or the LTB
  project's builds (RPM only). RHEL no longer ships an OpenLDAP server.

For maximum durability you can also vendor the exact pinned `.deb` files
(e.g. attach them to a GitHub Release) so a build reproduces even without the
Symas repo.

## Upgrading

Within the 2.6 LTS line (e.g. `2.6.13` → `2.6.14`, the bumps Renovate proposes),
the mdb on-disk format is stable, so upgrading is **in place**: pull the new
image and recreate the container against the existing `*-data` / `*-config`
volumes — no `slapcat`/`slapadd` dump-and-reload needed. Snapshot the volumes
first (the `restic` backup). Major upgrades from 2.4/2.5 are a different story —
see [MIGRATION.md](MIGRATION.md).

## Migrating from osixia/openldap

See [MIGRATION.md](MIGRATION.md).

## Disclaimer

This image is provided "as is", without warranty of any kind, as the [LICENSE](LICENSE) states.
Use it at your own risk. Intechcore GmbH is not liable for damage from its use, as far as the law
allows. It is published free of charge, outside of any commercial offering, with no obligation to
support it. Security reports are welcome, see [SECURITY.md](SECURITY.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report vulnerabilities privately, see [SECURITY.md](SECURITY.md).

## License

MIT
