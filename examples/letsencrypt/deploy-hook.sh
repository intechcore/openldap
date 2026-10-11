#!/bin/sh
# certbot deploy hook: publish the freshly issued/renewed cert into the volume
# shared with the openldap container, with permissions its non-root slapd
# (uid/gid 999) can read. Runs as root inside the certbot container.
#
# certbot sets RENEWED_LINEAGE to the live/<domain> directory.
set -e

src="${RENEWED_LINEAGE:?certbot did not set RENEWED_LINEAGE}"
dst=/certs

# Each file is staged with its final permissions under a temporary name, then
# renamed into place: a rename is atomic, so the watcher in the openldap
# container never reads a partly written file, and the key is never readable by
# others. The key goes first and the certificate, which the watcher polls, last,
# so that a reload never pairs the new certificate with the old key.
# fullchain/chain are public; the private key is group-readable by slapd only.
install -m 0640 -o 0 -g 999 "$src/privkey.pem" "$dst/.privkey.pem.new"
install -m 0644 "$src/chain.pem"     "$dst/.chain.pem.new"
install -m 0644 "$src/fullchain.pem" "$dst/.fullchain.pem.new"
mv -f "$dst/.privkey.pem.new"   "$dst/privkey.pem"
mv -f "$dst/.chain.pem.new"     "$dst/chain.pem"
mv -f "$dst/.fullchain.pem.new" "$dst/fullchain.pem"

echo "deploy-hook: published $(basename "$src") cert to $dst"
