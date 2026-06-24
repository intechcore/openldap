#!/bin/sh
# certbot deploy hook: publish the freshly issued/renewed cert into the volume
# shared with the openldap container, with permissions its non-root slapd
# (uid/gid 999) can read. Runs as root inside the certbot container.
#
# certbot sets RENEWED_LINEAGE to the live/<domain> directory.
set -e

src="${RENEWED_LINEAGE:?certbot did not set RENEWED_LINEAGE}"
dst=/certs

cp "$src/fullchain.pem" "$dst/fullchain.pem"
cp "$src/chain.pem"     "$dst/chain.pem"
cp "$src/privkey.pem"   "$dst/privkey.pem"

# fullchain/chain are public; the private key is group-readable by slapd only.
chmod 0644 "$dst/fullchain.pem" "$dst/chain.pem"
chmod 0640 "$dst/privkey.pem"
chown 0:999 "$dst/privkey.pem"

echo "deploy-hook: published $(basename "$src") cert to $dst"
