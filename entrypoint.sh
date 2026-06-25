#!/bin/sh
# Hybrid OpenLDAP bootstrap entrypoint.
#
# Drop-in spirit of osixia/openldap: the same env vars drive the initial setup
# (domain, organisation, admin/config passwords, readonly user, TLS), while
# anything beyond that is expressed as plain LDIF mounted at /schema and
# /bootstrap. First boot builds cn=config from scratch and loads the data;
# every subsequent boot just starts slapd against the existing volumes.
set -e

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [Entrypoint] $1"; }

# ─── Env contract (compatible subset of osixia/openldap) ────────────────────
LDAP_ORGANISATION="${LDAP_ORGANISATION:-Example Inc.}"
LDAP_DOMAIN="${LDAP_DOMAIN:-example.org}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_CONFIG_PASSWORD="${LDAP_CONFIG_PASSWORD:-$LDAP_ADMIN_PASSWORD}"
LDAP_READONLY_USER="${LDAP_READONLY_USER:-false}"
LDAP_READONLY_USER_USERNAME="${LDAP_READONLY_USER_USERNAME:-readonly}"
LDAP_READONLY_USER_PASSWORD="${LDAP_READONLY_USER_PASSWORD:-readonly}"
# A second read-only account that may ALSO read userPassword hashes — for
# services that verify passwords by reading the hash locally (e.g. some
# Dovecot/Postfix setups) rather than via an LDAP bind. Off by default; the
# plain readonly account above never sees password hashes.
LDAP_READONLY_PW_USER="${LDAP_READONLY_PW_USER:-false}"
LDAP_READONLY_PW_USERNAME="${LDAP_READONLY_PW_USERNAME:-readpw}"
LDAP_READONLY_PW_PASSWORD="${LDAP_READONLY_PW_PASSWORD:-readpw}"
# Overlays enabled by default for osixia parity. memberof maintains the reverse
# memberOf attribute; refint keeps DN references consistent on delete/rename.
# Both are configured exactly as osixia did (groupOfUniqueNames / uniqueMember).
LDAP_MEMBEROF="${LDAP_MEMBEROF:-true}"
LDAP_REFINT="${LDAP_REFINT:-true}"
# Opt-in: the lastbind overlay records the time of each successful bind in the
# operational attribute authTimestamp (a "last login" timestamp). Off by default
# — it writes on every successful bind.
LDAP_LASTBIND="${LDAP_LASTBIND:-false}"
# Opt-in: the unique overlay enforces value uniqueness for the listed attributes
# (e.g. no two entries may share a mail or uid), rejecting duplicate writes.
LDAP_UNIQUE="${LDAP_UNIQUE:-false}"
LDAP_UNIQUE_ATTRIBUTES="${LDAP_UNIQUE_ATTRIBUTES:-mail uid}"
# Password hashing scheme for new/changed passwords (olcPasswordHash). The
# default {SSHA} is the compiled-in default; {ARGON2}, {PBKDF2-SHA512},
# {SSHA512}, … load the matching module automatically. Existing hashes keep
# working, so switching is a lazy migration.
LDAP_PASSWORD_HASH="${LDAP_PASSWORD_HASH:-}"
[ -z "$LDAP_PASSWORD_HASH" ] && LDAP_PASSWORD_HASH='{SSHA}'
# Load the rfc2307bis schema instead of the standard nis schema (osixia
# LDAP_RFC2307BIS_SCHEMA equivalent). rfc2307bis makes posixAccount/posixGroup
# AUXILIARY, so one entry can be both an inetOrgPerson and a POSIX account/group
# — for unified web + Linux/SSSD directories. They share OIDs, so it is a swap.
LDAP_RFC2307BIS="${LDAP_RFC2307BIS:-false}"
LDAP_TLS="${LDAP_TLS:-false}"
LDAP_TLS_CRT_FILENAME="${LDAP_TLS_CRT_FILENAME:-ldap.crt}"
LDAP_TLS_KEY_FILENAME="${LDAP_TLS_KEY_FILENAME:-ldap.key}"
LDAP_TLS_CA_CRT_FILENAME="${LDAP_TLS_CA_CRT_FILENAME:-ca.crt}"
LDAP_TLS_DH_PARAM_FILENAME="${LDAP_TLS_DH_PARAM_FILENAME:-dhparam.pem}"
LDAP_TLS_VERIFY_CLIENT="${LDAP_TLS_VERIFY_CLIENT:-demand}"
# TLS hardening (osixia parity): minimum protocol TLS 1.2 (3.3) by default, and
# an optional cipher suite (OpenSSL syntax — left to the OpenSSL default when
# unset). 3.1=TLS1.0, 3.2=TLS1.1, 3.3=TLS1.2, 3.4=TLS1.3.
LDAP_TLS_PROTOCOL_MIN="${LDAP_TLS_PROTOCOL_MIN:-3.3}"
LDAP_TLS_CIPHER_SUITE="${LDAP_TLS_CIPHER_SUITE:-}"
# Opt-in: watch the TLS certificate for changes (e.g. an external Let's Encrypt
# renewal rewriting the mounted cert) and hot-reload slapd's TLS context without
# a restart. Off by default to avoid a background process.
LDAP_TLS_WATCH="${LDAP_TLS_WATCH:-false}"
LDAP_TLS_WATCH_INTERVAL="${LDAP_TLS_WATCH_INTERVAL:-3600}"
LDAP_LOG_LEVEL="${LDAP_LOG_LEVEL:-256}"

CERTS_DIR="${CERTS_DIR:-/container/certs}"
SCHEMA_DIR="${SCHEMA_DIR:-/schema}"
OVERLAYS_DIR="${OVERLAYS_DIR:-/overlays}"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-/bootstrap}"
CONFIG_DIR=/etc/ldap/slapd.d
DATA_DIR=/var/lib/ldap
# Stock schema + loadable backend/overlay modules shipped by the Symas packages.
SCHEMA_BASE="${SCHEMA_BASE:-/opt/symas/etc/openldap/schema}"
MODULE_PATH="${MODULE_PATH:-/opt/symas/lib/openldap}"

# Local ldapi:// socket with an explicit path so server and client always agree
# regardless of the compiled-in default.
LDAPI_URL="ldapi://%2Frun%2Fslapd%2Fldapi"

# Derive the base DN from the domain: intechcore.online -> dc=intechcore,dc=online
LDAP_BASE_DN="${LDAP_BASE_DN:-dc=$(echo "$LDAP_DOMAIN" | sed 's/\./,dc=/g')}"

# ─── Locale & timezone ──────────────────────────────────────────────────────
# TZ sets the container's timezone (affects slapd/entrypoint log timestamps).
# LANG selects the locale; C.UTF-8 is the always-available UTF-8 default, other
# locales are generated on first boot. Runs as root, before slapd starts.
setup_locale_tz() {
    if [ -n "${TZ:-}" ]; then
        if [ -f "/usr/share/zoneinfo/$TZ" ]; then
            ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
            echo "$TZ" > /etc/timezone
            log "Timezone set to $TZ"
        else
            log "WARNING: unknown timezone '$TZ' (no /usr/share/zoneinfo/$TZ) — ignoring"
        fi
    fi

    case "${LANG:-}" in
        ""|C|C.UTF-8|C.utf8|POSIX) ;;  # always available, nothing to generate
        *)
            want="$(echo "$LANG" | sed 's/\.UTF-8$/.utf8/I')"
            if ! locale -a 2>/dev/null | grep -qix "$want"; then
                log "Generating locale $LANG"
                echo "$LANG ${LANG##*.}" >> /etc/locale.gen
                locale-gen >/dev/null 2>&1 || log "  (locale-gen failed for $LANG)"
            fi
            ;;
    esac
}

# ─── TLS material ───────────────────────────────────────────────────────────
# Prefer mounted certs in $CERTS_DIR; fall back to self-signed (handy for
# dev/CI). For persistent TLS in production, always mount real certificates.
setup_tls() {
    [ "$LDAP_TLS" = "true" ] || return 0

    TLS_CRT="$CERTS_DIR/$LDAP_TLS_CRT_FILENAME"
    TLS_KEY="$CERTS_DIR/$LDAP_TLS_KEY_FILENAME"
    TLS_CA="$CERTS_DIR/$LDAP_TLS_CA_CRT_FILENAME"
    TLS_DH="$CERTS_DIR/$LDAP_TLS_DH_PARAM_FILENAME"

    if [ ! -f "$TLS_CRT" ] || [ ! -f "$TLS_KEY" ]; then
        log "TLS enabled but no certificate found in $CERTS_DIR — generating self-signed"
        GEN=/etc/ldap/certs
        mkdir -p "$GEN"
        CN="$(hostname -f 2>/dev/null || echo ldap)"
        # rsa:2048 and no DH params: fast to generate (matters on slow/low-entropy
        # CI hosts) and fine for a throwaway dev/CI cert — modern TLS negotiates
        # ECDHE, so explicit DH params are not needed. Mount real certs for prod.
        openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -subj "/CN=$CN" \
            -keyout "$GEN/ldap.key" -out "$GEN/ldap.crt" 2>/dev/null
        cp "$GEN/ldap.crt" "$GEN/ca.crt"
        TLS_CRT="$GEN/ldap.crt"; TLS_KEY="$GEN/ldap.key"
        TLS_CA="$GEN/ca.crt";   TLS_DH=""
        chown -R openldap:openldap "$GEN"
    else
        log "Using mounted TLS certificates from $CERTS_DIR"
    fi
}

# ─── First-run config generation ────────────────────────────────────────────
# A slapd.conf is the most compact way to express the whole tree; slaptest then
# converts it into the modern cn=config (slapd.d) layout.
bootstrap_config() {
    log "Bootstrapping cn=config for base DN '$LDAP_BASE_DN'"
    admin_hash="$(slappasswd -s "$LDAP_ADMIN_PASSWORD")"
    config_hash="$(slappasswd -s "$LDAP_CONFIG_PASSWORD")"

    # Extra ACL clause granting the optional password-reading readonly account
    # read access (injected into both the userPassword and the general ACL).
    pw_read=""
    if [ "$LDAP_READONLY_PW_USER" = "true" ]; then
        pw_read="
  by dn.exact=\"cn=$LDAP_READONLY_PW_USERNAME,$LDAP_BASE_DN\" read"
    fi

    # rfc2307bis is a drop-in replacement for nis (same OIDs), not an addition.
    nis_schema=nis
    [ "$LDAP_RFC2307BIS" = "true" ] && nis_schema=rfc2307bis

    conf="$(mktemp)"
    {
        for s in core cosine inetorgperson "$nis_schema"; do
            echo "include $SCHEMA_BASE/$s.schema"
        done
        for f in "$SCHEMA_DIR"/*.schema; do
            [ -f "$f" ] && echo "include $f"
        done
        echo "pidfile /run/slapd/slapd.pid"
        echo "argsfile /run/slapd/slapd.args"
        # In the Symas packages every backend/overlay is a loadable module, so
        # the mdb backend must be loaded explicitly before its database stanza.
        echo "modulepath $MODULE_PATH"
        echo "moduleload back_mdb"
        # Load the ppolicy module so its schema (pwdPolicy, pwd* attrs) is
        # available by default (osixia parity) — there is no standalone
        # ppolicy.schema file; the overlay is only activated when configured.
        echo "moduleload ppolicy"
        # Password hash for new/changed passwords. Built-in schemes ({SSHA},
        # {SHA}, {CRYPT}, …) need no module; load the right one otherwise.
        # slaptest places `password-hash` on the frontend database — the correct
        # location (setting olcPasswordHash on the global cn=config breaks
        # startup when the scheme comes from a loadable module).
        case "$LDAP_PASSWORD_HASH" in
            *ARGON2*) echo "moduleload argon2" ;;
            *PBKDF2*) echo "moduleload pw-pbkdf2" ;;
            *SHA256*|*SHA384*|*SHA512*) echo "moduleload pw-sha2" ;;
            *APR1*) echo "moduleload pw-apr1" ;;
        esac
        echo "password-hash $LDAP_PASSWORD_HASH"
        if [ "$LDAP_TLS" = "true" ]; then
            echo "TLSCACertificateFile $TLS_CA"
            echo "TLSCertificateFile $TLS_CRT"
            echo "TLSCertificateKeyFile $TLS_KEY"
            [ -f "$TLS_DH" ] && echo "TLSDHParamFile $TLS_DH"
            echo "TLSVerifyClient $LDAP_TLS_VERIFY_CLIENT"
            [ -n "$LDAP_TLS_PROTOCOL_MIN" ] && echo "TLSProtocolMin $LDAP_TLS_PROTOCOL_MIN"
            [ -n "$LDAP_TLS_CIPHER_SUITE" ] && echo "TLSCipherSuite $LDAP_TLS_CIPHER_SUITE"
        fi
        cat <<EOF
loglevel $LDAP_LOG_LEVEL

database config
rootdn "cn=admin,cn=config"
rootpw $config_hash
access to *
  by dn.exact="gidNumber=0+uidNumber=0,cn=peercred,cn=external,cn=auth" manage
  by * break

# mdb is defined before monitor so it lands at olcDatabase={1}mdb,cn=config —
# the osixia-compatible index that overlay LDIFs (e.g. ppolicy) reference.
database mdb
suffix "$LDAP_BASE_DN"
rootdn "cn=admin,$LDAP_BASE_DN"
rootpw $admin_hash
directory $DATA_DIR
maxsize 1073741824
index objectClass eq
index cn,sn,uid,mail eq,sub
index uidNumber,gidNumber,memberUid eq
index member eq

access to attrs=userPassword,shadowLastChange
  by self write
  by anonymous auth$pw_read
  by * none
access to *
  by self read
  by dn.exact="cn=$LDAP_READONLY_USER_USERNAME,$LDAP_BASE_DN" read$pw_read
  by * none

database monitor
EOF
    } > "$conf"

    rm -rf "${CONFIG_DIR:?}/"*
    mkdir -p "$CONFIG_DIR" "$DATA_DIR" /run/slapd

    # Validate config/schema syntax first (-u is a dry run: it checks but writes
    # nothing).
    if ! out="$(slaptest -u -f "$conf" -F "$CONFIG_DIR" 2>&1)"; then
        log "ERROR: generated slapd config is invalid:"
        echo "$out" | sed 's/^/    /'
        log "--- generated slapd.conf ---"
        sed 's/^/    /' "$conf"
        exit 1
    fi

    # Now actually write the cn=config tree. Without -u, slaptest also runs the
    # backend startup test and exits non-zero because the mdb database does not
    # exist yet ("Restore from backup!") — that is expected on a cold volume and
    # harmless: the conversion is written before that check runs, and the real
    # slapd creates the database on first start. So ignore the exit code and
    # instead confirm the config was produced.
    slaptest -f "$conf" -F "$CONFIG_DIR" >/dev/null 2>&1 || true
    if [ ! -f "$CONFIG_DIR/cn=config.ldif" ] || [ -z "$(ls -A "$CONFIG_DIR/cn=config" 2>/dev/null)" ]; then
        log "ERROR: slaptest did not produce a cn=config tree"
        exit 1
    fi
    rm -f "$conf"
    chown -R openldap:openldap "$CONFIG_DIR" "$DATA_DIR" /run/slapd
}

# ─── First-run data load ────────────────────────────────────────────────────
# Brings slapd up on the local socket only, loads schema LDIFs, the base tree,
# the readonly account and any user bootstrap LDIF, then shuts it back down so
# the real foreground slapd can take over with the full listener set.
bootstrap_data() {
    # The temporary slapd listens on a PRIVATE socket so nothing answers the
    # public ldapi:// (used by the healthcheck and clients) until the real
    # foreground slapd is up — this avoids a readiness race during the handover.
    boot_ldapi="ldapi://%2Frun%2Fslapd%2Fldapi-bootstrap"

    log "Starting temporary slapd for data load"
    slapd -h "$boot_ldapi" -u openldap -g openldap -F "$CONFIG_DIR"

    ok=false
    for _ in $(seq 1 30); do
        if ldapsearch -x -H "$boot_ldapi" -b "" -s base >/dev/null 2>&1; then
            ok=true; break
        fi
        sleep 0.3
    done
    $ok || { log "ERROR: temporary slapd did not come up"; exit 1; }

    # Custom schema in cn=config LDIF form (objectClass: olcSchemaConfig),
    # written under the config rootdn.
    for f in "$SCHEMA_DIR"/*.ldif; do
        [ -f "$f" ] || continue
        log "Loading schema LDIF $f"
        ldapadd -x -H "$boot_ldapi" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" -f "$f" >/dev/null 2>&1 \
            || log "  (schema $f already present or partially applied)"
    done

    # Built-in overlays (osixia parity), loaded before the data so memberOf is
    # computed as group entries land. memberof must precede refint so they take
    # the same {0}/{1} indices osixia used.
    if [ "$LDAP_MEMBEROF" = "true" ]; then
        log "Enabling memberof overlay"
        ldapmodify -c -x -H "$boot_ldapi" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" >/dev/null 2>&1 <<EOF || log "  (memberof already configured)"
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: memberof

dn: olcOverlay=memberof,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcMemberOf
olcOverlay: memberof
olcMemberOfDangling: ignore
olcMemberOfRefInt: TRUE
olcMemberOfGroupOC: groupOfUniqueNames
olcMemberOfMemberAD: uniqueMember
olcMemberOfMemberOfAD: memberOf

dn: olcDatabase={1}mdb,cn=config
changetype: modify
add: olcDbIndex
olcDbIndex: memberOf eq
EOF
    fi
    if [ "$LDAP_REFINT" = "true" ]; then
        log "Enabling refint overlay"
        ldapmodify -c -x -H "$boot_ldapi" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" >/dev/null 2>&1 <<EOF || log "  (refint already configured)"
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: refint

dn: olcOverlay=refint,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcRefintConfig
olcOverlay: refint
olcRefintAttribute: owner
olcRefintAttribute: manager
olcRefintAttribute: uniqueMember
olcRefintAttribute: member
olcRefintAttribute: memberOf
EOF
    fi
    if [ "$LDAP_LASTBIND" = "true" ]; then
        log "Enabling lastbind overlay (records authTimestamp on each bind)"
        ldapmodify -c -x -H "$boot_ldapi" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" >/dev/null 2>&1 <<EOF || log "  (lastbind already configured)"
dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: lastbind

dn: olcOverlay=lastbind,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcLastBindConfig
olcOverlay: lastbind
EOF
    fi
    if [ "$LDAP_UNIQUE" = "true" ] && [ -n "$LDAP_UNIQUE_ATTRIBUTES" ]; then
        log "Enabling unique overlay (attributes: $LDAP_UNIQUE_ATTRIBUTES)"
        uniq_ldif="dn: cn=module{0},cn=config
changetype: modify
add: olcModuleLoad
olcModuleLoad: unique

dn: olcOverlay=unique,olcDatabase={1}mdb,cn=config
changetype: add
objectClass: olcOverlayConfig
objectClass: olcUniqueConfig
olcOverlay: unique"
        for _attr in $LDAP_UNIQUE_ATTRIBUTES; do
            uniq_ldif="$uniq_ldif
olcUniqueURI: ldap:///?${_attr}?sub?"
        done
        printf '%s\n' "$uniq_ldif" | ldapmodify -c -x -H "$boot_ldapi" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" >/dev/null 2>&1 \
            || log "  (unique already configured)"
    fi

    # Overlay / cn=config customisation (e.g. ppolicy, memberof, refint). These
    # are cn=config "changetype:" LDIFs applied under the config rootdn before
    # the data load, so the overlays are active when the data lands. The data
    # backend is olcDatabase={1}mdb,cn=config (osixia-compatible index).
    for f in "$OVERLAYS_DIR"/*.ldif; do
        [ -f "$f" ] || continue
        log "Applying overlay/config LDIF $f"
        ldapmodify -c -x -H "$boot_ldapi" -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" -f "$f" >/dev/null 2>&1 \
            || log "  (some directives in $f were already applied)"
    done

    # Base tree + standard OUs.
    if ! ldapsearch -x -H "$boot_ldapi" -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_ADMIN_PASSWORD" -b "$LDAP_BASE_DN" -s base >/dev/null 2>&1; then
        dc="$(echo "$LDAP_BASE_DN" | sed -n 's/^dc=\([^,]*\).*/\1/p')"
        log "Creating base entry $LDAP_BASE_DN and default OUs"
        ldapadd -x -H "$boot_ldapi" -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null <<EOF
dn: $LDAP_BASE_DN
objectClass: top
objectClass: dcObject
objectClass: organization
o: $LDAP_ORGANISATION
dc: $dc

dn: ou=people,$LDAP_BASE_DN
objectClass: organizationalUnit
ou: people

dn: ou=groups,$LDAP_BASE_DN
objectClass: organizationalUnit
ou: groups
EOF
    fi

    # Read-only bind account.
    if [ "$LDAP_READONLY_USER" = "true" ]; then
        ro_hash="$(slappasswd -s "$LDAP_READONLY_USER_PASSWORD")"
        log "Creating readonly user cn=$LDAP_READONLY_USER_USERNAME"
        ldapadd -x -H "$boot_ldapi" -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1 <<EOF || true
dn: cn=$LDAP_READONLY_USER_USERNAME,$LDAP_BASE_DN
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: $LDAP_READONLY_USER_USERNAME
description: Read-only bind account
userPassword: $ro_hash
EOF
    fi

    # Second read-only account that may also read userPassword hashes.
    if [ "$LDAP_READONLY_PW_USER" = "true" ]; then
        ropw_hash="$(slappasswd -s "$LDAP_READONLY_PW_PASSWORD")"
        log "Creating password-reading readonly user cn=$LDAP_READONLY_PW_USERNAME"
        ldapadd -x -H "$boot_ldapi" -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_ADMIN_PASSWORD" >/dev/null 2>&1 <<EOF || true
dn: cn=$LDAP_READONLY_PW_USERNAME,$LDAP_BASE_DN
objectClass: simpleSecurityObject
objectClass: organizationalRole
cn: $LDAP_READONLY_PW_USERNAME
description: Read-only bind account with userPassword read (local password verification)
userPassword: $ropw_hash
EOF
    fi

    # User-supplied bootstrap data. -c keeps going past entries that already
    # exist so the LDIF is effectively idempotent across volume restores.
    for f in "$BOOTSTRAP_DIR"/*.ldif; do
        [ -f "$f" ] || continue
        log "Applying bootstrap LDIF $f"
        ldapadd -c -x -H "$boot_ldapi" -D "cn=admin,$LDAP_BASE_DN" -w "$LDAP_ADMIN_PASSWORD" -f "$f" >/dev/null 2>&1 \
            || log "  (some entries in $f already existed and were skipped)"
    done

    log "Stopping temporary slapd"
    pid="$(cat /run/slapd/slapd.pid 2>/dev/null || true)"
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do
        [ -e /run/slapd/slapd.pid ] || break
        sleep 0.3
    done
}

# ─── TLS cert watcher ───────────────────────────────────────────────────────
# Poll the configured certificate file; when its content changes (an external
# renewal), ask the running slapd to re-read its TLS material. Decoupled from
# whoever renews — no docker socket or cross-container signalling needed.
watch_tls_certs() {
    cert="${TLS_CRT:-}"
    [ -n "$cert" ] || return 0
    last="$(sha256sum "$cert" 2>/dev/null | awk '{print $1}')"
    log "Watching $cert for renewals every ${LDAP_TLS_WATCH_INTERVAL}s"
    while sleep "$LDAP_TLS_WATCH_INTERVAL"; do
        [ -f "$cert" ] || continue
        cur="$(sha256sum "$cert" 2>/dev/null | awk '{print $1}')"
        [ -n "$cur" ] && [ "$cur" != "$last" ] || continue
        log "TLS certificate change detected — reloading slapd TLS context"
        if LDAP_ADMIN_PASSWORD="$LDAP_ADMIN_PASSWORD" \
           LDAP_CONFIG_PASSWORD="$LDAP_CONFIG_PASSWORD" \
           LDAPI_URL="$LDAPI_URL" reload-tls; then
            last="$cur"
        else
            log "TLS reload failed; will retry on the next change"
        fi
    done
}

# ─── Main ───────────────────────────────────────────────────────────────────
setup_locale_tz

mkdir -p /run/slapd
chown -R openldap:openldap /run/slapd

setup_tls

if [ -f "$DATA_DIR/data.mdb" ] && [ -n "$(ls -A "$CONFIG_DIR" 2>/dev/null)" ]; then
    log "Existing database detected — skipping bootstrap"
else
    bootstrap_config
    bootstrap_data
fi

# If the user overrode CMD with something other than slapd, just run it.
if [ "$1" != "slapd" ]; then
    exec "$@"
fi

LISTEN="ldap:/// $LDAPI_URL"
[ "$LDAP_TLS" = "true" ] && LISTEN="$LISTEN ldaps:///"

# Start the optional cert watcher in the background before handing PID 1 to
# slapd; it polls slapd over ldapi:// once that listener is up.
if [ "$LDAP_TLS" = "true" ] && [ "$LDAP_TLS_WATCH" = "true" ]; then
    watch_tls_certs &
fi

log "Starting slapd (listeners: $LISTEN)"
# -d keeps slapd in the foreground as PID 1 and emits logs to stderr; the
# numeric value doubles as the log level.
exec slapd -h "$LISTEN" -u openldap -g openldap -F "$CONFIG_DIR" -d "$LDAP_LOG_LEVEL"
