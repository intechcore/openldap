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

## Baked-in

- **`openssh-lpk.schema`** — the `ldapPublicKey` objectClass + `sshPublicKey`
  attribute, so SSH public keys can be stored on accounts and fetched by `sshd`
  (`AuthorizedKeysCommand` / `sss_ssh_authorizedkeys`).

> Mounting your own volume at `/schema` **replaces** this directory, so re-add
> any baked schema you still need, or mount individual files instead.
