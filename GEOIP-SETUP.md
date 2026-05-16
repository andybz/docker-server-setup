# GeoIP2 Country Blocking Setup

Instructions for setting up GeoIP2 country blocking on a server running Nginx Proxy Manager (jc21/nginx-proxy-manager) in Docker.

## Prerequisites

- Server already set up with `setup.sh` (NPM running in Docker)
- A free MaxMind account: https://www.maxmind.com/en/geolite2/signup

## Step 1: Verify GeoIP2 Module

Confirm the GeoIP2 module is compiled into NPM's nginx:

```bash
docker exec nginx-proxy-manager nginx -V 2>&1 | tr ' ' '\n' | grep -i geo
```

You should see `--add-dynamic-module=/tmp/openresty/ngx_http_geoip2_module`. The module `.so` file should be at:

```bash
docker exec nginx-proxy-manager find / -name 'ngx_http_geoip2_module*'
# Expected: /usr/lib/nginx/modules/ngx_http_geoip2_module.so
```

## Step 2: Download GeoLite2-Country Database

Get your license key from MaxMind: **Services → My License Key**.

```bash
sudo mkdir -p ~/server/npm/geoip
wget -O /tmp/GeoLite2-Country.tar.gz "https://download.maxmind.com/app/geoip_download?edition_id=GeoLite2-Country&license_key=YOUR_LICENSE_KEY&suffix=tar.gz"
sudo tar -xzf /tmp/GeoLite2-Country.tar.gz -C /tmp/
sudo cp /tmp/GeoLite2-Country_*/GeoLite2-Country.mmdb ~/server/npm/geoip/
```

## Step 3: Create Nginx Custom Config Files

### 3a. Load the GeoIP2 module (`root_top.conf`)

```bash
sudo mkdir -p ~/server/npm/data/nginx/custom

sudo tee ~/server/npm/data/nginx/custom/root_top.conf > /dev/null << 'CONF'
load_module /usr/lib/nginx/modules/ngx_http_geoip2_module.so;
CONF
```

### 3b. GeoIP2 database lookup and country map (`http_top.conf`)

Replace the country codes (CN, RU, KP, DE) with whichever countries you want to block:

```bash
sudo tee ~/server/npm/data/nginx/custom/http_top.conf > /dev/null << 'CONF'
# GeoIP2 Country lookup
geoip2 /etc/geoip/GeoLite2-Country.mmdb {
    auto_reload 24h;
    $geoip2_country_code default=XX country iso_code;
}

# Map country codes to allow/deny
# 1 = blocked, 0 = allowed
map $geoip2_country_code $blocked_country {
    default 0;
    CN 1;
    RU 1;
    KP 1;
    DE 1;
}
CONF
```

### 3c. Enforce blocking on all proxy hosts (`server_proxy.conf`)

```bash
sudo tee ~/server/npm/data/nginx/custom/server_proxy.conf > /dev/null << 'CONF'
# Block requests from banned countries
if ($blocked_country) {
    return 403;
}
CONF
```

## Step 4: Mount GeoIP Database in Docker Compose

Add the following volume to the `nginx-proxy-manager` service in `~/server/docker-compose.yml`:

```yaml
      - ./npm/geoip:/etc/geoip:ro
```

It goes under the existing volumes, e.g.:

```yaml
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
      - ./npm/geoip:/etc/geoip:ro    # <-- add this line
```

## Step 5: Restart NPM

```bash
sudo docker compose -f ~/server/docker-compose.yml up -d nginx-proxy-manager
```

Verify the config is valid:

```bash
docker exec nginx-proxy-manager nginx -t
```

## Step 6: Test

Test with a blocked country IP (China - 180.76.76.76):

```bash
curl -s -o /dev/null -w "HTTP Status: %{http_code}" \
  -H "X-Real-IP: 180.76.76.76" \
  --resolve yourdomain.com:443:127.0.0.1 \
  --insecure https://yourdomain.com
# Expected: 403
```

Test with an allowed IP (US - 8.8.8.8):

```bash
curl -s -o /dev/null -w "HTTP Status: %{http_code}" \
  -H "X-Real-IP: 8.8.8.8" \
  --resolve yourdomain.com:443:127.0.0.1 \
  --insecure https://yourdomain.com
# Expected: 200
```

## Managing Bans

After setup, use the `andybz` command (options **Ban Country** / **Unban Country**) to add or remove country blocks without manually editing config files. The script handles editing `http_top.conf` and reloading nginx automatically.

To manually add/remove countries, edit `~/server/npm/data/nginx/custom/http_top.conf` and reload:

```bash
docker exec nginx-proxy-manager nginx -s reload
```

## Country Codes Reference

Use ISO 3166-1 alpha-2 codes: https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2
