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
RO_DN="cn=readonly,${BASE}"
RO_PW="ropw"
LDAPI="ldapi://%2Frun%2Fslapd%2Fldapi"

PASS=0
FAIL=0
TOTAL=16

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

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
