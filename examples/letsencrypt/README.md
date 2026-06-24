# Let's Encrypt (DNS-01) example

Issue and auto-renew a real Let's Encrypt certificate for the LDAP server using
a **certbot sidecar** and the **DNS-01** challenge — no public port 80, works
behind NAT, supports wildcards.

## How it fits together

```
certbot (sidecar) --DNS-01--> Let's Encrypt
      |  deploy-hook copies cert
      v
  certs volume  --mounted ro-->  openldap  (LDAP_TLS_WATCH reloads slapd)
```

- `certbot` issues/renews the cert and runs `deploy-hook.sh`, which copies
  `fullchain.pem` / `privkey.pem` / `chain.pem` into the shared `certs` volume
  with permissions slapd (uid/gid 999) can read.
- `openldap` mounts that volume at `/container/certs`, serves the cert, and —
  with `LDAP_TLS_WATCH=true` — polls it and hot-reloads slapd's TLS context on
  every renewal. **No restart, no docker socket.**

Why a copy instead of mounting `/etc/letsencrypt` directly: certbot keeps the
live tree at mode `0700 root`, which a non-root slapd cannot traverse. The
deploy hook publishes a readable copy and keeps the private key group-only.

## Setup

1. **Credentials** — scoped Cloudflare token (`Zone.DNS:Edit` on the zone):
   ```sh
   cp cloudflare.ini.example cloudflare.ini
   $EDITOR cloudflare.ini && chmod 600 cloudflare.ini
   ```
   Using another provider? Swap the `certbot/dns-cloudflare` image and the
   `cloudflare.ini` mount for your plugin (`certbot/dns-route53`, etc.).

2. **Domain** — set `LDAP_DOMAIN` (and the issuance `-d` below) to your domain.

3. **Initial issuance** (one-time) — registers the cert and stores the deploy
   hook so future `certbot renew` runs reuse it:
   ```sh
   docker compose run --rm certbot certonly \
     --dns-cloudflare --dns-cloudflare-credentials /etc/cloudflare.ini \
     --dns-cloudflare-propagation-seconds 30 \
     -m you@example.com --agree-tos --no-eff-email \
     --deploy-hook /deploy-hook.sh \
     -d ldap.intechcore.online
   ```

4. **Start the stack:**
   ```sh
   docker compose up -d
   ```

## Renewal

The `certbot` service retries `certbot renew` every 12h (a no-op until ~30 days
before expiry). On a real renewal the stored deploy hook republishes the cert
and slapd's watcher reloads it within `LDAP_TLS_WATCH_INTERVAL` (default 1h).

Force a dry run / manual renewal check:
```sh
docker compose exec certbot certbot renew --dry-run
```

Apply a renewed cert immediately instead of waiting for the watcher poll:
```sh
docker compose exec openldap reload-tls
```

## Verify

```sh
echo | openssl s_client -connect ldap.intechcore.online:636 2>/dev/null \
  | openssl x509 -noout -issuer -subject -enddate
# issuer should be Let's Encrypt (R10/R11/E1…)
```
