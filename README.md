# openldap

Self-maintained OpenLDAP **2.6 LTS** directory server, built from the official
[openldap.org](https://www.openldap.org/) source on Debian 13 (trixie).

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
    image: ghcr.io/intechcore/openldap:2.6.13
    environment:
      LDAP_ORGANISATION: "Intechcore GmbH"
      LDAP_DOMAIN: "intechcore.online"
      LDAP_ADMIN_PASSWORD: "change-me"
      LDAP_CONFIG_PASSWORD: "change-me-too"
      LDAP_READONLY_USER: "true"
      LDAP_READONLY_USER_PASSWORD: "readonly-pw"
      LDAP_TLS: "true"
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

- OpenLDAP 2.6.13 (LTS), compiled from source — version decoupled from Debian
- `cn=config` (dynamic) backend, `mdb` data store
- First-boot bootstrap driven by environment variables (osixia-compatible)
- Custom schema loading from `/schema` (`*.schema` and `*.ldif`)
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
| `LDAP_READONLY_USER` | `false` | Create a read-only bind account |
| `LDAP_READONLY_USER_USERNAME` | `readonly` | Read-only account CN |
| `LDAP_READONLY_USER_PASSWORD` | `readonly` | Read-only account password |
| `LDAP_TLS` | `false` | Enable `ldaps://` + StartTLS |
| `LDAP_TLS_CRT_FILENAME` | `ldap.crt` | Cert filename in `/container/certs` |
| `LDAP_TLS_KEY_FILENAME` | `ldap.key` | Key filename |
| `LDAP_TLS_CA_CRT_FILENAME` | `ca.crt` | CA cert filename |
| `LDAP_TLS_DH_PARAM_FILENAME` | `dhparam.pem` | DH params filename |
| `LDAP_TLS_VERIFY_CLIENT` | `demand` | `never`/`allow`/`try`/`demand` |
| `LDAP_LOG_LEVEL` | `256` | slapd log level |

### TLS

Mount certificates into `/container/certs` (filenames configurable via the
variables above). If `LDAP_TLS=true` and no certificate is found, a self-signed
cert is generated at startup — convenient for dev/CI, **not** for production.

## Directory layout

| Path | Purpose |
|---|---|
| `/var/lib/ldap` | mdb data (persist) |
| `/etc/ldap/slapd.d` | `cn=config` (persist) |
| `/container/certs` | mounted TLS material |
| `/schema` | custom schemas (baked or mounted) |
| `/bootstrap` | first-boot data LDIF (mount) |

## Building Locally

```bash
make build                       # build openldap:2.6.13
make test                        # build + integration tests (needs docker compose)
make lint                        # shellcheck + hadolint
make scan                        # build + trivy scan
make bump-openldap V=2.6.14      # bump version + refresh tarball checksum
```

## Releasing

Run the **Release** workflow (`workflow_dispatch`). It builds, tests, derives
the version from `slapd -VV`, and pushes multi-arch tags
`<version>-<n>`, `<version>`, and `latest` to `ghcr.io/intechcore/openldap`.

## Migrating from osixia/openldap

See [MIGRATION.md](MIGRATION.md).

## License

MIT
