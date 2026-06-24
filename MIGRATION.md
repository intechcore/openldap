# Migrating from osixia/openldap

This image is a drop-in replacement for `osixia/openldap:1.5.0`. It keeps the
same env contract and the same on-disk paths (`/var/lib/ldap`,
`/etc/ldap/slapd.d`), so the migration is small. The one real consideration is
the database format jump from OpenLDAP **2.4** (osixia) to **2.6** (this image).

## Env variable mapping

The variables you already use are supported as-is:

| osixia variable | supported | notes |
|---|---|---|
| `LDAP_ORGANISATION` | ✅ | |
| `LDAP_DOMAIN` | ✅ | base DN is derived from it |
| `LDAP_ADMIN_PASSWORD` | ✅ | |
| `LDAP_CONFIG_PASSWORD` | ✅ | |
| `LDAP_READONLY_USER` / `_USERNAME` / `_PASSWORD` | ✅ | |
| `LDAP_TLS`, `LDAP_TLS_*` | ✅ | |
| `LDAP_TLS_VERIFY_CLIENT` | ✅ | |
| `LDAP_LOG_LEVEL` | ✅ | |
| `LDAP_RFC2307BIS_SCHEMA` | ⚠️ | not auto-handled — load via `/schema` if needed |

Certificates: osixia mounted them at
`/container/service/slapd/assets/certs`. This image uses `/container/certs`.

## Recommended migration: export + reimport (clean)

The safe path is to dump the old directory and reload it into a fresh volume,
which lets OpenLDAP 2.6 write the mdb in its current format.

### 1. Export from the running osixia container

```bash
# Config (cn=config) and data, dumped as LDIF
docker exec itc-openldap slapcat -n 0 -l /tmp/config.ldif
docker exec itc-openldap slapcat -n 1 -l /tmp/data.ldif
docker cp itc-openldap:/tmp/data.ldif ./data.ldif
```

Keep only `data.ldif` — the `cn=config` from 2.4 is **not** reused; the new
image regenerates config from the env vars. Review `data.ldif` and strip any
operational attributes if `slapadd` complains (`entryCSN`, `entryUUID` are
fine to keep).

### 2. Start the new image with the data as bootstrap

```bash
mkdir -p ./bootstrap
cp data.ldif ./bootstrap/00-data.ldif
```

Point the compose service at fresh `*-data` / `*-config` volumes and start it.
On first boot the entrypoint creates the base tree and applies everything in
`/bootstrap` (idempotent — existing entries are skipped). If your dump already
contains the base entry and OUs, that is fine; duplicates are ignored.

### 3. Verify

```bash
docker exec itc-openldap ldapsearch -x -H ldapi://%2Frun%2Fslapd%2Fldapi \
  -D "cn=admin,dc=intechcore,dc=online" -w "$LDAP_ADMIN_PASSWORD" \
  -b "dc=intechcore,dc=online" -LLL dn
```

## Alternative: reuse the existing volume in place

Because both images use Debian paths, you *can* point the new container at the
existing `itc-openldap-data` / `itc-openldap-config` volumes. OpenLDAP mdb is
generally forward-compatible 2.4 → 2.6, but this is **not** guaranteed across a
two-minor jump and you lose the chance to clean stale config. Only do this with
a backup and a tested rollback. The export/reimport path above is preferred.

> Always snapshot the volumes (the project's `restic` backup) before migrating.
