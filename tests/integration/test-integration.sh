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
RPW_DN="cn=readpw,${BASE}"      # second readonly account that may read userPassword
RPW_PW="readpwpw"
USER_PW="Secret123"   # shared fixture password (see fixtures/bootstrap/21-people.ldif)
LDAPI="ldapi://%2Frun%2Fslapd%2Fldapi"

PASS=0
FAIL=0
TOTAL=64

# Standalone containers spun up by the configuration-variant tests.
EXTRA_CONTAINERS="openldap-notls openldap-domain openldap-basedn openldap-mtls openldap-cca openldap-loctz openldap-nolb openldap-nouniq"
cleanup() {
    echo ""
    echo "--- Cleanup ---"
    cd "$SCRIPT_DIR"
    IMAGE_NAME="$IMAGE_NAME" IMAGE_TAG="$IMAGE_TAG" docker compose down -v 2>/dev/null || true
    # shellcheck disable=SC2086
    docker rm -f $EXTRA_CONTAINERS >/dev/null 2>&1 || true
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
if ! wait_for_ldap 120; then
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

# ── Access-control matrix ───────────────────────────────────────────────────
# Roles: admin (rootdn), readonly (non-admin service account), a regular user
# (asmith), and anonymous. Helper: count inetOrgPerson entries an identity can
# see under ou=people. "" DN = anonymous.
people_seen() {
    bind=""
    [ -n "$1" ] && bind="-D $1 -w $2"
    # shellcheck disable=SC2086
    docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" $bind \
        -b "ou=people,$BASE" "(objectClass=inetOrgPerson)" dn 2>/dev/null | grep -c '^dn:' || true
}
canread_pw() {
    docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" -D "$1" -w "$2" \
        -b "cn=$3,ou=people,$BASE" -s base userPassword 2>/dev/null | grep -c '^userPassword' || true
}

ADMIN_SEES=$(people_seen "$ADMIN_DN" "$ADMIN_PW")

echo "[30/$TOTAL] admin (rootdn) reads every user entry"
if [ "${ADMIN_SEES:-0}" -ge 9 ]; then
    pass "admin sees all $ADMIN_SEES users"
else
    fail "admin should see the whole directory (saw $ADMIN_SEES)"
fi

echo "[31/$TOTAL] readonly service account (non-admin) reads all users"
RO_SEES=$(people_seen "$RO_DN" "$RO_PW")
if [ "${RO_SEES:-0}" = "${ADMIN_SEES:-0}" ] && [ "${RO_SEES:-0}" -ge 9 ]; then
    pass "readonly sees all $RO_SEES users (same as admin)"
else
    fail "readonly should read all users (saw $RO_SEES vs admin $ADMIN_SEES)"
fi

echo "[32/$TOTAL] a regular user reads its own entry but not another's"
# With "by self read" a user can read its own entry by DN, but cannot read
# others (nor enumerate the subtree — the ou=people base is itself denied).
U_SELF=$(docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" -D "cn=asmith,ou=people,$BASE" -w "$USER_PW" -b "cn=asmith,ou=people,$BASE" -s base cn 2>/dev/null | grep -c '^cn:' || true)
U_OTHER=$(docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" -D "cn=asmith,ou=people,$BASE" -w "$USER_PW" -b "cn=bjones,ou=people,$BASE" -s base cn 2>/dev/null | grep -c '^cn:' || true)
U_ENUM=$(people_seen "cn=asmith,ou=people,$BASE" "$USER_PW")
if [ "${U_SELF:-0}" -ge 1 ] && [ "${U_OTHER:-0}" -eq 0 ] && [ "${U_ENUM:-0}" -eq 0 ]; then
    pass "asmith reads self ($U_SELF), not bjones ($U_OTHER), cannot enumerate ($U_ENUM)"
else
    fail "self-read-only wrong (self=$U_SELF other=$U_OTHER enum=$U_ENUM)"
fi

echo "[33/$TOTAL] anonymous reads no user entries"
ANON_SEES=$(people_seen "" "")
if [ "${ANON_SEES:-0}" = "0" ]; then
    pass "anonymous sees no user entries"
else
    fail "anonymous should see nothing under ou=people (saw $ANON_SEES)"
fi

echo "[34/$TOTAL] userPassword is private (admin yes; readonly/other user no)"
PW_ADMIN=$(canread_pw "$ADMIN_DN" "$ADMIN_PW" asmith)
PW_RO=$(canread_pw "$RO_DN" "$RO_PW" asmith)
PW_OTHER=$(canread_pw "cn=bjones,ou=people,$BASE" "$USER_PW" asmith)
if [ "${PW_ADMIN:-0}" -ge 1 ] && [ "${PW_RO:-0}" -eq 0 ] && [ "${PW_OTHER:-0}" -eq 0 ]; then
    pass "only admin can read userPassword (admin=$PW_ADMIN ro=$PW_RO other=$PW_OTHER)"
else
    fail "userPassword privacy wrong (admin=$PW_ADMIN ro=$PW_RO other=$PW_OTHER)"
fi

echo "[35/$TOTAL] a regular user may change its own password but not edit its entry"
# self can change own password (write on userPassword)
PWOK=false; ATTROK=false
docker exec "$CONTAINER" ldappasswd -x -H "$LDAPI" -D "cn=cmiller,ou=people,$BASE" -w "$USER_PW" -s NewSecret789 >/dev/null 2>&1 \
    && uwhoami cmiller NewSecret789 && PWOK=true
# self may NOT modify other attributes of its own entry (self has read, not write)
if docker exec -i "$CONTAINER" ldapmodify -x -H "$LDAPI" -D "cn=cmiller,ou=people,$BASE" -w NewSecret789 >/dev/null 2>&1 <<EOF
dn: cn=cmiller,ou=people,$BASE
changetype: modify
replace: mail
mail: hacked@example.test
EOF
then ATTROK=false; else ATTROK=true; fi
if $PWOK && $ATTROK; then
    pass "self password change allowed; self attribute edit denied"
else
    fail "self-write semantics wrong (pwChange=$PWOK attrEditDenied=$ATTROK)"
fi

echo "[36/$TOTAL] password-reading readonly account: reads hashes + all users, no write"
RPW_PWREAD=$(canread_pw "$RPW_DN" "$RPW_PW" asmith)
RPW_SEES=$(people_seen "$RPW_DN" "$RPW_PW")
RPW_WRITE=denied
docker exec -i "$CONTAINER" ldapadd -x -H "$LDAPI" -D "$RPW_DN" -w "$RPW_PW" >/dev/null 2>&1 <<EOF && RPW_WRITE=allowed
dn: cn=intruder2,ou=people,$BASE
objectClass: inetOrgPerson
cn: intruder2
sn: x
EOF
if [ "${RPW_PWREAD:-0}" -ge 1 ] && [ "${RPW_SEES:-0}" = "${ADMIN_SEES:-0}" ] && [ "$RPW_WRITE" = "denied" ]; then
    pass "readpw reads userPassword ($RPW_PWREAD) and all $RPW_SEES users, write denied"
else
    fail "readpw wrong (pwRead=$RPW_PWREAD sees=$RPW_SEES vs admin=$ADMIN_SEES write=$RPW_WRITE)"
fi

# ── Baked schema: openssh-lpk ───────────────────────────────────────────────
echo "[37/$TOTAL] openssh-lpk schema baked in (sshPublicKey usable)"
SSHKEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestonlyexamplekeyvalue000000 svc@example.test"
docker exec -i "$CONTAINER" ldapmodify -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF
dn: cn=ffoster,ou=people,$BASE
changetype: modify
add: objectClass
objectClass: ldapPublicKey
-
add: sshPublicKey
sshPublicKey: $SSHKEY
EOF
if dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=ffoster,ou=people,$BASE" -s base sshPublicKey 2>/dev/null | grep -q "ssh-ed25519"; then
    pass "added ldapPublicKey + sshPublicKey and read it back"
else
    fail "openssh-lpk schema not available (sshPublicKey could not be stored)"
fi

# ── Data-plane edge cases ───────────────────────────────────────────────────
echo "[38/$TOTAL] indexed search: substring and presence filters return matches"
SUB=$(dsearch -LLL -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "ou=people,$BASE" "(cn=a*)" dn 2>/dev/null | grep -c '^dn:' || true)
PRES=$(dsearch -LLL -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "ou=people,$BASE" "(mail=*)" dn 2>/dev/null | grep -c '^dn:' || true)
if [ "${SUB:-0}" -ge 1 ] && [ "${PRES:-0}" -ge 9 ]; then
    pass "substring (cn=a*)=$SUB, presence (mail=*)=$PRES"
else
    fail "indexed search returned too little (sub=$SUB pres=$PRES)"
fi

echo "[39/$TOTAL] ModRDN: rename a user and refint updates group references"
docker exec "$CONTAINER" ldapmodrdn -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" "cn=ijames,ou=people,$BASE" "cn=ijames2" >/dev/null 2>&1
RN_NEW=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=testers,ou=groups,$BASE" uniqueMember 2>/dev/null | grep -c 'cn=ijames2,' || true)
RN_OLD=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=testers,ou=groups,$BASE" uniqueMember 2>/dev/null | grep -c 'cn=ijames,' || true)
if [ "${RN_NEW:-0}" -ge 1 ] && [ "${RN_OLD:-0}" -eq 0 ]; then
    pass "rename propagated by refint (testers -> cn=ijames2)"
else
    fail "refint did not update references on rename (new=$RN_NEW old=$RN_OLD)"
fi

echo "[40/$TOTAL] ppolicy: password history blocks reuse"
docker exec "$CONTAINER" ldappasswd -x -H "$LDAPI" -D "cn=bjones,ou=people,$BASE" -w "$USER_PW" -s Hist1Pass! >/dev/null 2>&1
docker exec "$CONTAINER" ldappasswd -x -H "$LDAPI" -D "cn=bjones,ou=people,$BASE" -w Hist1Pass! -s Hist2Pass! >/dev/null 2>&1
if docker exec "$CONTAINER" ldappasswd -x -H "$LDAPI" -D "cn=bjones,ou=people,$BASE" -w Hist2Pass! -s Hist1Pass! >/dev/null 2>&1; then
    fail "reusing a password from history was allowed"
else
    pass "reusing a password in history is rejected"
fi

echo "[41/$TOTAL] ppolicy: minimum length enforced on self password change"
if docker exec "$CONTAINER" ldappasswd -x -H "$LDAPI" -D "cn=eevans,ou=people,$BASE" -w "$USER_PW" -s short >/dev/null 2>&1; then
    fail "a password below pwdMinLength was accepted"
else
    pass "password below pwdMinLength is rejected"
fi

echo "[42/$TOTAL] binary attribute round-trip (jpegPhoto, base64)"
# Minimal valid JPEG (SOI+EOI markers) — slapd validates the jpegPhoto syntax.
BLOB="/9j/2Q=="
docker exec -i "$CONTAINER" ldapmodify -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF
dn: cn=asmith,ou=people,$BASE
changetype: modify
add: jpegPhoto
jpegPhoto:: $BLOB
EOF
GOT=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=asmith,ou=people,$BASE" jpegPhoto 2>/dev/null | sed -n 's/^jpegPhoto:: //p')
if [ "$GOT" = "$BLOB" ]; then
    pass "jpegPhoto stored and read back byte-identical"
else
    fail "binary round-trip mismatch (got '$GOT')"
fi

echo "[43/$TOTAL] rootDSE advertises supported features"
RD=$(docker exec "$CONTAINER" ldapsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -b "" -s base supportedLDAPVersion supportedControl 2>/dev/null)
if echo "$RD" | grep -q "supportedLDAPVersion: 3" && echo "$RD" | grep -qi "^supportedControl:"; then
    pass "rootDSE advertises LDAPv3 and controls"
else
    fail "rootDSE missing supported* attributes"
fi

# ── Container behaviour ─────────────────────────────────────────────────────
echo "[44/$TOTAL] container HEALTHCHECK reports healthy"
HS=""
for _ in $(seq 1 30); do
    HS=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null || true)
    [ "$HS" = "healthy" ] && break
    sleep 2
done
if [ "$HS" = "healthy" ]; then
    pass "healthcheck status is healthy"
else
    fail "healthcheck not healthy (status=$HS)"
fi

echo "[45/$TOTAL] slapd runs as the non-root openldap user"
P1=$(docker exec "$CONTAINER" sh -c 'cat /proc/1/comm; awk "/^Uid:/{print \$2}" /proc/1/status' 2>/dev/null || true)
if echo "$P1" | grep -qx slapd && echo "$P1" | grep -qx 999; then
    pass "PID 1 is slapd running as uid 999"
else
    fail "slapd not running as non-root (got: $(echo "$P1" | tr '\n' ' '))"
fi

echo "[46/$TOTAL] slapcat produces a complete LDIF backup"
# The admin tools default to the Symas config dir, so point -F at our slapd.d.
SC=$(docker exec "$CONTAINER" slapcat -F /etc/ldap/slapd.d -o ldif-wrap=no -b "$BASE" 2>/dev/null | grep -c '^dn:' || true)
if [ "${SC:-0}" -ge 9 ]; then
    pass "slapcat dumped $SC entries"
else
    fail "slapcat backup incomplete ($SC entries)"
fi

echo "[47/$TOTAL] restart: data persists and bootstrap is skipped"
docker exec -i "$CONTAINER" ldapadd -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF
dn: cn=restartmarker,ou=people,$BASE
objectClass: inetOrgPerson
cn: restartmarker
sn: marker
EOF
docker restart "$CONTAINER" >/dev/null 2>&1
RST_OK=false
for _ in $(seq 1 90); do
    docker exec "$CONTAINER" ldapsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE" -s base o >/dev/null 2>&1 && { RST_OK=true; break; }
    sleep 1
done
MARK=$(docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=restartmarker,ou=people,$BASE" -s base cn 2>/dev/null | grep -c '^cn:' || true)
SKIP=$(docker logs "$CONTAINER" 2>&1 | grep -c "skipping bootstrap" || true)
if $RST_OK && [ "${MARK:-0}" -ge 1 ] && [ "${SKIP:-0}" -ge 1 ]; then
    pass "data survived restart and bootstrap was skipped"
else
    fail "restart behaviour wrong (ready=$RST_OK marker=$MARK skipMsg=$SKIP)"
fi

# ── Configuration variants (standalone containers) ──────────────────────────
echo "[48/$TOTAL] non-TLS mode: ldap:// works, ldaps:// is not served"
docker rm -f openldap-notls >/dev/null 2>&1 || true
docker run -d --name openldap-notls -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin "$IMAGE" >/dev/null 2>&1
NT_OK=false
for _ in $(seq 1 90); do docker exec openldap-notls ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && { NT_OK=true; break; }; sleep 1; done
NT_LDAP=false; NT_LDAPS=false
docker exec openldap-notls ldapsearch -x -H ldap://localhost -b "" -s base >/dev/null 2>&1 && NT_LDAP=true
docker exec openldap-notls ldapsearch -x -H ldaps://localhost -b "" -s base >/dev/null 2>&1 || NT_LDAPS=true
docker rm -f openldap-notls >/dev/null 2>&1 || true
if $NT_OK && $NT_LDAP && $NT_LDAPS; then
    pass "ldap:// works and ldaps:// is absent when LDAP_TLS=false"
else
    fail "non-TLS mode wrong (ready=$NT_OK ldap=$NT_LDAP ldapsAbsent=$NT_LDAPS)"
fi

echo "[49/$TOTAL] entrypoint runs a non-slapd command (CMD override)"
CMD_OUT=$(docker run --rm -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin "$IMAGE" sh -c 'echo CMD_OVERRIDE_OK' 2>/dev/null || true)
if echo "$CMD_OUT" | grep -q "CMD_OVERRIDE_OK"; then
    pass "custom command executed via the entrypoint"
else
    fail "CMD override did not run"
fi

echo "[50/$TOTAL] base DN derived from domain and overridable"
docker rm -f openldap-domain openldap-basedn >/dev/null 2>&1 || true
docker run -d --name openldap-domain  -e LDAP_DOMAIN=a.b.test    -e LDAP_ADMIN_PASSWORD=admin "$IMAGE" >/dev/null 2>&1
docker run -d --name openldap-basedn  -e LDAP_DOMAIN=example.test -e LDAP_BASE_DN="dc=acme,dc=internal" -e LDAP_ADMIN_PASSWORD=admin "$IMAGE" >/dev/null 2>&1
for _ in $(seq 1 90); do docker exec openldap-domain ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && break; sleep 1; done
for _ in $(seq 1 90); do docker exec openldap-basedn ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && break; sleep 1; done
DERIVED=false; OVERRIDE=false
docker exec openldap-domain ldapsearch -LLL -x -H "$LDAPI" -b "" -s base namingContexts 2>/dev/null | grep -qi "dc=a,dc=b,dc=test" && DERIVED=true
docker exec openldap-basedn ldapsearch -LLL -x -H "$LDAPI" -b "" -s base namingContexts 2>/dev/null | grep -qi "dc=acme,dc=internal" && OVERRIDE=true
docker rm -f openldap-domain openldap-basedn >/dev/null 2>&1 || true
if $DERIVED && $OVERRIDE; then
    pass "a.b.test -> dc=a,dc=b,dc=test; LDAP_BASE_DN override honoured"
else
    fail "base DN handling wrong (derived=$DERIVED override=$OVERRIDE)"
fi

# ── Overlay/ppolicy depth + TLS depth ───────────────────────────────────────
echo "[51/$TOTAL] cn=config persisted across the restart (overlays still active)"
PP_PERSIST=false; MO_PERSIST=false
ccfg -b "cn=config" "(olcOverlay=ppolicy)" dn | grep -qi ppolicy && PP_PERSIST=true
dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=asmith,ou=people,$BASE" memberOf 2>/dev/null | grep -qi "cn=developers," && MO_PERSIST=true
if $PP_PERSIST && $MO_PERSIST; then
    pass "ppolicy overlay and computed memberOf survived the restart"
else
    fail "config did not persist (ppolicy=$PP_PERSIST memberOf=$MO_PERSIST)"
fi

echo "[52/$TOTAL] ppolicy: admin unlocks a locked account"
for _ in 1 2 3; do uwhoami jkent wrong-pw || true; done
PL_LOCKED=false; PL_UNLOCKED=false
uwhoami jkent "$USER_PW" || PL_LOCKED=true
docker exec -i "$CONTAINER" ldapmodify -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF
dn: cn=jkent,ou=people,$BASE
changetype: modify
delete: pwdAccountLockedTime
EOF
uwhoami jkent "$USER_PW" && PL_UNLOCKED=true
if $PL_LOCKED && $PL_UNLOCKED; then
    pass "locked account unlocked by clearing pwdAccountLockedTime"
else
    fail "admin unlock failed (locked=$PL_LOCKED unlocked=$PL_UNLOCKED)"
fi

echo "[53/$TOTAL] deleting a group removes memberOf from its members"
GD_BEFORE=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=ggreen,ou=people,$BASE" memberOf 2>/dev/null | grep -c 'cn=developers,' || true)
docker exec "$CONTAINER" ldapdelete -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" "cn=developers,ou=groups,$BASE" >/dev/null 2>&1
GD_AFTER=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=ggreen,ou=people,$BASE" memberOf 2>/dev/null | grep -c 'cn=developers,' || true)
if [ "${GD_BEFORE:-0}" -ge 1 ] && [ "${GD_AFTER:-0}" -eq 0 ]; then
    pass "members' memberOf cleaned when the group was deleted"
else
    fail "memberOf not cleaned on group delete (before=$GD_BEFORE after=$GD_AFTER)"
fi

echo "[54/$TOTAL] removing a member from a group drops its memberOf"
MR_BEFORE=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=hhill,ou=people,$BASE" memberOf 2>/dev/null | grep -c 'cn=everyone,' || true)
docker exec -i "$CONTAINER" ldapmodify -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF
dn: cn=everyone,ou=groups,$BASE
changetype: modify
delete: uniqueMember
uniqueMember: cn=hhill,ou=people,$BASE
EOF
MR_AFTER=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=hhill,ou=people,$BASE" memberOf 2>/dev/null | grep -c 'cn=everyone,' || true)
if [ "${MR_BEFORE:-0}" -ge 1 ] && [ "${MR_AFTER:-0}" -eq 0 ]; then
    pass "memberof dropped the reverse membership on member removal"
else
    fail "memberOf not updated on member removal (before=$MR_BEFORE after=$MR_AFTER)"
fi

echo "[55/$TOTAL] ppolicy: pwdLockoutDuration auto-unlocks after the window"
docker exec -i "$CONTAINER" ldapmodify -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF
dn: cn=default,ou=policies,$BASE
changetype: modify
replace: pwdLockoutDuration
pwdLockoutDuration: 3
EOF
for _ in 1 2 3; do uwhoami ffoster wrong-pw || true; done
AU_LOCKED=false; AU_UNLOCKED=false
uwhoami ffoster "$USER_PW" || AU_LOCKED=true
sleep 4
uwhoami ffoster "$USER_PW" && AU_UNLOCKED=true
if $AU_LOCKED && $AU_UNLOCKED; then
    pass "account auto-unlocked after pwdLockoutDuration elapsed"
else
    fail "auto-unlock failed (locked=$AU_LOCKED unlocked=$AU_UNLOCKED)"
fi

# ── TLS: mounted certs, renewal reload, mutual TLS ──────────────────────────
echo "[56/$TOTAL] a mounted TLS certificate is served (not the self-signed fallback)"
MNT="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=mounted-server" -keyout "$MNT/ldap.key" -out "$MNT/ldap.crt" 2>/dev/null
cp "$MNT/ldap.crt" "$MNT/ca.crt"
# slapd (uid 999) must traverse the mounted dir and read the files; mktemp -d is
# 0700, which blocks it on Linux (Docker Desktop on macOS masks this).
chmod 755 "$MNT"; chmod 644 "$MNT"/*
docker rm -f openldap-mtls >/dev/null 2>&1 || true
docker run -d --name openldap-mtls -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin \
    -e LDAP_TLS=true -e LDAP_TLS_VERIFY_CLIENT=never -v "$MNT:/container/certs" "$IMAGE" >/dev/null 2>&1
MC_OK=false
for _ in $(seq 1 90); do docker exec openldap-mtls ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && { MC_OK=true; break; }; sleep 1; done
MC_SUBJ=$(docker exec openldap-mtls sh -c 'echo | openssl s_client -connect 127.0.0.1:636 2>/dev/null | openssl x509 -noout -subject' 2>/dev/null || true)
if $MC_OK && echo "$MC_SUBJ" | grep -q "CN=mounted-server"; then
    pass "slapd served the mounted certificate ($MC_SUBJ)"
else
    fail "mounted cert not served (ready=$MC_OK subj=$MC_SUBJ)"
fi

echo "[57/$TOTAL] reload-tls applies a renewed mounted certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=mounted-renewed" -keyout "$MNT/ldap.key" -out "$MNT/ldap.crt" 2>/dev/null
cp -f "$MNT/ldap.crt" "$MNT/ca.crt"; chmod 644 "$MNT"/*
docker exec openldap-mtls reload-tls >/dev/null 2>&1 || true
MC_SUBJ2=$(docker exec openldap-mtls sh -c 'echo | openssl s_client -connect 127.0.0.1:636 2>/dev/null | openssl x509 -noout -subject' 2>/dev/null || true)
docker rm -f openldap-mtls >/dev/null 2>&1 || true
rm -rf "$MNT"
if echo "$MC_SUBJ2" | grep -q "CN=mounted-renewed"; then
    pass "reload-tls served the renewed mounted cert ($MC_SUBJ2)"
else
    fail "reload-tls did not pick up the renewed mounted cert (subj=$MC_SUBJ2)"
fi

echo "[58/$TOTAL] mutual TLS: LDAP_TLS_VERIFY_CLIENT=demand requires a client cert"
MT="$(mktemp -d)"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Test CA" -keyout "$MT/ca.key" -out "$MT/ca.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=localhost" -keyout "$MT/ldap.key" -out "$MT/srv.csr" 2>/dev/null
openssl x509 -req -in "$MT/srv.csr" -CA "$MT/ca.crt" -CAkey "$MT/ca.key" -CAcreateserial -days 2 -out "$MT/ldap.crt" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -subj "/CN=client" -keyout "$MT/client.key" -out "$MT/cli.csr" 2>/dev/null
openssl x509 -req -in "$MT/cli.csr" -CA "$MT/ca.crt" -CAkey "$MT/ca.key" -CAcreateserial -days 2 -out "$MT/client.crt" 2>/dev/null
chmod 755 "$MT"; chmod 644 "$MT"/*
docker rm -f openldap-cca >/dev/null 2>&1 || true
docker run -d --name openldap-cca -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin \
    -e LDAP_TLS=true -e LDAP_TLS_VERIFY_CLIENT=demand -v "$MT:/container/certs" "$IMAGE" >/dev/null 2>&1
CC_OK=false
for _ in $(seq 1 90); do docker exec openldap-cca ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && { CC_OK=true; break; }; sleep 1; done
CC_NOCERT=false; CC_WITHCERT=false
docker exec -e LDAPTLS_REQCERT=allow openldap-cca \
    ldapsearch -x -H ldaps://localhost -b "" -s base >/dev/null 2>&1 || CC_NOCERT=true
docker exec -e LDAPTLS_REQCERT=allow -e LDAPTLS_CERT=/container/certs/client.crt -e LDAPTLS_KEY=/container/certs/client.key openldap-cca \
    ldapsearch -x -H ldaps://localhost -b "" -s base >/dev/null 2>&1 && CC_WITHCERT=true
docker rm -f openldap-cca >/dev/null 2>&1 || true
rm -rf "$MT"
if $CC_OK && $CC_NOCERT && $CC_WITHCERT; then
    pass "ldaps rejected without a client cert, accepted with a valid one"
else
    fail "mutual TLS wrong (ready=$CC_OK noCertRejected=$CC_NOCERT withCert=$CC_WITHCERT)"
fi

# ── Locale & timezone ───────────────────────────────────────────────────────
echo "[59/$TOTAL] default locale is UTF-8"
LANG_VAL=$(docker exec "$CONTAINER" sh -c 'printf %s "$LANG"' 2>/dev/null)
CHARMAP=$(docker exec "$CONTAINER" locale charmap 2>/dev/null)
if [ "$CHARMAP" = "UTF-8" ] && echo "$LANG_VAL" | grep -qi 'UTF-8'; then
    pass "LANG=$LANG_VAL, charmap=$CHARMAP"
else
    fail "default locale is not UTF-8 (LANG=$LANG_VAL charmap=$CHARMAP)"
fi

echo "[60/$TOTAL] TZ sets the timezone and a non-default locale is generated"
docker rm -f openldap-loctz >/dev/null 2>&1 || true
docker run -d --name openldap-loctz -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin \
    -e TZ=Europe/Berlin -e LANG=en_US.UTF-8 "$IMAGE" >/dev/null 2>&1
LT_OK=false
for _ in $(seq 1 90); do docker exec openldap-loctz ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && { LT_OK=true; break; }; sleep 1; done
LT_TZ=$(docker exec openldap-loctz cat /etc/timezone 2>/dev/null)
LT_ZONE=$(docker exec openldap-loctz date +%Z 2>/dev/null)
LT_LOC=$(docker exec openldap-loctz sh -c 'locale -a 2>/dev/null | grep -ic "^en_US.utf8$"' 2>/dev/null || true)
docker rm -f openldap-loctz >/dev/null 2>&1 || true
if $LT_OK && [ "$LT_TZ" = "Europe/Berlin" ] && echo "$LT_ZONE" | grep -qE 'CES?T' && [ "${LT_LOC:-0}" -ge 1 ]; then
    pass "TZ=Europe/Berlin (zone $LT_ZONE) and en_US.UTF-8 generated"
else
    fail "locale/TZ wrong (ready=$LT_OK tz=$LT_TZ zone=$LT_ZONE en_US=$LT_LOC)"
fi

# ── lastbind overlay ────────────────────────────────────────────────────────
echo "[61/$TOTAL] lastbind overlay records authTimestamp on a successful bind"
dadd <<EOF
dn: cn=lbuser,ou=people,$BASE
objectClass: inetOrgPerson
cn: lbuser
sn: User
userPassword: $USER_PW
EOF
LB_BEFORE=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=lbuser,ou=people,$BASE" -s base authTimestamp 2>/dev/null | grep -c '^authTimestamp:' || true)
uwhoami lbuser "$USER_PW"
LB_AFTER=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=lbuser,ou=people,$BASE" -s base authTimestamp 2>/dev/null | grep -c '^authTimestamp:' || true)
if [ "${LB_BEFORE:-0}" -eq 0 ] && [ "${LB_AFTER:-0}" -ge 1 ]; then
    pass "authTimestamp absent before, recorded after bind"
else
    fail "lastbind did not record authTimestamp (before=$LB_BEFORE after=$LB_AFTER)"
fi

echo "[62/$TOTAL] lastbind disabled (default): authTimestamp is NOT written"
docker rm -f openldap-nolb >/dev/null 2>&1 || true
docker run -d --name openldap-nolb -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin "$IMAGE" >/dev/null 2>&1
NLB_OK=false
for _ in $(seq 1 90); do docker exec openldap-nolb ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && { NLB_OK=true; break; }; sleep 1; done
docker exec -i openldap-nolb ldapadd -x -H "$LDAPI" -D "cn=admin,dc=example,dc=test" -w admin >/dev/null 2>&1 <<EOF
dn: cn=nlb,ou=people,dc=example,dc=test
objectClass: inetOrgPerson
cn: nlb
sn: x
userPassword: Secret123
EOF
docker exec openldap-nolb ldapwhoami -x -H "$LDAPI" -D "cn=nlb,ou=people,dc=example,dc=test" -w Secret123 >/dev/null 2>&1
NLB_TS=$(docker exec openldap-nolb ldapsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "cn=admin,dc=example,dc=test" -w admin -b "cn=nlb,ou=people,dc=example,dc=test" -s base authTimestamp 2>/dev/null | grep -c '^authTimestamp:' || true)
docker rm -f openldap-nolb >/dev/null 2>&1 || true
if $NLB_OK && [ "${NLB_TS:-1}" -eq 0 ]; then
    pass "no authTimestamp written when LDAP_LASTBIND is unset"
else
    fail "authTimestamp written despite lastbind disabled (ready=$NLB_OK ts=$NLB_TS)"
fi

# ── unique overlay ──────────────────────────────────────────────────────────
echo "[63/$TOTAL] unique overlay rejects a duplicate mail, allows a unique one"
# asmith already has mail asmith@example.test (fixture) — a duplicate must fail.
DUP_REJECTED=false; UNIQ_OK=false
docker exec -i "$CONTAINER" ldapadd -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF || DUP_REJECTED=true
dn: cn=dupmail,ou=people,$BASE
objectClass: inetOrgPerson
cn: dupmail
sn: x
mail: asmith@example.test
EOF
docker exec -i "$CONTAINER" ldapadd -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF && UNIQ_OK=true
dn: cn=uniqmail,ou=people,$BASE
objectClass: inetOrgPerson
cn: uniqmail
sn: x
mail: uniqmail@example.test
EOF
if $DUP_REJECTED && $UNIQ_OK; then
    pass "duplicate mail rejected, unique mail accepted"
else
    fail "unique enforcement wrong (dupRejected=$DUP_REJECTED uniqueAccepted=$UNIQ_OK)"
fi

echo "[64/$TOTAL] unique disabled (default): a duplicate mail is allowed"
docker rm -f openldap-nouniq >/dev/null 2>&1 || true
docker run -d --name openldap-nouniq -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin "$IMAGE" >/dev/null 2>&1
NU_OK=false
for _ in $(seq 1 90); do docker exec openldap-nouniq ldapsearch -x -H "$LDAPI" -b "" -s base >/dev/null 2>&1 && { NU_OK=true; break; }; sleep 1; done
docker exec -i openldap-nouniq ldapadd -x -H "$LDAPI" -D "cn=admin,dc=example,dc=test" -w admin >/dev/null 2>&1 <<EOF
dn: cn=a,ou=people,dc=example,dc=test
objectClass: inetOrgPerson
cn: a
sn: x
mail: same@example.test
EOF
NU_DUP=false
docker exec -i openldap-nouniq ldapadd -x -H "$LDAPI" -D "cn=admin,dc=example,dc=test" -w admin >/dev/null 2>&1 <<EOF && NU_DUP=true
dn: cn=b,ou=people,dc=example,dc=test
objectClass: inetOrgPerson
cn: b
sn: x
mail: same@example.test
EOF
docker rm -f openldap-nouniq >/dev/null 2>&1 || true
if $NU_OK && $NU_DUP; then
    pass "duplicate mail accepted when LDAP_UNIQUE is unset"
else
    fail "unexpected enforcement with unique disabled (ready=$NU_OK dupAccepted=$NU_DUP)"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
