#!/bin/bash
# ================================================================
#   VPS PATCH SCRIPT — Apply ws-epro + NGINX fix without reinstall
#   Fixes: 413 Request Entity Too Large on HTTP Custom tunneling
#   Run  : bash <(curl -fsSL https://raw.githubusercontent.com/ishmaelbii416/vps/main/fix.sh)
# ================================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root!${NC}"; exit 1; }

log()  { echo -e "${GREEN}[✔]${NC} $1"; }
info() { echo -e "${CYAN}[…]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; }
step() { echo -e "\n${YELLOW}══ $1 ══${NC}"; }

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${BOLD}${YELLOW}    VPS PATCH — HTTP Custom 413 Fix (ws-epro + NGINX)      ${NC}${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

# ── Load config ────────────────────────────────────────────────
source /etc/vps-config 2>/dev/null || {
    err "/etc/vps-config missing — run the full install first."
    exit 1
}

# ════════════════════════════════════════════════════════════════
step "1 — Stop ws-epro"
# ════════════════════════════════════════════════════════════════
systemctl stop ws-epro 2>/dev/null
# Free port 80 if nginx was squatting it
systemctl stop nginx 2>/dev/null
sleep 1
log "Services stopped."

# ════════════════════════════════════════════════════════════════
step "2 — Install fixed ws-epro (port 80 + 8880, UNLOCK→101)"
# ════════════════════════════════════════════════════════════════
cat > /usr/local/bin/ws-epro.py <<'WSPY'
#!/usr/bin/env python3
"""
WS-ePRO — HTTP Custom multi-split payload proxy (patched)
=========================================================
Root cause of 413:
  Cloudflare/CDN strips hop-by-hop headers (Connection, Upgrade) before
  forwarding to the origin.  The UNLOCK method itself is the tunnel signal —
  not the Upgrade header.  Any UNLOCK request must immediately return 101 so
  the CDN treats the connection as a raw TCP tunnel from that point on.

Payload flow HTTP Custom sends:
  [split 1]  GET /cdn-cgi/trace ...          → 200 OK  (CDN probe, loop)
  [split 2]  UNLOCK /? ... Upgrade:websocket → 101     (tunnel opens)
  [split 3]  UNLOCK /? ... Content-Length:9e12         (never reaches us;
                                                         CDN already tunneling)
"""

import asyncio
import sys

SSH_HOST     = "127.0.0.1"
SSH_PORT     = 22
LISTEN_PORTS = [80, 8880]

# ── Canned responses ──────────────────────────────────────────
R101 = (
    b"HTTP/1.1 101 Switching Protocols\r\n"
    b"Upgrade: websocket\r\n"
    b"Connection: Upgrade\r\n"
    b"\r\n"
)
R200_PROBE = (
    b"HTTP/1.1 200 OK\r\n"
    b"Content-Type: text/plain\r\n"
    b"Content-Length: 2\r\n"
    b"Connection: keep-alive\r\n"
    b"\r\n"
    b"OK"
)
R200_CONN = b"HTTP/1.1 200 Connection established\r\n\r\n"


# ── Helpers ───────────────────────────────────────────────────
async def read_header(reader: asyncio.StreamReader) -> bytes | None:
    """Read exactly one HTTP request header block (up to \\r\\n\\r\\n)."""
    buf = b""
    try:
        while b"\r\n\r\n" not in buf:
            chunk = await asyncio.wait_for(reader.read(4096), timeout=30)
            if not chunk:
                return None
            buf += chunk
            if len(buf) > 65536:   # safety cap — malformed request
                return None
    except asyncio.TimeoutError:
        return None
    return buf


def first_line(header: bytes) -> bytes:
    return header.split(b"\r\n")[0].upper()


def is_tunnel_trigger(header: bytes) -> bool:
    """
    True when the request should open the SSH tunnel (respond 101).

    Two signals — either is sufficient:
      1. WebDAV verb (UNLOCK, PROPFIND, MOVE, COPY, LOCK, MKCOL)
         CDNs strip Connection/Upgrade but leave the method intact.
      2. 'Upgrade' or 'websocket' header present (direct / non-CDN path).
    """
    fl = first_line(header)
    # WebDAV tunnel-trigger verbs
    if fl.startswith((
        b"UNLOCK ",   b"PROPFIND ", b"MOVE ",
        b"COPY ",     b"LOCK ",     b"MKCOL ",
    )):
        return True
    # Explicit WebSocket upgrade (direct connection, no CDN stripping)
    h = header.lower()
    if b"upgrade" in h or b"websocket" in h:
        return True
    return False


def is_connect(header: bytes) -> bool:
    return first_line(header).startswith(b"CONNECT ")


def is_probe(header: bytes) -> bool:
    """CDN liveness / trace probes — reply 200 and stay alive."""
    fl = first_line(header)
    return fl.startswith(b"GET ") and (
        b"/CDN-CGI/" in fl or b"/TRACE" in fl or b"TRACE " in fl
    )


# ── Pipe ─────────────────────────────────────────────────────
async def pipe(src: asyncio.StreamReader, dst: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await src.read(32768)
            if not data:
                break
            dst.write(data)
            await dst.drain()
    except Exception:
        pass
    finally:
        try:
            dst.close()
        except Exception:
            pass


# ── Connection handler ────────────────────────────────────────
async def handle(reader: asyncio.StreamReader,
                 writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            header = await read_header(reader)
            if header is None:
                return

            # ── UNLOCK / WebDAV / Upgrade → open SSH tunnel (101) ──
            if is_tunnel_trigger(header):
                writer.write(R101)
                await writer.drain()
                try:
                    sr, sw = await asyncio.open_connection(SSH_HOST, SSH_PORT)
                except OSError:
                    return
                # Bidirectional pipe; whichever direction closes ends both
                await asyncio.gather(pipe(reader, sw), pipe(sr, writer))
                return

            # ── CONNECT → open SSH tunnel (200) ──
            elif is_connect(header):
                writer.write(R200_CONN)
                await writer.drain()
                try:
                    sr, sw = await asyncio.open_connection(SSH_HOST, SSH_PORT)
                except OSError:
                    return
                await asyncio.gather(pipe(reader, sw), pipe(sr, writer))
                return

            # ── GET /cdn-cgi/trace (probe) → 200, stay alive, loop ──
            elif is_probe(header):
                writer.write(R200_PROBE)
                await writer.drain()
                # Stay in the loop — HTTP Custom sends the next split

            # ── Any other GET/POST/etc → 200, stay alive, loop ──
            else:
                writer.write(R200_PROBE)
                await writer.drain()

    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


# ── Server bootstrap ─────────────────────────────────────────
async def main() -> None:
    servers: list[asyncio.Server] = []
    for port in LISTEN_PORTS:
        try:
            srv = await asyncio.start_server(handle, "0.0.0.0", port)
            servers.append(srv)
            print(f"[ws-epro] listening on :{port}", flush=True)
        except OSError as exc:
            print(f"[ws-epro] cannot bind :{port} — {exc}", flush=True)

    if not servers:
        print("[ws-epro] no ports bound — exiting", flush=True)
        sys.exit(1)

    async with asyncio.TaskGroup() as tg:
        for srv in servers:
            tg.create_task(srv.serve_forever())


asyncio.run(main())
WSPY
chmod +x /usr/local/bin/ws-epro.py
log "ws-epro.py written."

# ════════════════════════════════════════════════════════════════
step "3 — Patch NGINX (client_max_body_size 0, move off port 80)"
# ════════════════════════════════════════════════════════════════
# ws-epro owns port 80; NGINX moves to 8181 (internal WS router)
cat > /etc/nginx/conf.d/vps-tunnel.conf <<NGINXCONF
# ── Internal WebSocket path router ──────────────────────────────
server {
    listen 8181;
    server_name ${DOMAIN} _;

    client_max_body_size 0;
    proxy_request_buffering off;

    location /ssh-ws {
        proxy_pass http://127.0.0.1:22;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
    location /dropbear-ws {
        proxy_pass http://127.0.0.1:442;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }
    location /vmess-ws {
        proxy_pass http://127.0.0.1:8443;
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

# ── WSS / TLS WebSocket (port 8080) ─────────────────────────────
server {
    listen 8080 ssl;
    server_name ${DOMAIN} _;

    ssl_certificate     /etc/xray/ssl/cert.crt;
    ssl_certificate_key /etc/xray/ssl/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    client_max_body_size 0;
    proxy_request_buffering off;

    location /ssh-ws {
        proxy_pass http://127.0.0.1:22;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_read_timeout 3600s;
    }
    location /vmess-ws {
        proxy_pass http://127.0.0.1:8443;
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
log "NGINX config patched (off port 80, client_max_body_size 0)."

# ════════════════════════════════════════════════════════════════
step "4 — Patch ws-epro systemd unit"
# ════════════════════════════════════════════════════════════════
cat > /etc/systemd/system/ws-epro.service <<WSESVC
[Unit]
Description=WS-ePRO HTTP Custom multi-split WebSocket-SSH proxy
After=network.target
# Must start BEFORE nginx so it can claim port 80
Before=nginx.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/ws-epro.py
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
WSESVC
systemctl daemon-reload
log "systemd unit updated."

# ════════════════════════════════════════════════════════════════
step "5 — Start services in correct order"
# ════════════════════════════════════════════════════════════════
systemctl start ws-epro
sleep 2
nginx -t 2>/dev/null && systemctl start nginx || {
    err "NGINX config error — check: nginx -t"
}

# ════════════════════════════════════════════════════════════════
step "6 — Verify ports"
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${CYAN}  Port status after patch:${NC}"
for PORT in 22 80 442 443 8080 8181 8443 8444 8880; do
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
        echo -e "  ${GREEN}●${NC} :${PORT} OPEN"
    else
        echo -e "  ${RED}●${NC} :${PORT} CLOSED"
    fi
done

echo ""
echo -e "${CYAN}  Service status:${NC}"
for SVC in ws-epro nginx haproxy xray dropbear; do
    ST=$(systemctl is-active "$SVC" 2>/dev/null)
    [[ "$ST" == "active" ]] \
        && echo -e "  ${GREEN}●${NC} ${SVC}: ACTIVE" \
        || echo -e "  ${RED}●${NC} ${SVC}: INACTIVE"
done

# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${GREEN}${BOLD}  PATCH APPLIED SUCCESSFULLY!${NC}"
echo ""
echo -e "${CYAN}  HTTP Custom config:${NC}"
echo -e "  SSH Host  : ${DOMAIN}"
echo -e "  Port      : 22"
echo -e "  Proxy     : (your CDN bug host):80"
echo -e ""
echo -e "  ${WHITE}Payload:${NC}"
echo -e "  GET /cdn-cgi/trace HTTP/1.1[crlf]Host: [proxy][crlf][crlf]"
echo -e "  [split]"
echo -e "  UNLOCK /? HTTP/1.1[crlf]Host: ${DOMAIN}[crlf]"
echo -e "  Connection: upgrade[crlf]User-Agent: [ua][crlf]"
echo -e "  Upgrade: websocket[crlf][crlf]"
echo -e "  [split]"
echo -e "  UNLOCK /? HTTP/1.1[crlf]Host: [proxy][crlf]"
echo -e "  Content-Length: 999999999999[crlf]"
echo ""
echo -e "  ${YELLOW}Expected: HTTP/1.1 101 Switching Protocols → SSH connects${NC}"
echo ""
