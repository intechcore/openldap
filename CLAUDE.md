# CLAUDE.md

Guidance for working in this repo.

## What this is

A self-maintained OpenLDAP 2.6 LTS Docker image, built from openldap.org source
on Debian 13. Replaces the abandoned `osixia/openldap`. Same repo conventions as
`intechcore/nginx-geoip` and `intechcore/subversion-ldap-httpd`.

## Layout

- `Dockerfile` — multi-stage: stage 1 compiles OpenLDAP (pinned
  `OPENLDAP_VERSION` + `OPENLDAP_SHA256`), stage 2 is the slim runtime.
- `entrypoint.sh` — hybrid bootstrap. Env vars (osixia-compatible) drive
  first-boot config; `/schema` and `/bootstrap` LDIF cover the rest. Idempotent
  across restarts (only bootstraps when the config volume is empty).
- `schema/` — custom schemas baked into the image at `/schema`.
- `tests/integration/` — `docker compose` + `test-integration.sh` smoke +
  end-to-end (auth, readonly, bootstrap, custom schema, TLS).
- `.github/workflows/` — build+test, lint, security (Trivy), release.

## Key facts

- Binaries live under `/opt/openldap/{libexec,sbin,bin}` (on `PATH`).
- Data: `/var/lib/ldap`; config: `/etc/ldap/slapd.d` (osixia-compatible paths).
- slapd runs as the `openldap` user; the entrypoint starts as root to set up.
- Local admin access uses rootdn binds over `ldapi://` (`cn=admin,cn=config`
  and `cn=admin,<base>`), not SASL EXTERNAL.

## Versioning

- Image tag = bundled OpenLDAP version + build suffix (`2.6.13-1`).
- renovate tracks new 2.6 releases via the `endoflife.date` custom datasource.
  A version bump PR is **not** automerged — refresh the tarball checksum with
  `make bump-openldap V=<version>` (CI fails until the SHA256 matches).

## Common commands

```bash
make build
make test     # needs docker compose
make lint     # shellcheck + hadolint
make scan     # trivy
```
