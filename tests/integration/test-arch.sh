#!/bin/bash
# Cross-architecture runtime smoke test.
#
# CI builds and tests only the native amd64 image, but we publish linux/arm64
# too. This builds the image for a target platform (default linux/arm64) and
# boots it under emulation, verifying slapd actually runs and serves there.
# Requires buildx + QEMU/binfmt for the non-native platform (the CI Build and
# Test job already sets these up; Docker Desktop provides them locally).
#
# Usage: ./tests/integration/test-arch.sh [platform] [tag]
set -eu

PLATFORM="${1:-linux/arm64}"
TAG="${2:-openldap:archtest}"
CONTEXT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER="openldap-arch-test"
LDAPI="ldapi://%2Frun%2Fslapd%2Fldapi"
BASE="dc=example,dc=test"
ADMIN_DN="cn=admin,${BASE}"
case "$PLATFORM" in
    *arm64*|*aarch64*) WANT_ARCH=aarch64 ;;
    *amd64*|*x86_64*)  WANT_ARCH=x86_64 ;;
    *)                 WANT_ARCH="" ;;
esac

PASS=0
FAIL=0
TOTAL=4

cleanup() {
    echo ""
    echo "--- Cleanup ---"
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

echo "=== $PLATFORM runtime smoke (image $TAG) ==="
echo ""

echo "[1/$TOTAL] Build the image for $PLATFORM"
if docker buildx build --platform "$PLATFORM" -t "$TAG" --load "$CONTEXT" >/dev/null 2>&1; then
    pass "image built for $PLATFORM"
else
    fail "buildx build failed for $PLATFORM"
    echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

echo "[2/$TOTAL] Binaries are the target architecture and slapd is 2.6.x"
ARCH=$(docker run --rm --platform "$PLATFORM" --entrypoint "" "$TAG" uname -m 2>/dev/null || true)
VER=$(docker run --rm --platform "$PLATFORM" --entrypoint "" "$TAG" sh -c 'slapd -VV 2>&1' 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if { [ -z "$WANT_ARCH" ] || [ "$ARCH" = "$WANT_ARCH" ]; } && echo "$VER" | grep -q '^2\.6\.'; then
    pass "arch=$ARCH, slapd $VER"
else
    fail "wrong arch/version (arch=$ARCH want=$WANT_ARCH ver=$VER)"
fi

echo "[3/$TOTAL] Boots and serves under emulation"
docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
docker run -d --name "$CONTAINER" --platform "$PLATFORM" \
    -e LDAP_DOMAIN=example.test -e LDAP_ADMIN_PASSWORD=admin "$TAG" >/dev/null 2>&1
ready=false
for _ in $(seq 1 120); do
    if docker exec "$CONTAINER" ldapsearch -x -H "$LDAPI" -D "$ADMIN_DN" -w admin -b "$BASE" -s base o >/dev/null 2>&1; then
        ready=true; break
    fi
    sleep 1
done
if $ready; then
    pass "slapd answered an authenticated search under emulation"
else
    fail "slapd did not become ready under emulation"
    docker logs "$CONTAINER" 2>&1 | tail -15 | sed 's/^/    /'
    echo ""; echo "=== Results: $PASS passed, $FAIL failed ==="; exit 1
fi

echo "[4/$TOTAL] CRUD works under emulation"
docker exec -i "$CONTAINER" ldapadd -x -H "$LDAPI" -D "$ADMIN_DN" -w admin >/dev/null 2>&1 <<EOF || true
dn: cn=archuser,ou=people,$BASE
objectClass: inetOrgPerson
cn: archuser
sn: x
mail: archuser@example.test
EOF
if docker exec "$CONTAINER" ldapsearch -LLL -x -H "$LDAPI" -D "$ADMIN_DN" -w admin -b "cn=archuser,ou=people,$BASE" mail 2>/dev/null | grep -qi "archuser@example.test"; then
    pass "added and read back an entry on $PLATFORM"
else
    fail "CRUD failed under emulation"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
