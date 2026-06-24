# Custom schemas

Files placed here are baked into the image at `/schema` and loaded on first
start (empty config volume). You can also override this directory at runtime by
mounting a volume at `/schema`.

Two formats are supported:

- **`*.schema`** — classic slapd.conf schema syntax. Included directly when the
  initial `cn=config` is generated.
- **`*.ldif`** — modern `cn=config` schema entries (`objectClass: olcSchemaConfig`,
  `dn: cn=<name>,cn=schema,cn=config`). Loaded with `ldapadd` after the directory
  starts.

Both are applied **only on first boot**. To add a schema to an already-populated
config volume, load it manually with `ldapmodify`/`ldapadd` against the running
server.
