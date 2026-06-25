#!/bin/bash
# NOTE: no `pipefail` here on purpose. Many checks are `ldapsearch ... | grep -q`,
# and `grep -q` exits on first match, which makes ldapsearch take SIGPIPE (141).
# With pipefail that would mark the pipeline failed even though the match was
# found — a size-of-output race. Without it, the pipeline status is grep's.
set -eu

# Tests for the openldap image.
# Structural checks (image, binaries, healthcheck) + end-to-end LDAP tests
# (anonymous/admin/readonly binds, bootstrap data, custom schema, TLS).
#
# Usage: ./tests/integration/test-integration.sh [IMAGE_NAME:TAG]
# Requires: docker compose. All ldap* commands run inside the container.

IMAGE="${1:-openldap:2.6.13}"
IMAGE_NAME="${IMAGE%%:*}"
IMAGE_TAG="${IMAGE##*:}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONTAINER="openldap-integration-test"

BASE="dc=example,dc=test"
ADMIN_DN="cn=admin,${BASE}"
ADMIN_PW="adminpw"
CONFIG_PW="configpw"
RO_DN="cn=readonly,${BASE}"
RO_PW="ropw"
USER_PW="Secret123"   # shared fixture password (see fixtures/bootstrap/21-people.ldif)
LDAPI="ldapi://%2Frun%2Fslapd%2Fldapi"

PASS=0
FAIL=0
TOTAL=30

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    cd "$SCRIPT_DIR"
    IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" docker compose down -v 2>/dev/null || true
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# ldapsearch/ldapadd inside the container over the local socket
dsearch() { docker exec "$CONTAINER" ldapsearch "$@"; }

wait_for_ldap() {
    local timeout="${1:-60}"
    # Gate on an authenticated read of the base entry: this only succeeds once
    # the final foreground slapd is up AND the mdb backend has loaded the data,
    # so the tests never race the bootstrap → final-slapd handover.
    for _ in $(seq 1 "$timeout"); do
        if docker exec "$CONTAINER" ldapsearch -x -H "$LDAPI" \
                -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE" -s base o 2>/dev/null \
                | grep -qi "^o: "; then
            return 0
        fi
        sleep 1
    done
    echo "  LDAP did not become ready within ${timeout}s"
    docker compose -f "$SCRIPT_DIR/docker-compose.yml" logs 2>&1 | tail -30 | sed 's/^/    /'
    return 1
}

echo "=== Tests for $IMAGE ==="
echo ""

# ── Structural checks ───────────────────────────────────────────────────────

echo "[1/$TOTAL] Image exists"
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
    pass "Image $IMAGE found"
else
    fail "Image $IMAGE not found — build it first"
    echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

echo "[2/$TOTAL] slapd present and is OpenLDAP 2.6.x"
SLAPD_VER=$(docker run --rm --entrypoint "" "$IMAGE" sh -c 'slapd -VV 2>&1' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ -n "$SLAPD_VER" ] && echo "$SLAPD_VER" | grep -q '^2\.6\.'; then
    pass "slapd $SLAPD_VER"
else
    fail "unexpected slapd version: '${SLAPD_VER:-none}'"
fi

echo "[3/$TOTAL] LDAP client tools present"
if docker run --rm --entrypoint "" "$IMAGE" sh -c 'ldapsearch -VV' > /dev/null 2>&1; then
    pass "ldapsearch is installed"
else
    fail "ldapsearch not found"
fi

echo "[4/$TOTAL] HEALTHCHECK instruction present"
HC=$(docker inspect --format='{{.Config.Healthcheck}}' "$IMAGE" 2>/dev/null || echo "")
if [ -n "$HC" ] && [ "$HC" != "<nil>" ]; then
    pass "HEALTHCHECK is defined"
else
    fail "HEALTHCHECK not found in image"
fi

# ── Integration ─────────────────────────────────────────────────────────────

echo ""
echo "Starting test environment..."
cd "$SCRIPT_DIR"
IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" docker compose up -d

echo "Waiting for slapd to be ready..."
if ! wait_for_ldap 60; then
    fail "slapd did not start"
    echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi
echo ""

echo "[5/$TOTAL] rootDSE advertises the naming context"
if dsearch -x -H "$LDAPI" -b "" -s base namingContexts 2>/dev/null | grep -qi "namingContexts: $BASE"; then
    pass "namingContexts includes $BASE"
else
    fail "namingContexts does not include $BASE"
fi

echo "[6/$TOTAL] Base entry exists with organisation"
if dsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE" -s base 2>/dev/null | grep -qi "o: Example Test Org"; then
    pass "base entry has o: Example Test Org"
else
    fail "base entry missing or wrong organisation"
fi

echo "[7/$TOTAL] Default OUs created"
OUT=$(dsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE" "(objectClass=organizationalUnit)" dn 2>/dev/null || true)
if echo "$OUT" | grep -qi "ou=people,$BASE" && echo "$OUT" | grep -qi "ou=groups,$BASE"; then
    pass "ou=people and ou=groups exist"
else
    fail "default OUs missing"
fi

echo "[8/$TOTAL] Admin can read the subtree"
COUNT=$(dsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE" dn 2>/dev/null | grep -c "^dn:" || true)
if [ "${COUNT:-0}" -ge 3 ]; then
    pass "admin search returned $COUNT entries"
else
    fail "admin search returned only ${COUNT:-0} entries"
fi

echo "[9/$TOTAL] Readonly user can bind and search"
if dsearch -x -H "$LDAPI" -D "$RO_DN" -w "$RO_PW" -b "$BASE" -s base dn >/dev/null 2>&1; then
    pass "readonly bind + search works"
else
    fail "readonly bind/search failed"
fi

echo "[10/$TOTAL] Readonly user cannot write"
if docker exec -i "$CONTAINER" ldapadd -x -H "$LDAPI" -D "$RO_DN" -w "$RO_PW" >/dev/null 2>&1 <<EOF
dn: uid=intruder,ou=people,$BASE
objectClass: inetOrgPerson
cn: Intruder
sn: Intruder
uid: intruder
EOF
then
    fail "readonly user was able to write (should be denied)"
else
    pass "readonly write correctly denied"
fi

echo "[11/$TOTAL] Bootstrap data loaded"
if dsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "ou=people,$BASE" "(uid=alice)" cn 2>/dev/null | grep -qi "cn: Alice Example"; then
    pass "bootstrap user uid=alice present"
else
    fail "bootstrap user uid=alice not found"
fi

echo "[12/$TOTAL] Custom schema loaded into cn=config"
if docker exec "$CONTAINER" ldapsearch -x -H "$LDAPI" -D "cn=admin,cn=config" -w "configpw" \
    -b "cn=schema,cn=config" "(cn={*}itctest)" olcAttributeTypes 2>/dev/null | grep -q "itcTestAttr"; then
    pass "custom attribute itcTestAttr present in cn=config"
else
    fail "custom schema not loaded"
fi

echo "[13/$TOTAL] Admin can add and read back a new user"
docker exec -i "$CONTAINER" ldapadd -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF || true
dn: uid=bob,ou=people,$BASE
objectClass: inetOrgPerson
cn: Bob Example
sn: Example
uid: bob
EOF
if dsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "ou=people,$BASE" "(uid=bob)" uid 2>/dev/null | grep -qi "uid: bob"; then
    pass "added uid=bob and read it back"
else
    fail "could not add/read uid=bob"
fi

echo "[14/$TOTAL] Wrong admin password is rejected"
if docker exec "$CONTAINER" ldapwhoami -x -H "$LDAPI" -D "$ADMIN_DN" -w "wrong-password" >/dev/null 2>&1; then
    fail "bind succeeded with wrong password"
else
    pass "bind with wrong password rejected"
fi

echo "[15/$TOTAL] TLS: StartTLS and ldaps:// work"
STARTTLS_OK=false
LDAPS_OK=false
docker exec -e LDAPTLS_REQCERT=never "$CONTAINER" \
    ldapsearch -x -ZZ -H ldap://localhost -b "" -s base >/dev/null 2>&1 && STARTTLS_OK=true
docker exec -e LDAPTLS_REQCERT=never "$CONTAINER" \
    ldapsearch -x -H ldaps://localhost -b "" -s base >/dev/null 2>&1 && LDAPS_OK=true
if $STARTTLS_OK && $LDAPS_OK; then
    pass "StartTLS (ldap://) and ldaps:// both work"
else
    fail "TLS failed (StartTLS=$STARTTLS_OK, ldaps=$LDAPS_OK)"
fi

echo "[16/$TOTAL] reload-tls hot-swaps the cert without a restart"
served_subject() {
    docker exec "$CONTAINER" sh -c \
        'echo | openssl s_client -connect 127.0.0.1:636 2>/dev/null | openssl x509 -noout -subject' 2>/dev/null
}
SUBJ_BEFORE=$(served_subject)
# Issue a fresh cert (new CN) at the paths slapd is configured to use, then ask
# the running server to re-read it — simulating a Let's Encrypt renewal.
docker exec "$CONTAINER" sh -c '
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=renewed.example.test" \
        -keyout /etc/ldap/certs/ldap.key -out /etc/ldap/certs/ldap.crt 2>/dev/null &&
    cp /etc/ldap/certs/ldap.crt /etc/ldap/certs/ca.crt &&
    chown openldap:openldap /etc/ldap/certs/ldap.crt /etc/ldap/certs/ldap.key /etc/ldap/certs/ca.crt' >/dev/null 2>&1
docker exec "$CONTAINER" reload-tls >/dev/null 2>&1 || true
SUBJ_AFTER=$(served_subject)
if echo "$SUBJ_AFTER" | grep -q "CN=renewed.example.test" && [ "$SUBJ_BEFORE" != "$SUBJ_AFTER" ]; then
    pass "renewed cert served after reload-tls (no restart)"
else
    fail "cert not reloaded (before='$SUBJ_BEFORE' after='$SUBJ_AFTER')"
fi

# ── Schema extension (ppolicy) + realistic data + CRUD ──────────────────────
# Helpers that run a write op from stdin inside the container.
dmodify() { docker exec -i "$CONTAINER" ldapmodify -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; }
dadd()    { docker exec -i "$CONTAINER" ldapadd    -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1; }
uwhoami() { docker exec "$CONTAINER" ldapwhoami -x -H "$LDAPI" -D "cn=$1,ou=people,$BASE" -w "$2" >/dev/null 2>&1; }

echo "[17/$TOTAL] ppolicy overlay loaded from /overlays + default policy present"
OV=$(docker exec "$CONTAINER" ldapsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" \
        -D "cn=admin,cn=config" -w "$CONFIG_PW" -b "cn=config" "(olcOverlay=ppolicy)" dn 2>/dev/null)
POL=$(dsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=default,ou=policies,$BASE" -s base pwdLockout 2>/dev/null)
if echo "$OV" | grep -qi "olcOverlay=.*ppolicy,olcDatabase={1}mdb" && echo "$POL" | grep -qi "pwdLockout: TRUE"; then
    pass "ppolicy active on {1}mdb + default policy present"
else
    fail "ppolicy overlay or default policy missing"
fi

echo "[18/$TOTAL] realistic dataset loaded (inetOrgPerson + groupOfUniqueNames)"
NPEOPLE=$(dsearch -LLL -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "ou=people,$BASE" "(objectClass=inetOrgPerson)" dn 2>/dev/null | grep -c '^dn:')
NMEMB=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=everyone,ou=groups,$BASE" uniqueMember 2>/dev/null | grep -c '^uniqueMember:')
if [ "${NPEOPLE:-0}" -ge 11 ] && [ "${NMEMB:-0}" -ge 11 ]; then
    pass "people=$NPEOPLE, group 'everyone' members=$NMEMB"
else
    fail "dataset incomplete (people=$NPEOPLE, members=$NMEMB)"
fi

echo "[19/$TOTAL] a fixture user can bind with its password"
if uwhoami asmith "$USER_PW"; then
    pass "asmith bind works (ppolicy hashed the cleartext on add)"
else
    fail "asmith bind failed"
fi

echo "[20/$TOTAL] CRUD: add, modify, read back, delete a user"
CRUD_OK=true
dadd <<EOF || CRUD_OK=false
dn: cn=tuser,ou=people,$BASE
objectClass: inetOrgPerson
cn: tuser
sn: User
displayName: Temp User
mail: tuser@example.test
userPassword: $USER_PW
EOF
dmodify <<EOF || CRUD_OK=false
dn: cn=tuser,ou=people,$BASE
changetype: modify
replace: mail
mail: changed@example.test
EOF
dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=tuser,ou=people,$BASE" mail 2>/dev/null | grep -qi "changed@example.test" || CRUD_OK=false
docker exec "$CONTAINER" ldapdelete -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" "cn=tuser,ou=people,$BASE" >/dev/null 2>&1 || CRUD_OK=false
# A base search on the deleted DN must now fail (no such object).
docker exec "$CONTAINER" ldapsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=tuser,ou=people,$BASE" -s base dn >/dev/null 2>&1 && CRUD_OK=false
if $CRUD_OK; then pass "add/modify/read/delete cycle works"; else fail "CRUD cycle failed"; fi

echo "[21/$TOTAL] CRUD: add a member to a group"
dmodify <<EOF
dn: cn=testers,ou=groups,$BASE
changetype: modify
add: uniqueMember
uniqueMember: cn=zmuller,ou=people,$BASE
EOF
if dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=testers,ou=groups,$BASE" uniqueMember 2>/dev/null | grep -qi "cn=zmuller,"; then
    pass "uniqueMember added to cn=testers"
else
    fail "group membership update failed"
fi

echo "[22/$TOTAL] CRUD: change a user's password (ldappasswd) and bind with it"
if docker exec "$CONTAINER" ldappasswd -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" \
        -s NewSecret456 "cn=ggreen,ou=people,$BASE" >/dev/null 2>&1 \
        && uwhoami ggreen NewSecret456 && ! uwhoami ggreen "$USER_PW"; then
    pass "password changed; new password binds, old one rejected"
else
    fail "password change/bind failed"
fi

echo "[23/$TOTAL] ppolicy: account locks after repeated bad binds"
for _ in 1 2 3; do uwhoami jkent wrong-pw || true; done
if uwhoami jkent "$USER_PW"; then
    fail "account not locked after 3 failed binds"
else
    pass "account locked after pwdMaxFailure failed binds"
fi

echo "[24/$TOTAL] ppolicy: disable/enable a user via pwdAccountLockedTime"
DISABLED=false; ENABLED=false
dmodify <<EOF
dn: cn=hhill,ou=people,$BASE
changetype: modify
replace: pwdAccountLockedTime
pwdAccountLockedTime: 20200101000000Z
EOF
uwhoami hhill "$USER_PW" || DISABLED=true
dmodify <<EOF
dn: cn=hhill,ou=people,$BASE
changetype: modify
delete: pwdAccountLockedTime
EOF
uwhoami hhill "$USER_PW" && ENABLED=true
if $DISABLED && $ENABLED; then
    pass "pwdAccountLockedTime disables then re-enables bind"
else
    fail "disable/enable failed (disabled=$DISABLED enabled=$ENABLED)"
fi

# ── Default overlays (osixia parity): memberof + refint ─────────────────────
echo "[25/$TOTAL] memberof computes reverse membership (memberOf)"
MO=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=asmith,ou=people,$BASE" memberOf 2>/dev/null)
if echo "$MO" | grep -qi "cn=developers,ou=groups,$BASE" && echo "$MO" | grep -qi "cn=everyone,ou=groups,$BASE"; then
    pass "asmith has computed memberOf (developers + everyone)"
else
    fail "memberOf not computed (got: $(echo "$MO" | grep -i memberof | tr '\n' ' '))"
fi

echo "[26/$TOTAL] refint cleans DN references when an entry is deleted"
docker exec "$CONTAINER" ldapdelete -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" "cn=ddavis,ou=people,$BASE" >/dev/null 2>&1
if dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=admins,ou=groups,$BASE" uniqueMember 2>/dev/null | grep -qi "cn=ddavis,"; then
    fail "refint did not remove the deleted user from cn=admins"
else
    pass "deleting cn=ddavis removed it from cn=admins uniqueMember"
fi

# ── osixia parity: memberOf index, ppolicy schema, TLS floor, strict ACL ────
ccfg() { docker exec "$CONTAINER" ldapsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "cn=admin,cn=config" -w "$CONFIG_PW" "$@" 2>/dev/null; }

echo "[27/$TOTAL] memberOf is indexed on the mdb backend"
if ccfg -b "olcDatabase={1}mdb,cn=config" -s base olcDbIndex | grep -qiE '^olcDbIndex: memberOf eq'; then
    pass "olcDbIndex memberOf eq present"
else
    fail "memberOf is not indexed"
fi

echo "[28/$TOTAL] ppolicy module (schema) loaded by default"
if ccfg -b "cn=module{0},cn=config" -s base olcModuleLoad | grep -qi 'ppolicy'; then
    pass "ppolicy module loaded — pwdPolicy schema available by default"
else
    fail "ppolicy module not loaded by default"
fi

echo "[29/$TOTAL] TLS hardening: protocol floor configured + TLS 1.2 works"
PMIN=$(ccfg -b cn=config -s base olcTLSProtocolMin | sed -n 's/^olcTLSProtocolMin: //p')
T12=$(docker exec "$CONTAINER" sh -c 'echo | openssl s_client -connect 127.0.0.1:636 -tls1_2 2>/dev/null | openssl x509 -noout -subject 2>/dev/null' || true)
if [ -n "$PMIN" ] && [ "$PMIN" != "0.0" ] && [ -n "$T12" ]; then
    pass "olcTLSProtocolMin=$PMIN and TLS 1.2 handshake works"
else
    fail "TLS floor not enforced (min='$PMIN' tls1.2_cert='$T12')"
fi

echo "[30/$TOTAL] ACL: a user reads its own entry but not others (osixia self-read-only)"
SELF=$(docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" -D "cn=asmith,ou=people,$BASE" -w "$USER_PW" -b "cn=asmith,ou=people,$BASE" -s base cn 2>/dev/null | grep -c '^cn:' || true)
OTHER=$(docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" -D "cn=asmith,ou=people,$BASE" -w "$USER_PW" -b "cn=bjones,ou=people,$BASE" -s base cn 2>/dev/null | grep -c '^cn:' || true)
if [ "${SELF:-0}" -ge 1 ] && [ "${OTHER:-0}" -eq 0 ]; then
    pass "asmith reads self ($SELF) but not bjones ($OTHER)"
else
    fail "self-read-only ACL not enforced (self=$SELF other=$OTHER)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
