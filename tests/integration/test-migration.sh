#!/bin/bash
# 2.4 → 2.6 migration test.
#
# Exercises the documented export/reimport path (see MIGRATION.md): stand up the
# old OpenLDAP 2.4 image (osixia/openldap:1.5.0), load realistic anonymized data
# + a ppolicy policy entry, slapcat the directory, strip the operational
# attributes that ldapadd rejects, then reimport into this image's 2.6 server via
# /bootstrap (data) + /overlays (the ppolicy overlay config, which is NOT carried
# in the data dump and is regenerated on the new server). Finally assert the data
# migrated intact, credentials still bind, and the ppolicy extension works.
#
# Usage: ./tests/integration/test-migration.sh [IMAGE_NAME:TAG]
# Requires: docker. Pulls osixia/openldap:1.5.0 (the 2.4 source).
set -eu

IMAGE="${1:-openldap:2.6.13}"
SRC_IMAGE="osixia/openldap:1.5.0"
FIX="$(cd "$(dirname "$0")" && pwd)/fixtures"
WORK="$(mktemp -d)"
SRC="openldap-migration-src"
DST="openldap-migration-dst"

BASE="dc=example,dc=test"
ADMIN_DN="cn=admin,${BASE}"
ADMIN_PW="admin"
USER_PW="Secret123"
LDAPI="ldapi://%2Frun%2Fslapd%2Fldapi"

# Operational / NO-USER-MODIFICATION attributes that a slapcat dump carries but
# ldapadd refuses — stripped before reimport. Note memberOf: the old osixia
# server runs the memberof overlay, so user entries carry computed memberOf
# values; they must be dropped (group membership lives in the group entries'
# uniqueMember/member, which the overlay recomputes if re-enabled).
OPATTRS='structuralObjectClass|entryUUID|entryCSN|creatorsName|createTimestamp|modifiersName|modifyTimestamp|entryDN|subschemaSubentry|hasSubordinates|contextCSN|memberOf|pwdChangedTime|pwdFailureTime|pwdGraceUseTime|pwdHistory|pwdAccountLockedTime|pwdReset'

# Opt-in coverage mode, used by tests/coverage.sh: COVERAGE_DIR is a host
# directory, mounted at /cov, where the coverage image writes its kcov data.
COVERAGE_DIR="${COVERAGE_DIR:-}"
COV_ARGS=()
[[ -n "$COVERAGE_DIR" ]] && COV_ARGS=(-v "$COVERAGE_DIR:/cov")

PASS=0
FAIL=0
TOTAL=8

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    # kcov writes its data when the traced process exits. Stop the target
    # first, a SIGKILL loses the data.
    if [[ -n "$COVERAGE_DIR" ]]; then
        docker stop "$DST" >/dev/null 2>&1 || true
    fi
    docker rm -f "$SRC" "$DST" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

ssearch() { docker exec "$SRC" ldapsearch "$@"; }   # against the 2.4 source
dsearch() { docker exec "$DST" ldapsearch "$@"; }   # against the 2.6 target
duwhoami() { docker exec "$DST" ldapwhoami -x -H "$LDAPI" -D "cn=$1,ou=people,$BASE" -w "$2" >/dev/null 2>&1; }

echo "=== 2.4 → 2.6 migration test (target: $IMAGE) ==="
echo ""

# ── 1. Stand up the 2.4 source and load data ────────────────────────────────
echo "[1/$TOTAL] Boot OpenLDAP 2.4 source ($SRC_IMAGE)"
docker rm -f "$SRC" >/dev/null 2>&1 || true
docker run -d --name "$SRC" \
    -e LDAP_ORGANISATION="Example Test Org" \
    -e LDAP_DOMAIN="example.test" \
    -e LDAP_ADMIN_PASSWORD="$ADMIN_PW" \
    "$SRC_IMAGE" >/dev/null 2>&1
src_ok=false
for _ in $(seq 1 90); do
    if docker exec "$SRC" ldapsearch -x -H ldap://localhost -b "" -s base >/dev/null 2>&1; then
        src_ok=true; break
    fi
    sleep 1
done
if $src_ok; then
    SRC_VER=$(docker exec "$SRC" slapd -VV 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    pass "source up (slapd $SRC_VER)"
else
    fail "2.4 source did not start"
    echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

echo "[2/$TOTAL] Load anonymized data into the 2.4 source"
load_ok=true
# OUs first (osixia only creates the base entry), then the shared fixtures.
docker exec -i "$SRC" ldapadd -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 <<EOF || load_ok=false
dn: ou=people,$BASE
objectClass: organizationalUnit
ou: people

dn: ou=groups,$BASE
objectClass: organizationalUnit
ou: groups
EOF
docker exec -i "$SRC" ldapadd -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 < "$FIX/bootstrap/21-people.ldif" || load_ok=false
docker exec -i "$SRC" ldapadd -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" >/dev/null 2>&1 < "$FIX/bootstrap/22-groups.ldif" || load_ok=false
SRC_PEOPLE=$(ssearch -LLL -x -H ldap://localhost -D "$ADMIN_DN" -w "$ADMIN_PW" -b "ou=people,$BASE" "(objectClass=inetOrgPerson)" dn 2>/dev/null | grep -c '^dn:' || true)
if $load_ok && [[ "${SRC_PEOPLE:-0}" -ge 11 ]]; then
    pass "loaded $SRC_PEOPLE users + groups into 2.4"
else
    fail "failed to load source data (people=$SRC_PEOPLE)"
fi

# ── 2. Export from 2.4 and sanitise for reimport ────────────────────────────
echo "[3/$TOTAL] slapcat the 2.4 directory and strip operational attributes"
docker exec "$SRC" slapcat -o ldif-wrap=no -b "$BASE" 2>/dev/null > "$WORK/dump.ldif" || true
grep -ivE "^($OPATTRS):" "$WORK/dump.ldif" > "$WORK/data.ldif"
if [[ -s "$WORK/data.ldif" ]] && grep -q "^dn: cn=asmith,ou=people,$BASE" "$WORK/data.ldif" \
        && ! grep -qiE "^($OPATTRS):" "$WORK/data.ldif"; then
    pass "exported $(grep -c '^dn:' "$WORK/data.ldif") entries, operational attrs stripped"
else
    fail "export/sanitise produced an unusable dump"
    echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

# ── 3. Reimport into the 2.6 target ─────────────────────────────────────────
echo "[4/$TOTAL] Boot the 2.6 target and reimport (data via /bootstrap, ppolicy via /overlays)"
docker rm -f "$DST" >/dev/null 2>&1 || true
docker run -d --name "$DST" "${COV_ARGS[@]+"${COV_ARGS[@]}"}" \
    -e LDAP_ORGANISATION="Example Test Org" \
    -e LDAP_DOMAIN="example.test" \
    -e LDAP_ADMIN_PASSWORD="$ADMIN_PW" \
    -e LDAP_CONFIG_PASSWORD="configpw" \
    -v "$WORK/data.ldif:/bootstrap/00-data.ldif:ro" \
    -v "$FIX/bootstrap/20-policies.ldif:/bootstrap/20-policies.ldif:ro" \
    -v "$FIX/overlays/10-ppolicy.ldif:/overlays/10-ppolicy.ldif:ro" \
    "$IMAGE" >/dev/null 2>&1
dst_ok=false
for _ in $(seq 1 60); do
    if docker exec "$DST" ldapsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "$BASE" -s base o >/dev/null 2>&1; then
        dst_ok=true; break
    fi
    sleep 1
done
if $dst_ok; then
    pass "2.6 target up with migrated data"
else
    fail "2.6 target did not start"
    docker logs "$DST" 2>&1 | tail -20 | sed 's/^/    /'
    echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

# ── 4. Verify the migration ─────────────────────────────────────────────────
echo "[5/$TOTAL] All users and group membership migrated intact"
DST_PEOPLE=$(dsearch -LLL -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "ou=people,$BASE" "(objectClass=inetOrgPerson)" dn 2>/dev/null | grep -c '^dn:' || true)
NMEMB=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=everyone,ou=groups,$BASE" uniqueMember 2>/dev/null | grep -c '^uniqueMember:' || true)
if [[ "$DST_PEOPLE" = "$SRC_PEOPLE" ]] && [[ "${NMEMB:-0}" -ge 11 ]]; then
    pass "people ${SRC_PEOPLE} -> ${DST_PEOPLE}, group membership preserved ($NMEMB)"
else
    fail "data mismatch (src=$SRC_PEOPLE dst=$DST_PEOPLE members=$NMEMB)"
fi

echo "[6/$TOTAL] Attribute fidelity, incl. UTF-8 (Zoë Müller)"
UNI=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=zmuller,ou=people,$BASE" displayName 2>/dev/null | sed -n 's/^displayName:: //p' | base64 -d 2>/dev/null)
MAIL=$(dsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "$ADMIN_DN" -w "$ADMIN_PW" -b "cn=asmith,ou=people,$BASE" mail 2>/dev/null | sed -n 's/^mail: //p')
if [[ "$UNI" = "Zoë Müller" ]] && [[ "$MAIL" = "asmith@example.test" ]]; then
    pass "attributes and UTF-8 values preserved"
else
    fail "attribute fidelity lost (unicode='$UNI' mail='$MAIL')"
fi

echo "[7/$TOTAL] Credentials still bind after migration"
if duwhoami asmith "$USER_PW" && duwhoami jkent "$USER_PW"; then
    pass "migrated passwords still authenticate"
else
    fail "post-migration bind failed"
fi

echo "[8/$TOTAL] ppolicy extension active on the migrated directory (lockout enforced)"
PP=$(docker exec "$DST" ldapsearch -LLL -o ldif-wrap=no -x -H "$LDAPI" -D "cn=admin,cn=config" -w "configpw" -b "cn=config" "(olcOverlay=ppolicy)" dn 2>/dev/null)
for _ in 1 2 3; do duwhoami jkent wrong-pw || true; done
if echo "$PP" | grep -qi "olcOverlay=.*ppolicy" && ! duwhoami jkent "$USER_PW"; then
    pass "ppolicy overlay active and locks accounts after migration"
else
    fail "ppolicy not enforced post-migration"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -gt 0 ]] && exit 1 || exit 0
