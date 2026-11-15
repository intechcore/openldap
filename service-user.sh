#!/bin/sh
# Creates or updates the scoped service account and its ACL rules, or removes them.
#
# The account reads the tree like the readonly account and writes only what the
# LDAP_SERVICE_USER_* variables grant. Its rules go in front of the existing
# olcAccess rules of the data database. Every rule ends with "by * break", so
# all other clients fall through to the rules below, unchanged.
#
# The entrypoint runs it on first boot. On a running server, set the variables
# and run it again:
#   docker exec <container> ldap-service-user
#
# LDAP_SERVICE_USER=true creates or updates the account, its password and its
# rules. Any other value removes them. Rules are found by the account DN, so a
# rerun replaces them and leaves every other rule as it is.
set -e

LDAPI_URL="${LDAPI_URL:-ldapi://%2Frun%2Fslapd%2Fldapi}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_CONFIG_PASSWORD="${LDAP_CONFIG_PASSWORD:-$LDAP_ADMIN_PASSWORD}"
LDAP_SERVICE_USER="${LDAP_SERVICE_USER:-false}"
LDAP_SERVICE_USER_USERNAME="${LDAP_SERVICE_USER_USERNAME:-service}"
LDAP_SERVICE_USER_PASSWORD="${LDAP_SERVICE_USER_PASSWORD:-service}"
LDAP_SERVICE_USER_SUBTREE="${LDAP_SERVICE_USER_SUBTREE:-ou=people}"
LDAP_SERVICE_USER_MANAGE_ATTRS="${LDAP_SERVICE_USER_MANAGE_ATTRS:-}"
LDAP_SERVICE_USER_WRITE_ATTRS="${LDAP_SERVICE_USER_WRITE_ATTRS:-}"
LDAP_SERVICE_USER_GROUPS="${LDAP_SERVICE_USER_GROUPS:-}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [ldap-service-user] $1"; }
die() { log "ERROR: $1"; exit 1; }

cfg_search() {
    ldapsearch -o ldif-wrap=no -LLL -x -H "$LDAPI_URL" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" "$@"
}

# "a b" -> "a,b". Every name must be a plain attribute name.
attr_list() {
    out=""
    for a in $1; do
        printf '%s' "$a" | grep -qE '^[A-Za-z][A-Za-z0-9-]*$' || die "invalid attribute name '$a'"
        out="${out:+$out,}$a"
    done
    printf '%s' "$out"
}

# The data database is the one with an olcSuffix.
db_entry=$(cfg_search -b cn=config "(olcSuffix=*)" dn olcSuffix) \
    || die "cannot read cn=config (is slapd up and the config password correct?)"
DB_DN=$(printf '%s\n' "$db_entry" | sed -n 's/^dn: //p' | head -1)
BASE=$(printf '%s\n' "$db_entry" | sed -n 's/^olcSuffix: //p' | head -1)
[ -n "$DB_DN" ] && [ -n "$BASE" ] || die "no database with an olcSuffix in cn=config"

printf '%s' "$LDAP_SERVICE_USER_USERNAME" | grep -qE '^[A-Za-z0-9._-]+$' \
    || die "invalid LDAP_SERVICE_USER_USERNAME '$LDAP_SERVICE_USER_USERNAME'"
SVC_DN="cn=$LDAP_SERVICE_USER_USERNAME,$BASE"
WHO="dn.exact=\"$SVC_DN\""

# Current rules without the {n} index and without the rules of this account.
current=$(cfg_search -b "$DB_DN" -s base olcAccess) || die "cannot read the olcAccess rules of $DB_DN"
printf '%s\n' "$current" | grep -q '^olcAccess::' && die "a base64 olcAccess value is not supported, edit the rules by hand"
others=$(printf '%s\n' "$current" | sed -n 's/^olcAccess: {[0-9]*}//p' | grep -vF "$WHO" || true)

rules=""
add_rule() { rules="$rules$1
"; }

if [ "$LDAP_SERVICE_USER" = "true" ]; then
    printf '%s' "$LDAP_SERVICE_USER_SUBTREE" | grep -qE '^[A-Za-z]+=[^,"]+(,[A-Za-z]+=[^,"]+)*$' \
        || die "invalid LDAP_SERVICE_USER_SUBTREE '$LDAP_SERVICE_USER_SUBTREE'"
    SCOPE="dn.subtree=\"$LDAP_SERVICE_USER_SUBTREE,$BASE\""
    manage=$(attr_list "$LDAP_SERVICE_USER_MANAGE_ATTRS")
    write=$(attr_list "$LDAP_SERVICE_USER_WRITE_ATTRS")

    for g in $LDAP_SERVICE_USER_GROUPS; do
        printf '%s' "$g" | grep -qE '^[A-Za-z]+=[^,"]+(,[A-Za-z]+=[^,"]+)*$' || die "invalid group '$g'"
        add_rule "to dn.exact=\"$g,$BASE\" attrs=uniqueMember by $WHO write by * break"
    done
    # The levels manage and write include read. userPassword gets the bare
    # privileges instead, so the account sets passwords but never reads a hash.
    # m keeps a password set by the account an administrative reset for ppolicy.
    case ",$manage," in
        *,userPassword,*)
            add_rule "to $SCOPE attrs=userPassword by $WHO =mw by * break"
            manage=$(printf '%s' ",$manage," | sed 's/,userPassword,/,/; s/^,//; s/,$//') ;;
    esac
    case ",$write," in
        *,userPassword,*)
            add_rule "to $SCOPE attrs=userPassword by $WHO =w by * break"
            write=$(printf '%s' ",$write," | sed 's/,userPassword,/,/; s/^,//; s/,$//') ;;
    esac
    [ -n "$manage" ] && add_rule "to $SCOPE attrs=$manage by $WHO manage by * break"
    [ -n "$write" ] && add_rule "to $SCOPE attrs=$write by $WHO write by * break"
    add_rule "to attrs=userPassword,shadowLastChange by $WHO none by * break"
    add_rule "to * by $WHO read by * break"
fi

values=$(printf '%s\n' "$rules$others" | while IFS= read -r r; do
    if [ -n "$r" ]; then printf 'olcAccess: %s\n' "$r"; fi
done)
# An empty olcAccess means "everyone reads everything": never write that.
[ -n "$values" ] || die "no access rules would remain on $DB_DN"
ldif="dn: $DB_DN
replace: olcAccess
$values"

account_exists() {
    ldapsearch -LLL -x -H "$LDAPI_URL" -D "cn=admin,$BASE" -w "$LDAP_ADMIN_PASSWORD" \
        -b "$SVC_DN" -s base dn >/dev/null 2>&1
}

if [ "$LDAP_SERVICE_USER" = "true" ]; then
    hash="$(slappasswd -s "$LDAP_SERVICE_USER_PASSWORD")"
    if account_exists; then
        log "Updating the password of $SVC_DN"
        ldapmodify -x -H "$LDAPI_URL" -D "cn=admin,$BASE" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: $SVC_DN
changetype: modify
replace: userPassword
userPassword: $hash
EOF
    else
        log "Creating $SVC_DN"
        ldapadd -x -H "$LDAPI_URL" -D "cn=admin,$BASE" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: $SVC_DN
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: $LDAP_SERVICE_USER_USERNAME
description: Service account with scoped write access
userPassword: $hash
EOF
    fi
fi

log "Writing $(printf '%s' "$rules" | grep -c . || true) service rules in front of $(printf '%s\n' "$others" | grep -c . || true) other rules"
printf '%s\n' "$ldif" | ldapmodify -x -H "$LDAPI_URL" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" >/dev/null

if [ "$LDAP_SERVICE_USER" != "true" ] && account_exists; then
    log "Removing $SVC_DN"
    ldapdelete -x -H "$LDAPI_URL" -D "cn=admin,$BASE" -w "$LDAP_ADMIN_PASSWORD" "$SVC_DN"
fi
log "Done"
