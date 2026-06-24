#!/bin/sh
# Make a running slapd re-read its TLS certificate files without a restart.
#
# slapd loads its TLS material once at startup and does not watch the files, so
# after a Let's Encrypt (or any) renewal the new certificate on disk is not
# served until the TLS context is rebuilt. Modifying an olcTLS* attribute in
# cn=config makes slapd 2.6 reinitialise TLS from the (now renewed) files. We
# re-assert the currently configured paths (a no-op value change) to trigger it.
#
# Invoke from the certificate tool's deploy/renew hook, e.g.:
#   docker exec <container> reload-tls
#
# The in-image cert watcher (LDAP_TLS_WATCH=true) calls this automatically.
set -e

LDAPI_URL="${LDAPI_URL:-ldapi://%2Frun%2Fslapd%2Fldapi}"
LDAP_ADMIN_PASSWORD="${LDAP_ADMIN_PASSWORD:-admin}"
LDAP_CONFIG_PASSWORD="${LDAP_CONFIG_PASSWORD:-$LDAP_ADMIN_PASSWORD}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [reload-tls] $1"; }

attrs=$(ldapsearch -o ldif-wrap=no -LLL -x -H "$LDAPI_URL" \
    -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" \
    -b cn=config -s base \
    olcTLSCertificateFile olcTLSCertificateKeyFile olcTLSCACertificateFile 2>/dev/null) || {
    log "ERROR: cannot read cn=config (is slapd up and the config password correct?)"
    exit 1
}

crt=$(echo "$attrs" | sed -n 's/^olcTLSCertificateFile: //p')
key=$(echo "$attrs" | sed -n 's/^olcTLSCertificateKeyFile: //p')
ca=$(echo "$attrs"  | sed -n 's/^olcTLSCACertificateFile: //p')

if [ -z "$crt" ] || [ -z "$key" ]; then
    log "TLS is not configured (no olcTLSCertificateFile) — nothing to reload"
    exit 0
fi

ldif="dn: cn=config
replace: olcTLSCertificateFile
olcTLSCertificateFile: $crt
-
replace: olcTLSCertificateKeyFile
olcTLSCertificateKeyFile: $key"

if [ -n "$ca" ]; then
    ldif="$ldif
-
replace: olcTLSCACertificateFile
olcTLSCACertificateFile: $ca"
fi

log "Reloading TLS context (cert=$crt)"
printf '%s\n' "$ldif" | ldapmodify -x -H "$LDAPI_URL" \
    -D "cn=admin,cn=config" -w "$LDAP_CONFIG_PASSWORD" >/dev/null
log "TLS context reloaded"
