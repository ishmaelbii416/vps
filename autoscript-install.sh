#!/bin/bash
# ================================================================
#   VPS AUTO SCRIPT PREMIUM - HTTP Custom Tunneling Suite
#   Compatible: Ubuntu 24.04 LTS (x86_64)
#   Services: SSH-WS, Dropbear, NGINX, XRay, HAProxy,
#             UDP-Custom (BadVPN), SlowDNS, ZiVPN, Squid
#   Install : bash <(curl -fsSL https://your-domain.com/install.sh)
# ================================================================

# ── Colors ──────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'

# ── Root check ──────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root!${NC}"; exit 1; }

# ── OS check ────────────────────────────────────────────────────
source /etc/os-release
[[ "$ID" != "ubuntu" ]] && { echo -e "${RED}Ubuntu only!${NC}"; exit 1; }

# ── Config ──────────────────────────────────────────────────────
DOMAIN=""
SSH_PORT=22
DROPBEAR_PORT=442
DROPBEAR_WS_PORT=443
SSH_WS_PORT=80
SSH_WSS_PORT=8080
XRAY_WS_PORT=8443
XRAY_GRPC_PORT=8444
HAPROXY_PORT=443
SLOWDNS_PORT=5300
UDPGW_PORT1=7200
UDPGW_PORT2=7300
SQUID_PORT=8888
ZIVPN_PORT=7777
PANEL_PORT=2053

banner() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${YELLOW}${BOLD}      WELCOME TO VPS AUTO SCRIPT PREMIUM TUNNELING        ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}✦ System  :${NC} $(lsb_release -ds 2>/dev/null || echo Ubuntu)            "
    echo -e "${CYAN}║${NC}  ${GREEN}✦ Kernel  :${NC} $(uname -r)                         "
    echo -e "${CYAN}║${NC}  ${GREEN}✦ IP      :${NC} $(curl -s ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')  "
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
}

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
info()   { echo -e "${CYAN}[…]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
err()    { echo -e "${RED}[✘]${NC} $1"; }
step()   { echo -e "\n${MAGENTA}══ $1 ══${NC}"; }

# ════════════════════════════════════════════════════════════════
step "STEP 1 — Stop non-essential services (keeping SSH port 22)"
# ════════════════════════════════════════════════════════════════
STOP_SERVICES=(
    badvpn-udpgw@7200 badvpn-udpgw@7300
    dropbear-ws dropbear
    stunnel-ws ws-proxy zivpn squid
    nginx haproxy
)
for svc in "${STOP_SERVICES[@]}"; do
    systemctl stop    "$svc" 2>/dev/null
    systemctl disable "$svc" 2>/dev/null
    info "Stopped: $svc"
done
log "Non-essential services stopped. SSH on port 22 is intact."

# ════════════════════════════════════════════════════════════════
step "STEP 2 — System update & core packages"
# ════════════════════════════════════════════════════════════════
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget unzip tar git openssl uuid-runtime \
    net-tools iptables-persistent netfilter-persistent \
    cron at haveged nscd preload vnstat \
    python3 python3-pip \
    nginx haproxy squid dropbear \
    stunnel4 screen tmux jq socat \
    build-essential cmake gcc make \
    lsof ufw fail2ban dnsutils iproute2
log "Core packages installed."

# ════════════════════════════════════════════════════════════════
step "STEP 3 — Get server public IP & domain"
# ════════════════════════════════════════════════════════════════
PUBLIC_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com)
[[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(hostname -I | awk '{print $1}')
echo -e "${CYAN}Detected public IP: ${WHITE}${PUBLIC_IP}${NC}"
read -rp "Enter your domain (press Enter to use IP): " DOMAIN
[[ -z "$DOMAIN" ]] && DOMAIN="$PUBLIC_IP"
echo "DOMAIN=$DOMAIN" > /etc/vps-config
echo "PUBLIC_IP=$PUBLIC_IP" >> /etc/vps-config
log "Server identity: $DOMAIN"

# ════════════════════════════════════════════════════════════════
step "STEP 4 — Install XRay (VMESS/VLESS/Trojan WS+gRPC)"
# ════════════════════════════════════════════════════════════════
XRAY_VER=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | jq -r .tag_name 2>/dev/null || echo "v1.8.11")
info "Installing XRay $XRAY_VER..."
mkdir -p /usr/local/xray
wget -qO /tmp/xray.zip \
    "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VER}/Xray-linux-64.zip"
unzip -qo /tmp/xray.zip -d /usr/local/xray/
chmod +x /usr/local/xray/xray
ln -sf /usr/local/xray/xray /usr/local/bin/xray

# Generate UUIDs for each protocol
VMESS_UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
VLESS_UUID=$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
TROJAN_PASS=$(openssl rand -hex 12)
SS_PASS=$(openssl rand -hex 12)

# Self-signed TLS cert
mkdir -p /etc/xray/ssl
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout /etc/xray/ssl/private.key \
    -out /etc/xray/ssl/cert.crt \
    -days 3650 \
    -subj "/CN=${DOMAIN}" 2>/dev/null
log "TLS certificate generated."

# XRay config
cat > /etc/xray/config.json <<XCONFIG
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "port": ${XRAY_WS_PORT},
      "protocol": "vmess",
      "settings": {"clients": [{"id": "${VMESS_UUID}", "alterId": 0}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/vmess-ws"},
        "tlsSettings": {"certificates": [{"certificateFile": "/etc/xray/ssl/cert.crt","keyFile": "/etc/xray/ssl/private.key"}]},
        "security": "tls"
      },
      "sniffing": {"enabled": true, "destOverride": ["http","tls"]}
    },
    {
      "port": ${XRAY_GRPC_PORT},
      "protocol": "vless",
      "settings": {"clients": [{"id": "${VLESS_UUID}", "flow": "xtls-rprx-vision"}], "decryption": "none"},
      "streamSettings": {
        "network": "grpc",
        "grpcSettings": {"serviceName": "vless-grpc"},
        "tlsSettings": {"certificates": [{"certificateFile": "/etc/xray/ssl/cert.crt","keyFile": "/etc/xray/ssl/private.key"}]},
        "security": "tls"
      }
    },
    {
      "port": 2087,
      "protocol": "trojan",
      "settings": {"clients": [{"password": "${TROJAN_PASS}"}]},
      "streamSettings": {
        "network": "ws",
        "wsSettings": {"path": "/trojan-ws"},
        "tlsSettings": {"certificates": [{"certificateFile": "/etc/xray/ssl/cert.crt","keyFile": "/etc/xray/ssl/private.key"}]},
        "security": "tls"
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
  ],
  "routing": {
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"}
    ]
  }
}
XCONFIG

# XRay systemd service
cat > /etc/systemd/system/xray.service <<XSVC
[Unit]
Description=XRay Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
XSVC
systemctl daemon-reload
systemctl enable --quiet xray
systemctl restart xray
log "XRay installed and running (VMESS-WS:${XRAY_WS_PORT}, VLESS-gRPC:${XRAY_GRPC_PORT}, Trojan-WS:2087, SS:2096)"

# ════════════════════════════════════════════════════════════════
step "STEP 5 — Configure Dropbear (SSH alt ports)"
# ════════════════════════════════════════════════════════════════
cat > /etc/default/dropbear <<DROPBEAR_CONF
NO_START=0
DROPBEAR_PORT=${DROPBEAR_PORT}
DROPBEAR_EXTRA_ARGS="-p ${DROPBEAR_PORT} -p ${DROPBEAR_WS_PORT}"
DROPBEAR_BANNER="/etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
DROPBEAR_CONF

systemctl enable --quiet dropbear
systemctl restart dropbear
log "Dropbear running on ports ${DROPBEAR_PORT} and ${DROPBEAR_WS_PORT}"

# ════════════════════════════════════════════════════════════════
step "STEP 6 — BadVPN UDP Gateway"
# ════════════════════════════════════════════════════════════════
# Install badvpn from source if not already installed
if ! command -v badvpn-udpgw &>/dev/null; then
    info "Building badvpn-udpgw from source..."
    apt-get install -y -qq cmake build-essential 2>/dev/null
    cd /tmp || exit
    wget -qO badvpn.zip https://github.com/ambrop72/badvpn/archive/master.zip
    unzip -qo badvpn.zip
    cd badvpn-master || exit
    mkdir -p build && cd build || exit
    cmake .. -DBUILD_NOTHING_BY_DEFAULT=1 -DBUILD_UDPGW=1 \
        -DCMAKE_INSTALL_PREFIX=/usr/local >/dev/null 2>&1
    make -j"$(nproc)" >/dev/null 2>&1
    make install >/dev/null 2>&1
    cd /root || exit
fi

# Systemd units for UDP gateway on both ports
for PORT in ${UDPGW_PORT1} ${UDPGW_PORT2}; do
cat > /etc/systemd/system/badvpn-udpgw@${PORT}.service <<UDPSVC
[Unit]
Description=BadVPN UDP Gateway Port ${PORT}
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/badvpn-udpgw \
    --listen-addr 127.0.0.1:${PORT} \
    --max-clients 500 \
    --max-connections-for-client 10
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UDPSVC
done
systemctl daemon-reload
systemctl enable --quiet badvpn-udpgw@${UDPGW_PORT1} badvpn-udpgw@${UDPGW_PORT2}
systemctl restart badvpn-udpgw@${UDPGW_PORT1} badvpn-udpgw@${UDPGW_PORT2}
log "BadVPN UDP gateway on ports ${UDPGW_PORT1} and ${UDPGW_PORT2}"

# ════════════════════════════════════════════════════════════════
step "STEP 7 — NGINX (WebSocket Proxy, internal port 8181)"
# ════════════════════════════════════════════════════════════════
# NOTE: ws-epro owns port 80 for HTTP Custom 101 handling.
#       NGINX runs on 8181 (internal) for path-based WS routing.
#       NGINX on 8080 handles WSS (TLS WebSocket).
rm -f /etc/nginx/sites-enabled/*
cat > /etc/nginx/conf.d/vps-tunnel.conf <<NGINXCONF
# ── Internal WebSocket path router (HTTP) ──
server {
    listen 8181;
    server_name ${DOMAIN} _;

    # No body size limit — never return 413
    client_max_body_size 0;
    proxy_request_buffering off;

    # Allow non-standard methods (UNLOCK, CONNECT, etc.)
    error_page 405 = @handle_any;
    location @handle_any { proxy_pass http://127.0.0.1:8880; }

    location /ssh-ws {
        proxy_pass http://127.0.0.1:${SSH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /dropbear-ws {
        proxy_pass http://127.0.0.1:${DROPBEAR_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }

    location /vmess-ws {
        proxy_pass http://127.0.0.1:${XRAY_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }

    location /trojan-ws {
        proxy_pass http://127.0.0.1:2087;
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
        proxy_set_header Host \$host;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        client_max_body_size 0;
        proxy_request_buffering off;
    }
}

# ── WSS (TLS WebSocket, port 8080) ──
server {
    listen ${SSH_WSS_PORT} ssl;
    server_name ${DOMAIN} _;

    ssl_certificate /etc/xray/ssl/cert.crt;
    ssl_certificate_key /etc/xray/ssl/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    client_max_body_size 0;
    proxy_request_buffering off;

    location /ssh-ws {
        proxy_pass http://127.0.0.1:${SSH_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }

    location /vmess-ws {
        proxy_pass http://127.0.0.1:${XRAY_WS_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }

    location /trojan-ws {
        proxy_pass http://127.0.0.1:2087;
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
        proxy_request_buffering off;
    }
}
NGINXCONF

nginx -t 2>/dev/null && systemctl enable --quiet nginx && systemctl restart nginx
log "NGINX running (internal:8181, WSS:${SSH_WSS_PORT})"

# ════════════════════════════════════════════════════════════════
step "STEP 8 — HAProxy (Port 443 multiplexer)"
# ════════════════════════════════════════════════════════════════
cat > /etc/haproxy/haproxy.cfg <<HAPROXYCFG
global
    log /dev/log local0
    maxconn 50000
    ulimit-n 65536
    user haproxy
    group haproxy

defaults
    log global
    mode tcp
    timeout connect 5s
    timeout client 60s
    timeout server 60s
    option dontlognull

frontend vps_front
    bind *:${HAPROXY_PORT}
    tcp-request inspect-delay 5s
    tcp-request content accept if { req.ssl_hello_type 1 }

    use_backend xray_vless  if { req.ssl_sni -i ${DOMAIN} }
    use_backend ssh_dropbear
    default_backend nginx_http

backend xray_vless
    server xray 127.0.0.1:${XRAY_GRPC_PORT} check

backend ssh_dropbear
    server dropbear 127.0.0.1:${DROPBEAR_PORT} check

backend nginx_http
    server nginx 127.0.0.1:${SSH_WS_PORT} check

listen stats
    bind *:1936
    mode http
    stats enable
    stats uri /haproxy-stats
    stats refresh 10s
    stats realm HAProxy\ Statistics
    stats auth admin:vps@admin123
HAPROXYCFG

systemctl enable --quiet haproxy
systemctl restart haproxy
log "HAProxy running on port ${HAPROXY_PORT} (multiplexing SSH/XRay/NGINX)"

# ════════════════════════════════════════════════════════════════
step "STEP 9 — Squid HTTP Proxy"
# ════════════════════════════════════════════════════════════════
cat > /etc/squid/squid.conf <<SQUIDCONF
http_port ${SQUID_PORT}
http_port 3128

# Allow all — restrict later per-user with auth
acl all src 0.0.0.0/0
http_access allow all

# Basic settings
coredump_dir /var/spool/squid
access_log /var/log/squid/access.log
cache deny all
dns_v4_first on
forwarded_for delete
via off
SQUIDCONF

systemctl enable --quiet squid
systemctl restart squid
log "Squid HTTP proxy on ports 3128 and ${SQUID_PORT}"

# ════════════════════════════════════════════════════════════════
step "STEP 10 — SlowDNS Setup"
# ════════════════════════════════════════════════════════════════
mkdir -p /etc/slowdns
# Download slowdns binary
SDNS_URL="https://github.com/Snawoot/doh-proxy/releases/latest/download/doh-proxy-linux-amd64"
# Fallback: use iodine (DNS tunnel) which is in Ubuntu repos
apt-get install -y -qq iodine 2>/dev/null

# Generate SlowDNS keypair using openssl ECDH simulation
SLOWDNS_KEY=$(openssl rand -hex 16)
SLOWDNS_PUB=$(openssl rand -hex 16)
echo "SLOWDNS_KEY=${SLOWDNS_KEY}" >> /etc/vps-config
echo "SLOWDNS_PUB=${SLOWDNS_PUB}" >> /etc/vps-config

# SlowDNS systemd wrapper using DNS-over-UDP relay
cat > /etc/systemd/system/slowdns.service <<SDNS_SVC
[Unit]
Description=SlowDNS Tunnel Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/sbin/iodined -f -c -P ${SLOWDNS_KEY} 10.99.0.1 tunnel.${DOMAIN}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SDNS_SVC
systemctl daemon-reload
systemctl enable --quiet slowdns 2>/dev/null
# Note: iodine requires DNS delegation — start manually after DNS is configured
log "SlowDNS (iodine) configured. Start after delegating NS records to: ${PUBLIC_IP}"

# ════════════════════════════════════════════════════════════════
step "STEP 11 — ZiVPN WebSocket"
# ════════════════════════════════════════════════════════════════
# ZiVPN uses a Python WebSocket relay over SSH
pip3 install websockets asyncio 2>/dev/null

cat > /usr/local/bin/zivpn-ws.py <<ZIPY
#!/usr/bin/env python3
"""ZiVPN WebSocket-SSH relay"""
import asyncio, websockets, socket, sys

RELAY_HOST = "127.0.0.1"
RELAY_PORT = 22
LISTEN_PORT = ${ZIVPN_PORT}

async def handle(ws, path):
    try:
        sock = socket.socket()
        sock.connect((RELAY_HOST, RELAY_PORT))
        sock.setblocking(False)
        loop = asyncio.get_event_loop()
        async def fwd_to_ssh():
            while True:
                try:
                    data = await ws.recv()
                    await loop.sock_sendall(sock, data if isinstance(data,bytes) else data.encode())
                except Exception:
                    break
        async def fwd_from_ssh():
            while True:
                try:
                    data = await loop.sock_recv(sock, 4096)
                    if not data: break
                    await ws.send(data)
                except Exception:
                    break
        await asyncio.gather(fwd_to_ssh(), fwd_from_ssh())
    except Exception as e:
        pass
    finally:
        sock.close()

async def main():
    async with websockets.serve(handle, "0.0.0.0", LISTEN_PORT, ping_interval=None):
        print(f"ZiVPN WebSocket relay on port {LISTEN_PORT}")
        await asyncio.Future()

asyncio.run(main())
ZIPY
chmod +x /usr/local/bin/zivpn-ws.py

cat > /etc/systemd/system/zivpn.service <<ZISVC
[Unit]
Description=ZiVPN WebSocket SSH Relay
After=network.target ssh.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/zivpn-ws.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
ZISVC
systemctl daemon-reload
systemctl enable --quiet zivpn
systemctl restart zivpn
log "ZiVPN WebSocket relay on port ${ZIVPN_PORT}"

# ════════════════════════════════════════════════════════════════
step "STEP 12 — WS-ePRO (HTTP Custom multi-split payload handler)"
# ════════════════════════════════════════════════════════════════
# WS-ePRO listens on port 80 AND 8880.
# Handles HTTP Custom's 3-part [split] payload correctly:
#   Part 1 (GET /cdn-cgi/trace)  → 200 OK, keep reading
#   Part 2 (UNLOCK + Upgrade)    → 101 Switching Protocols → SSH tunnel
#   Part 3 (Content-Length:9999) → never sent; CDN already tunneling
# Responds 101 IMMEDIATELY on seeing Upgrade header — no body read.
cat > /usr/local/bin/ws-epro.py <<'WSPY'
#!/usr/bin/env python3
"""
WS-ePRO — HTTP Custom multi-split payload proxy
Listens on port 80 and 8880, tunnels SSH via WebSocket upgrade.
"""
import asyncio
import sys

SSH_HOST = "127.0.0.1"
SSH_PORT  = 22
LISTEN_PORTS = [80, 8880]

R101 = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"\r\n"
)
R200 = b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
R200_CONN = b"HTTP/1.1 200 Connection established\r\n\r\n"


async def pipe(src_r, dst_w):
    """One-direction byte pipe."""
    try:
        while True:
            data = await src_r.read(32768)
            if not data:
                break
            dst_w.write(data)
            await dst_w.drain()
    except Exception:
        pass
    finally:
        try:
            dst_w.close()
        except Exception:
            pass


async def read_header(reader):
    """Read bytes until \\r\\n\\r\\n without consuming the body."""
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = await asyncio.wait_for(reader.read(4096), timeout=30)
        if not chunk:
            return None
        buf += chunk
        # Safety cap — if no header end in 64 KB, abort
        if len(buf) > 65536:
            return None
    return buf


def is_upgrade(header: bytes) -> bool:
    h = header.lower()
    return b"upgrade" in h or b"websocket" in h


def is_connect(header: bytes) -> bool:
    first = header.split(b"\r\n")[0].upper()
    return first.startswith(b"CONNECT ")


def is_probe(header: bytes) -> bool:
    """Detect CDN probe/trace requests that need a 200 keep-alive reply."""
    first = header.split(b"\r\n")[0].upper()
    return first.startswith(b"GET ") and (
        b"/CDN-CGI/" in first or b"TRACE" in first
    )


async def handle(reader, writer):
    peer = writer.get_extra_info("peername")
    try:
        while True:
            header = await read_header(reader)
            if header is None:
                return

            # ── Case 1: Upgrade / WebSocket / UNLOCK+upgrade → 101 ──
            if is_upgrade(header):
                writer.write(R101)
                await writer.drain()
                # Open SSH and pipe bidirectionally
                try:
                    sr, sw = await asyncio.open_connection(SSH_HOST, SSH_PORT)
                except Exception:
                    return
                await asyncio.gather(pipe(reader, sw), pipe(sr, writer))
                return

            # ── Case 2: CONNECT tunnel ──
            elif is_connect(header):
                writer.write(R200_CONN)
                await writer.drain()
                try:
                    sr, sw = await asyncio.open_connection(SSH_HOST, SSH_PORT)
                except Exception:
                    return
                await asyncio.gather(pipe(reader, sw), pipe(sr, writer))
                return

            # ── Case 3: CDN probe (GET /cdn-cgi/trace …) → 200, loop ──
            elif is_probe(header):
                writer.write(R200)
                await writer.drain()
                # Stay in loop — HTTP Custom sends next split request

            # ── Case 4: Anything else → 200, loop ──
            else:
                writer.write(R200)
                await writer.drain()

    except asyncio.TimeoutError:
        pass
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main():
    servers = []
    for port in LISTEN_PORTS:
        try:
            srv = await asyncio.start_server(handle, "0.0.0.0", port)
            servers.append(srv)
            print(f"[WS-ePRO] listening on port {port}", flush=True)
        except OSError as e:
            print(f"[WS-ePRO] cannot bind port {port}: {e}", flush=True)

    if not servers:
        print("[WS-ePRO] no ports available — exiting", flush=True)
        sys.exit(1)

    async with asyncio.TaskGroup() as tg:
        for srv in servers:
            tg.create_task(srv.serve_forever())


asyncio.run(main())
WSPY
chmod +x /usr/local/bin/ws-epro.py

cat > /etc/systemd/system/ws-epro.service <<WSESVC
[Unit]
Description=WS-ePRO HTTP Custom multi-split WebSocket-SSH proxy
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-epro.py
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
WSESVC
systemctl daemon-reload
systemctl enable --quiet ws-epro
systemctl restart ws-epro
log "WS-ePRO proxy on ports 80 and 8880 (HTTP Custom multi-split ready)"

# ════════════════════════════════════════════════════════════════
step "STEP 13 — SSH account management scripts"
# ════════════════════════════════════════════════════════════════
mkdir -p /etc/vps/accounts

# Create SSH account
cat > /usr/local/bin/ssh-add-user <<'SSHADD'
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
[[ -z "$1" || -z "$2" || -z "$3" ]] && {
    echo -e "${CYAN}Usage: ssh-add-user <username> <password> <days>${NC}"; exit 1; }
USERNAME=$1; PASSWORD=$2; DAYS=$3
useradd -M -s /bin/false -e "$(date -d "+${DAYS} days" +%Y-%m-%d)" "$USERNAME" 2>/dev/null
echo "$USERNAME:$PASSWORD" | chpasswd
echo "$(date +%Y-%m-%d) $USERNAME $DAYS" >> /etc/vps/accounts/ssh.db
echo -e "${GREEN}[✔] SSH account created:${NC}"
echo -e "  Username : ${WHITE}${USERNAME}${NC}"
echo -e "  Password : ${WHITE}${PASSWORD}${NC}"
echo -e "  Expires  : ${WHITE}$(date -d "+${DAYS} days" +%Y-%m-%d)${NC}"
SSHADD

# Delete SSH account
cat > /usr/local/bin/ssh-del-user <<'SSHDEL'
#!/bin/bash
[[ -z "$1" ]] && { echo "Usage: ssh-del-user <username>"; exit 1; }
userdel -f "$1" 2>/dev/null
sed -i "/ $1 /d" /etc/vps/accounts/ssh.db
echo "Account $1 deleted."
SSHDEL

# List SSH accounts
cat > /usr/local/bin/ssh-list-users <<'SSHLIST'
#!/bin/bash
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'
echo -e "${CYAN}══ Active SSH Accounts ══${NC}"
printf "%-20s %-15s %-12s %s\n" "Username" "Expiry" "Days Left" "Status"
echo "------------------------------------------------------------"
while IFS= read -r line; do
    USER=$(echo "$line" | awk '{print $2}')
    EXP=$(chage -l "$USER" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    if id "$USER" &>/dev/null; then
        DAYS=$(( ( $(date -d "$EXP" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
        STATUS="ACTIVE"
        [[ $DAYS -lt 0 ]] && STATUS="EXPIRED"
        printf "%-20s %-15s %-12s %s\n" "$USER" "$EXP" "${DAYS}d" "$STATUS"
    fi
done < /etc/vps/accounts/ssh.db 2>/dev/null
SSHLIST

chmod +x /usr/local/bin/ssh-add-user \
         /usr/local/bin/ssh-del-user \
         /usr/local/bin/ssh-list-users
log "SSH account management scripts installed."

# ════════════════════════════════════════════════════════════════
step "STEP 14 — Auto-remove expired accounts (cron)"
# ════════════════════════════════════════════════════════════════
cat > /usr/local/bin/clean-expired <<'CLEAN'
#!/bin/bash
while IFS= read -r line; do
    USER=$(echo "$line" | awk '{print $2}')
    EXP=$(chage -l "$USER" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
    if [[ -n "$EXP" ]]; then
        EXP_EPOCH=$(date -d "$EXP" +%s 2>/dev/null || echo 9999999999)
        NOW_EPOCH=$(date +%s)
        [[ $EXP_EPOCH -lt $NOW_EPOCH ]] && userdel -f "$USER" 2>/dev/null \
            && sed -i "/ $USER /d" /etc/vps/accounts/ssh.db
    fi
done < /etc/vps/accounts/ssh.db 2>/dev/null
CLEAN
chmod +x /usr/local/bin/clean-expired
(crontab -l 2>/dev/null; echo "0 * * * * /usr/local/bin/clean-expired") | crontab -
log "Expired account cleanup cron scheduled (hourly)."

# ════════════════════════════════════════════════════════════════
step "STEP 15 — Main interactive menu"
# ════════════════════════════════════════════════════════════════
source /etc/vps-config

cat > /usr/local/bin/menu <<MENUEOF
#!/bin/bash
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'
WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'
source /etc/vps-config 2>/dev/null

status(){ systemctl is-active "\$1" &>/dev/null \
    && echo -e "${GREEN}ON●${NC}" || echo -e "${RED}OFF●${NC}"; }

main_menu() {
    clear
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${YELLOW}${BOLD}      VPS AUTO SCRIPT PREMIUM — HTTP CUSTOM TUNNELING     ${NC}${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${GREEN}✦ OS      :${NC} \$(lsb_release -ds 2>/dev/null)"
    echo -e "${CYAN}║${NC}  ${GREEN}✦ IP      :${NC} \${PUBLIC_IP}"
    echo -e "${CYAN}║${NC}  ${GREEN}✦ Domain  :${NC} \${DOMAIN}"
    echo -e "${CYAN}║${NC}  ${GREEN}✦ Uptime  :${NC} \$(uptime -p)"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  SSH      : \$(status ssh)  WS-ePRO : \$(status ws-epro)  ZiVPN: \$(status zivpn)"
    echo -e "${CYAN}║${NC}  NGINX    : \$(status nginx)  Dropbear: \$(status dropbear)  XRay : \$(status xray)"
    echo -e "${CYAN}║${NC}  HAProxy  : \$(status haproxy)  UDP-GW  : \$(status badvpn-udpgw@${UDPGW_PORT1})  Squid: \$(status squid)"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}[01] MENU SSH${NC}          ${WHITE}[06] MENU TRIAL${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}[02] MENU VMESS${NC}        ${WHITE}[07] SPEEDTEST${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}[03] MENU VLESS${NC}        ${WHITE}[08] MENU UTILITY${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}[04] MENU TROJAN${NC}       ${WHITE}[09] MENU ZIVPN${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}[05] MENU SHADOWSOCKS${NC}  ${WHITE}[10] CEK VPS${NC}"
    echo -e "${CYAN}║${NC}  ${WHITE}[11] MENU SLOW DNS${NC}     ${WHITE}[00] EXIT${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    read -rp "Select menu: " OPT
    case \$OPT in
        01|1) menu_ssh ;;
        02|2) menu_vmess ;;
        03|3) menu_vless ;;
        04|4) menu_trojan ;;
        05|5) menu_ss ;;
        06|6) menu_trial ;;
        07|7) speedtest ;;
        08|8) menu_utility ;;
        09|9) menu_zivpn ;;
        10)   cek_vps ;;
        11)   menu_slowdns ;;
        00|0) exit 0 ;;
        *) main_menu ;;
    esac
}

menu_ssh() {
    clear
    echo -e "\${CYAN}═══ SSH / WS-ePRO MENU ═══\${NC}"
    echo -e "  [1] Add SSH Account"
    echo -e "  [2] Delete SSH Account"
    echo -e "  [3] List SSH Accounts"
    echo -e "  [4] Renew Account"
    echo -e "  [0] Back"
    read -rp "Option: " O
    case \$O in
        1) read -rp "Username: " U; read -rp "Password: " P; read -rp "Days: " D
           ssh-add-user "\$U" "\$P" "\$D"
           echo -e "\n\${CYAN}═══ SSH Config for HTTP Custom ═══\${NC}"
           echo -e "  Host     : \${DOMAIN}"
           echo -e "  Port     : 22 / 442 / 8880"
           echo -e "  Username : \$U"
           echo -e "  Password : \$P"
           echo -e "  Payload  : GET / HTTP/1.1[crlf]Host: \${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]"
           read -rp "Press Enter to continue..." ;;
        2) read -rp "Username: " U; ssh-del-user "\$U" ;;
        3) ssh-list-users; read -rp "Press Enter..." ;;
        4) read -rp "Username: " U; read -rp "Add days: " D
           chage -E "\$(date -d "+\${D} days" +%Y-%m-%d)" "\$U"
           echo "Renewed \$U for \$D days." ;;
        0) main_menu; return ;;
    esac
    menu_ssh
}

menu_vmess() {
    clear
    echo -e "\${CYAN}═══ VMESS WS+TLS ACCOUNT ═══\${NC}"
    UUID=\$(grep -A3 '"vmess"' /etc/xray/config.json | grep '"id"' | head -1 | cut -d'"' -f4)
    echo -e "  Address  : \${DOMAIN}"
    echo -e "  Port     : ${XRAY_WS_PORT}"
    echo -e "  UUID     : \${UUID}"
    echo -e "  AlterId  : 0"
    echo -e "  Network  : ws"
    echo -e "  Path     : /vmess-ws"
    echo -e "  TLS      : tls"
    echo ""
    # v2ray link
    VMESS_JSON=\$(echo -n "{\"v\":\"2\",\"ps\":\"VPS-VMESS\",\"add\":\"\${DOMAIN}\",\"port\":\"${XRAY_WS_PORT}\",\"id\":\"\${UUID}\",\"aid\":\"0\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\${DOMAIN}\",\"path\":\"/vmess-ws\",\"tls\":\"tls\"}" | base64 -w0)
    echo -e "  Link     : vmess://\${VMESS_JSON}"
    read -rp "Press Enter..."
    main_menu
}

menu_vless() {
    clear
    echo -e "\${CYAN}═══ VLESS gRPC+TLS ACCOUNT ═══\${NC}"
    UUID=\$(grep -A3 '"vless"' /etc/xray/config.json | grep '"id"' | head -1 | cut -d'"' -f4)
    echo -e "  Address  : \${DOMAIN}"
    echo -e "  Port     : ${XRAY_GRPC_PORT}"
    echo -e "  UUID     : \${UUID}"
    echo -e "  Network  : grpc"
    echo -e "  Service  : vless-grpc"
    echo -e "  TLS      : tls"
    echo ""
    echo -e "  Link     : vless://\${UUID}@\${DOMAIN}:${XRAY_GRPC_PORT}?type=grpc&serviceName=vless-grpc&security=tls#VPS-VLESS"
    read -rp "Press Enter..."
    main_menu
}

menu_trojan() {
    clear
    echo -e "\${CYAN}═══ TROJAN WS+TLS ACCOUNT ═══\${NC}"
    PASS=\$(grep -A3 '"trojan"' /etc/xray/config.json | grep '"password"' | head-1 | cut -d'"' -f4)
    echo -e "  Address  : \${DOMAIN}"
    echo -e "  Port     : 2087"
    echo -e "  Password : \${PASS}"
    echo -e "  Network  : ws"
    echo -e "  Path     : /trojan-ws"
    echo -e "  TLS      : tls"
    echo ""
    echo -e "  Link     : trojan://\${PASS}@\${DOMAIN}:2087?type=ws&path=/trojan-ws&security=tls#VPS-TROJAN"
    read -rp "Press Enter..."
    main_menu
}

menu_ss() {
    clear
    echo -e "\${CYAN}═══ SHADOWSOCKS ACCOUNT ═══\${NC}"
    SSPASS=\$(grep '"password"' /etc/xray/config.json | tail -1 | cut -d'"' -f4)
    echo -e "  Address  : \${DOMAIN}"
    echo -e "  Port     : 2096"
    echo -e "  Password : \${SSPASS}"
    echo -e "  Method   : chacha20-ietf-poly1305"
    read -rp "Press Enter..."
    main_menu
}

menu_trial() {
    clear
    echo -e "\${CYAN}═══ TRIAL ACCOUNT (1 day) ═══\${NC}"
    TUSER="trial\$(shuf -i 1000-9999 -n1)"
    TPASS=\$(openssl rand -hex 4)
    ssh-add-user "\$TUSER" "\$TPASS" 1
    echo -e "  This account expires in 24 hours."
    read -rp "Press Enter..."
    main_menu
}

speedtest() {
    clear
    echo -e "\${CYAN}Running speedtest...\${NC}"
    if command -v speedtest-cli &>/dev/null; then
        speedtest-cli
    elif command -v speedtest &>/dev/null; then
        speedtest
    else
        pip3 install speedtest-cli -q && speedtest-cli
    fi
    read -rp "Press Enter..."
    main_menu
}

menu_utility() {
    clear
    echo -e "\${CYAN}═══ UTILITY ═══\${NC}"
    echo -e "  [1] Restart all services"
    echo -e "  [2] Service status"
    echo -e "  [3] Change XRay UUID"
    echo -e "  [4] Firewall rules"
    echo -e "  [0] Back"
    read -rp "Option: " O
    case \$O in
        1) systemctl restart nginx haproxy xray dropbear zivpn ws-epro squid
           systemctl restart badvpn-udpgw@${UDPGW_PORT1} badvpn-udpgw@${UDPGW_PORT2}
           echo -e "\${GREEN}All services restarted.\${NC}" ;;
        2) systemctl status nginx xray haproxy dropbear zivpn ws-epro squid --no-pager 2>/dev/null | head -60 ;;
        3) NEW=\$(xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
           sed -i "s/\${UUID}/\${NEW}/g" /etc/xray/config.json
           systemctl restart xray; echo "New UUID: \$NEW" ;;
        4) iptables -L -n --line-numbers 2>/dev/null | head -40 ;;
        0) main_menu; return ;;
    esac
    read -rp "Press Enter..."
    menu_utility
}

menu_zivpn() {
    clear
    echo -e "\${CYAN}═══ ZiVPN WEBSOCKET ═══\${NC}"
    echo -e "  Type     : WebSocket SSH Relay"
    echo -e "  Address  : \${DOMAIN}"
    echo -e "  WS Port  : ${ZIVPN_PORT}"
    echo -e "  Status   : \$(status zivpn)"
    echo ""
    echo -e "  HTTP Custom Payload:"
    echo -e "  GET / HTTP/1.1[crlf]Host: \${DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]"
    read -rp "Press Enter..."
    main_menu
}

menu_slowdns() {
    clear
    echo -e "\${CYAN}═══ SLOW DNS SETUP ═══\${NC}"
    echo -e "  NS Record  : ns.tunnel → \${PUBLIC_IP}"
    echo -e "  DNS Port   : ${SLOWDNS_PORT}"
    echo -e "  Status     : \$(status slowdns)"
    echo ""
    echo -e "  [1] Start SlowDNS"
    echo -e "  [2] Stop SlowDNS"
    echo -e "  [0] Back"
    read -rp "Option: " O
    case \$O in
        1) systemctl start slowdns; echo "SlowDNS started." ;;
        2) systemctl stop slowdns; echo "SlowDNS stopped." ;;
        0) main_menu; return ;;
    esac
    read -rp "Press Enter..."
    menu_slowdns
}

cek_vps() {
    clear
    echo -e "\${CYAN}═══ VPS STATUS ═══\${NC}"
    echo -e "  Hostname  : \$(hostname)"
    echo -e "  OS        : \$(lsb_release -ds 2>/dev/null)"
    echo -e "  Kernel    : \$(uname -r)"
    echo -e "  CPU       : \$(grep 'model name' /proc/cpuinfo | head -1 | cut -d: -f2 | xargs)"
    echo -e "  Cores     : \$(nproc)"
    echo -e "  RAM       : \$(free -h | awk '/Mem:/{print \$3 "/" \$2}')"
    echo -e "  Disk      : \$(df -h / | awk 'NR==2{print \$3 "/" \$2 " (" \$5 ")"}')"
    echo -e "  Uptime    : \$(uptime -p)"
    echo -e "  Public IP : \${PUBLIC_IP}"
    echo ""
    echo -e "\${CYAN}═══ PORT STATUS ═══\${NC}"
    for PORT in 22 80 442 443 8080 8443 8444 8880 ${ZIVPN_PORT} ${UDPGW_PORT1} ${UDPGW_PORT2} 3128 2087 2096; do
        ss -tlnp | grep -q ":\$PORT " \
            && echo -e "  :\$PORT → \${GREEN}OPEN\${NC}" \
            || echo -e "  :\$PORT → \${RED}CLOSED\${NC}"
    done
    read -rp "Press Enter..."
    main_menu
}

main_menu
MENUEOF

chmod +x /usr/local/bin/menu
log "Interactive menu installed. Run: menu"

# ════════════════════════════════════════════════════════════════
step "STEP 16 — Firewall (UFW)"
# ════════════════════════════════════════════════════════════════
ufw --force reset 2>/dev/null
ufw default deny incoming 2>/dev/null
ufw default allow outgoing 2>/dev/null
# Allow all required ports
for PORT in 22 80 442 443 1936 2053 2087 2096 3128 7200 7300 7777 8080 8443 8444 8880 8888 5300; do
    ufw allow $PORT/tcp 2>/dev/null
done
ufw allow $UDPGW_PORT1/udp 2>/dev/null
ufw allow $UDPGW_PORT2/udp 2>/dev/null
ufw allow 5300/udp 2>/dev/null
ufw --force enable 2>/dev/null
log "Firewall configured."

# ════════════════════════════════════════════════════════════════
step "STEP 17 — SSH Banner"
# ════════════════════════════════════════════════════════════════
source /etc/vps-config
cat > /etc/issue.net <<BANNER

╔══════════════════════════════════════════════════╗
║        VPS AUTO SCRIPT PREMIUM TUNNELING        ║
╠══════════════════════════════════════════════════╣
║  Server  : ${DOMAIN}                             ║
║  Support : HTTP Custom / XRay / Dropbear         ║
╚══════════════════════════════════════════════════╝
BANNER

# Enable banner in SSH
sed -i 's/#Banner none/Banner \/etc\/issue.net/' /etc/ssh/sshd_config
systemctl restart ssh
log "SSH banner configured."

# ════════════════════════════════════════════════════════════════
step "STEP 18 — Final service restart & status"
# ════════════════════════════════════════════════════════════════
systemctl daemon-reload
for SVC in nginx haproxy xray dropbear zivpn ws-epro squid \
           "badvpn-udpgw@${UDPGW_PORT1}" "badvpn-udpgw@${UDPGW_PORT2}"; do
    systemctl restart "$SVC" 2>/dev/null
done

# ════════════════════════════════════════════════════════════════
banner
echo ""
echo -e "${GREEN}${BOLD}  INSTALLATION COMPLETE!${NC}"
echo ""
echo -e "${CYAN}  ╔══════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}  ║${NC}  ${YELLOW}SERVICE STATUS${NC}                              ${CYAN}║${NC}"
echo -e "${CYAN}  ╠══════════════════════════════════════════════╣${NC}"
for SVC in ssh nginx haproxy xray dropbear zivpn ws-epro squid; do
    ST=$(systemctl is-active $SVC 2>/dev/null)
    [[ "$ST" == "active" ]] \
        && echo -e "${CYAN}  ║${NC}  ${GREEN}●${NC} $(printf '%-12s' $SVC) : ${GREEN}ACTIVE${NC}           ${CYAN}║${NC}" \
        || echo -e "${CYAN}  ║${NC}  ${RED}●${NC} $(printf '%-12s' $SVC) : ${RED}INACTIVE${NC}         ${CYAN}║${NC}"
done
echo -e "${CYAN}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  ║${NC}  ${WHITE}PORTS SUMMARY${NC}                              ${CYAN}║${NC}"
echo -e "${CYAN}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  ║${NC}  SSH        → 22                            ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  Dropbear   → 442, 443                      ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  WS-ePRO   → 8880  (HTTP Upgrade)           ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  ZiVPN     → ${ZIVPN_PORT}  (WebSocket SSH)          ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  NGINX     → 80 (WS), 8080 (WSS)            ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  HAProxy   → 443 (SSL MUX)                  ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  VMESS-WS  → ${XRAY_WS_PORT}                         ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  VLESS-gRPC → ${XRAY_GRPC_PORT}                        ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  Trojan-WS → 2087                           ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  Shadowsocks → 2096                         ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  UDP-GW    → ${UDPGW_PORT1}, ${UDPGW_PORT2}                   ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  Squid     → 3128, ${SQUID_PORT}                   ${CYAN}║${NC}"
echo -e "${CYAN}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  ║${NC}  HTTP Custom Payload (WS-ePRO port 8880):   ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  GET / HTTP/1.1[crlf]                        ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  Host: ${DOMAIN}[crlf]                  ${CYAN}║${NC}"
echo -e "${CYAN}  ║${NC}  Upgrade: websocket[crlf][crlf]              ${CYAN}║${NC}"
echo -e "${CYAN}  ╠══════════════════════════════════════════════╣${NC}"
echo -e "${CYAN}  ║${NC}  ${YELLOW}Type 'menu' to manage accounts & services  ${NC}${CYAN}║${NC}"
echo -e "${CYAN}  ╚══════════════════════════════════════════════╝${NC}"
echo ""
