#!/bin/sh
# Hides pwdHistory from every client except the rootdn.
#
# ppolicy keeps the hashes of the previous passwords in pwdHistory. The default
# rules protect userPassword, but "to * by <readonly> read" also exposed
# pwdHistory. ppolicy itself checks the history with internal operations, so it
# keeps working without read access for anyone.
#
# New servers get the rule on first boot. On a running server, run once:
#   docker exec <container> ldap-hide-pwdhistory
# It adds the rule in front of the others, and does nothing when it exists.
set -e

LDAPI_URL="${LDAPI_URL:-ldapi://%2Frun%2Fslapd%2Fldapi}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_CONFIG_PASSWORD="${LDAP_CONFIG_PASSWORD:-$LDAP_ADMIN_PASSWORD}"
RULE='to attrs=pwdHistory by * none'

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ldap-hide-pwdhistory] $1"; }
die() { log "ERROR: $1"; exit 1; }

cfg_search() {
    ldapsearch -o ldif-wrap=no -LLL -x -H "$LDAPI_URL" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" "$@"
}

# The data database is the one with an olcSuffix.
DB_DN=$(cfg_search -b cn=config "(olcSuffix=*)" dn | sed -n 's/^dn: //p' | head -1) \
    || die "cannot read cn=config (is slapd up and the config password correct?)"
[ -n "$DB_DN" ] || die "no database with an olcSuffix in cn=config"

current=$(cfg_search -b "$DB_DN" -s base olcAccess) || die "cannot read the olcAccess rules of $DB_DN"
# slapd stores a rule from slapd.conf with two spaces before each "by": compare
# with the spaces squeezed.
if printf '%s\n' "$current" | sed -n 's/^olcAccess: {[0-9]*}//p' | tr -s ' ' | grep -qxF "$RULE"; then
    log "pwdHistory is already hidden on $DB_DN"
    exit 0
fi

log "Hiding pwdHistory on $DB_DN"
ldapmodify -x -H "$LDAPI_URL" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" >/dev/null <<LDIF
dn: $DB_DN
changetype: modify
add: olcAccess
olcAccess: {0}$RULE
LDIF
log "Done"
