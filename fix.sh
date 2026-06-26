#!/bin/bash
# ================================================================
#   VPS PATCH — ws-epro (ultra-simple) + XRay VMESS fix
#   Run: bash <(curl -fsSL https://raw.githubusercontent.com/ishmaelbii416/vps/main/fix.sh)
# ================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root!${NC}"; exit 1; }
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; }
step() { echo -e "\n${YELLOW}══ $1 ══${NC}"; }

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${BOLD}${YELLOW}     VPS PATCH — Ultra-simple ws-epro + VMESS Fix          ${NC}${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

source /etc/vps-config 2>/dev/null || { err "Run full install first."; exit 1; }

# ════════════════════════════════════════════════════════════════
step "1 — Kill everything on ports 80 and 8880"
# ════════════════════════════════════════════════════════════════
systemctl stop ws-epro nginx 2>/dev/null
fuser -k 80/tcp   2>/dev/null
fuser -k 8880/tcp 2>/dev/null
sleep 1

# Verify ports are free
ss -tlnp | grep -E ':80 |:8880 ' && err "Ports still in use!" || log "Ports 80 and 8880 are free."

# ════════════════════════════════════════════════════════════════
step "2 — Install ultra-simple ws-epro"
# ════════════════════════════════════════════════════════════════
# Logic:
#   - GET /cdn-cgi/...  →  200 OK + keep alive  (CDN liveness probe)
#   - EVERYTHING else   →  101 Switching Protocols → SSH tunnel
# No header inspection. No method detection. Just 2 cases.
cat > /usr/local/bin/ws-epro.py <<'WSPY'
#!/usr/bin/env python3
"""
ws-epro ultra-simple
  GET /cdn-cgi/... → 200 OK (CDN probe, stay alive, read next request)
  ANYTHING ELSE    → 101 Switching Protocols → SSH tunnel

Why so simple?
  CDN proxies (Cloudflare, etc.) strip hop-by-hop headers like
  'Connection: upgrade' and 'Upgrade: websocket' before forwarding
  to the origin. The UNLOCK / WebDAV method is the only reliable
  signal — but even method detection can fail if the CDN rewrites it.
  Simplest solution: anything that is not a CDN probe is a tunnel request.
"""
import asyncio, sys

SSH_HOST = "127.0.0.1"
SSH_PORT = 22
PORTS    = [80, 8880]

R101 = (b"HTTP/1.1 101 Switching Protocols\r\n"
        b"Upgrade: websocket\r\n"
        b"Connection: Upgrade\r\n\r\n")
R200 = (b"HTTP/1.1 200 OK\r\n"
        b"Content-Type: text/plain\r\n"
        b"Content-Length: 2\r\n"
        b"Connection: keep-alive\r\n\r\nOK")

async def pipe(r, w):
    try:
        while chunk := await r.read(32768):
            w.write(chunk); await w.drain()
    except Exception:
        pass
    finally:
        try: w.close()
        except Exception: pass

async def read_headers(reader):
    buf = b""
    try:
        while b"\r\n\r\n" not in buf:
            chunk = await asyncio.wait_for(reader.read(4096), timeout=20)
            if not chunk:
                return None
            buf += chunk
            if len(buf) > 32768:
                return None
    except asyncio.TimeoutError:
        return None
    return buf

async def handle(reader, writer):
    try:
        while True:
            hdr = await read_headers(reader)
            if hdr is None:
                return

            # CDN probe: GET /cdn-cgi/... → 200, loop for next split
            first = hdr.split(b"\r\n")[0].upper()
            if first.startswith(b"GET ") and b"/CDN-CGI" in first:
                writer.write(R200)
                await writer.drain()
                continue   # read next request in this connection

            # Everything else (UNLOCK, PROPFIND, GET /, POST…) → tunnel
            writer.write(R101)
            await writer.drain()
            try:
                sr, sw = await asyncio.open_connection(SSH_HOST, SSH_PORT)
            except OSError:
                return
            await asyncio.gather(pipe(reader, sw), pipe(sr, writer))
            return

    except Exception:
        pass
    finally:
        try: writer.close()
        except Exception: pass

async def main():
    servers = []
    for port in PORTS:
        try:
            srv = await asyncio.start_server(handle, "0.0.0.0", port)
            servers.append(srv)
            print(f"[ws-epro] :{port} ready", flush=True)
        except OSError as e:
            print(f"[ws-epro] :{port} FAILED — {e}", flush=True)
    if not servers:
        sys.exit(1)
    await asyncio.gather(*[s.serve_forever() for s in servers])

asyncio.run(main())
WSPY
chmod +x /usr/local/bin/ws-epro.py

cat > /etc/systemd/system/ws-epro.service <<'SVCEOF'
[Unit]
Description=ws-epro ultra-simple HTTP Custom SSH tunnel proxy
After=network.target
Before=nginx.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-epro.py
Restart=on-failure
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable --quiet ws-epro
systemctl start ws-epro
sleep 2

# ── Sanity check: does port 80 now return 101 on UNLOCK? ─────
echo -e "${CYAN}Testing port 80 response to UNLOCK...${NC}"
RESP=$(printf 'UNLOCK /? HTTP/1.1\r\nHost: %s\r\n\r\n' "${DOMAIN}" \
       | timeout 3 nc -q1 127.0.0.1 80 2>/dev/null | head -1)
echo -e "  Response: ${WHITE}${RESP}${NC}"
if echo "$RESP" | grep -q "101"; then
    log "ws-epro returning 101 correctly on port 80 ✓"
else
    err "ws-epro NOT returning 101 — check: systemctl status ws-epro"
fi

# ── Same check port 8880 ──────────────────────────────────────
RESP2=$(printf 'UNLOCK /? HTTP/1.1\r\nHost: %s\r\n\r\n' "${DOMAIN}" \
        | timeout 3 nc -q1 127.0.0.1 8880 2>/dev/null | head -1)
echo -e "  Port 8880: ${WHITE}${RESP2}${NC}"
[[ "$RESP2" == *"101"* ]] && log "Port 8880 ✓" || err "Port 8880 not responding"

# ════════════════════════════════════════════════════════════════
step "3 — Fix NGINX (off port 80, client_max_body_size 0)"
# ════════════════════════════════════════════════════════════════
cat > /etc/nginx/conf.d/vps-tunnel.conf <<NGINXCONF
server {
    listen 8181;
    server_name ${DOMAIN} _;
    client_max_body_size 0;
    proxy_request_buffering off;

    location /vmess/ {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
    }
    location /vless/ {
        proxy_pass http://127.0.0.1:8444;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }
    location /trojan/ {
        proxy_pass http://127.0.0.1:2087;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }
    location /ssh-ws {
        proxy_pass http://127.0.0.1:22;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }
    location / {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}

# WSS on 8080
server {
    listen 8080 ssl;
    server_name ${DOMAIN} _;
    ssl_certificate     /etc/xray/ssl/cert.crt;
    ssl_certificate_key /etc/xray/ssl/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    client_max_body_size 0;
    proxy_request_buffering off;

    location /vmess/ {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }
    location /ssh-ws {
        proxy_pass http://127.0.0.1:22;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }
    location / {
        proxy_pass http://127.0.0.1:8880;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_read_timeout 3600s;
        client_max_body_size 0;
    }
}
NGINXCONF

nginx -t 2>/dev/null && systemctl restart nginx && log "NGINX restarted on 8181/8080" \
    || err "NGINX config error — run: nginx -t"

# ════════════════════════════════════════════════════════════════
step "4 — Update XRay VMESS/VLESS/Trojan config (proper WS paths)"
# ════════════════════════════════════════════════════════════════
# Read existing UUIDs/passwords so they don't change
VMESS_UUID=$(grep -A3 '"vmess"' /etc/xray/config.json 2>/dev/null \
    | grep '"id"' | head -1 | cut -d'"' -f4)
VLESS_UUID=$(grep -A3 '"vless"' /etc/xray/config.json 2>/dev/null \
    | grep '"id"' | head -1 | cut -d'"' -f4)
TROJAN_PASS=$(grep '"password"' /etc/xray/config.json 2>/dev/null \
    | head -1 | cut -d'"' -f4)
SS_PASS=$(grep '"password"' /etc/xray/config.json 2>/dev/null \
    | tail -1 | cut -d'"' -f4)

# Generate new ones only if missing
[[ -z "$VMESS_UUID"  ]] && VMESS_UUID=$(cat /proc/sys/kernel/random/uuid)
[[ -z "$VLESS_UUID"  ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
[[ -z "$TROJAN_PASS" ]] && TROJAN_PASS=$(openssl rand -hex 12)
[[ -z "$SS_PASS"     ]] && SS_PASS=$(openssl rand -hex 12)

cat > /etc/xray/config.json <<XCONFIG
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": 8443,
      "listen": "127.0.0.1",
      "protocol": "vmess",
      "settings": {
        "clients": [{"id": "${VMESS_UUID}", "alterId": 0, "security": "auto", "level": 8}]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess/"}
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
    },
    {
      "port": 8444,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "${VLESS_UUID}", "flow": ""}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vless/"}
      }
    },
    {
      "port": 2087,
      "listen": "127.0.0.1",
      "protocol": "trojan",
      "settings": {"clients": [{"password": "${TROJAN_PASS}"}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/trojan/"}
      }
    },
    {
      "port": 2096,
      "protocol": "shadowsocks",
      "settings": {
        "method": "chacha20-ietf-poly1305",
        "password": "${SS_PASS}",
        "network": "tcp,udp"
      }
    }
  ],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "blocked"}
  ]
}
XCONFIG

systemctl restart xray && log "XRay restarted with new WS paths." \
    || err "XRay failed — check: journalctl -u xray -n 20"

# Save UUIDs/passwords
{
    echo "VMESS_UUID=${VMESS_UUID}"
    echo "VLESS_UUID=${VLESS_UUID}"
    echo "TROJAN_PASS=${TROJAN_PASS}"
    echo "SS_PASS=${SS_PASS}"
} >> /etc/vps-config

# ════════════════════════════════════════════════════════════════
step "5 — Final port check"
# ════════════════════════════════════════════════════════════════
echo ""
for PORT in 22 80 442 443 2087 2096 7200 7300 8080 8181 8443 8444 8880; do
    ss -tlnp 2>/dev/null | grep -q ":${PORT} " \
        && echo -e "  ${GREEN}●${NC} :${PORT} OPEN" \
        || echo -e "  ${RED}●${NC} :${PORT} CLOSED"
done

# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}══ PATCH COMPLETE ══${NC}"
echo ""
echo -e "${CYAN}  SSH / HTTP Custom config:${NC}"
echo -e "  SSH host  : ${DOMAIN}"
echo -e "  SSH port  : 22"
echo -e "  WS proxy  : your CDN bug host (e.g. imagedelivery.net:80)"
echo -e ""
echo -e "  ${WHITE}Payload (port 80):${NC}"
echo -e "  GET /cdn-cgi/trace HTTP/1.1[crlf]Host: [bug-host][crlf][crlf][split]"
echo -e "  UNLOCK /? HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]"
echo -e "  Upgrade: websocket[crlf][crlf][split]"
echo -e "  UNLOCK /? HTTP/1.1[crlf]Host: [bug-host][crlf]"
echo -e "  Content-Length: 999999999999[crlf]"
echo ""
echo -e "${CYAN}  VMESS (for V2Ray/XRay client):${NC}"
echo -e "  Bug host : imagedelivery.net  Port: 443"
echo -e "  SNI/Host : ${DOMAIN}"
echo -e "  UUID     : ${VMESS_UUID}"
echo -e "  AlterId  : 0    Security: auto"
echo -e "  Network  : ws   Path: /vmess/"
echo -e "  TLS      : tls  allowInsecure: true"
echo ""
echo -e "${CYAN}  VLESS:${NC}"
echo -e "  UUID : ${VLESS_UUID}  Path: /vless/  Network: ws"
echo ""
echo -e "${CYAN}  Trojan:${NC}"
echo -e "  Pass : ${TROJAN_PASS}  Path: /trojan/  Network: ws"
echo ""
echo -e "${YELLOW}  IMPORTANT: ${DOMAIN} must be Cloudflare-proxied (orange cloud)${NC}"
echo -e "${YELLOW}  for CDN bug tunneling to work.${NC}"
echo ""
