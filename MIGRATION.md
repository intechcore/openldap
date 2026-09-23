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
# Dump the data backend as LDIF (suffix-scoped; -o ldif-wrap=no keeps every
# attribute on a single line so the filter below is reliable).
docker exec openldap slapcat -o ldif-wrap=no -b "dc=example,dc=org" > dump.ldif
```

The `cn=config` from 2.4 is **not** reused — the new image regenerates config
from the env vars (and overlays from `/overlays`, see step 2).

The new image applies `/bootstrap` LDIF with `ldapadd`, which **rejects
operational / `NO-USER-MODIFICATION` attributes** that `slapcat` emits. Strip
them before reimport — note `memberOf`, which the old osixia server's memberof
overlay computed onto every user entry. Membership really lives in the group
entries' `member`/`uniqueMember`, and this image runs the memberof overlay by
default (`LDAP_MEMBEROF`), so `memberOf` is recomputed automatically after the
import:

```bash
grep -ivE '^(structuralObjectClass|entryUUID|entryCSN|creatorsName|createTimestamp|modifiersName|modifyTimestamp|entryDN|subschemaSubentry|hasSubordinates|contextCSN|memberOf|pwdChangedTime|pwdFailureTime|pwdGraceUseTime|pwdHistory|pwdAccountLockedTime|pwdReset):' \
  dump.ldif > data.ldif
```

User `userPassword` hashes are preserved by this dump, so existing credentials
keep working after the import. This export/strip/reimport flow is exercised end
to end by `tests/integration/test-migration.sh`.

### 2. Start the new image with the data as bootstrap

```bash
mkdir -p ./bootstrap ./overlays
cp data.ldif ./bootstrap/00-data.ldif
```

If your old server ran the **ppolicy** overlay (password policy / account
lockout), re-enable it on the new server by dropping its `cn=config` LDIF into
`./overlays` (mounted at `/overlays`) — overlays are applied on first boot
before the data. The data backend is `olcDatabase={1}mdb,cn=config`:

```ldif
# overlays/10-ppolicy.ldif
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

Point the compose service at fresh `*-data` / `*-config` volumes and start it.
On first boot the entrypoint creates the base tree and applies everything in
`/bootstrap` (idempotent — existing entries are skipped). If your dump already
contains the base entry and OUs, that is fine; duplicates are ignored.

### 3. Verify

```bash
docker exec openldap ldapsearch -x -H ldapi://%2Frun%2Fslapd%2Fldapi \
  -D "cn=admin,dc=example,dc=org" -w "$LDAP_ADMIN_PASSWORD" \
  -b "dc=example,dc=org" -LLL dn
```

## Alternative: reuse the existing volume in place

Because both images use Debian paths, you *can* point the new container at the
existing `openldap-data` / `openldap-config` volumes. OpenLDAP mdb is
generally forward-compatible 2.4 → 2.6, but this is **not** guaranteed across a
two-minor jump and you lose the chance to clean stale config. Only do this with
a backup and a tested rollback. The export/reimport path above is preferred.

> Always snapshot the volumes (the project's `restic` backup) before migrating.
