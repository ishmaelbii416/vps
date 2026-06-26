#!/bin/bash
# ================================================================
#   VPS PATCH — C-compiled ws-epro + VMESS fix
#   Run: bash <(curl -fsSL https://raw.githubusercontent.com/ishmaelbii416/vps/main/fix.sh)
# ================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; WHITE='\033[1;37m'; NC='\033[0m'; BOLD='\033[1m'

[[ $EUID -ne 0 ]] && { echo -e "${RED}Run as root!${NC}"; exit 1; }
log()  { echo -e "${GREEN}[✔]${NC} $1"; }
err()  { echo -e "${RED}[✘]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "\n${YELLOW}══ $1 ══${NC}"; }

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${BOLD}${YELLOW}     VPS PATCH — C ws-epro + VMESS + Diagnostic Fix        ${NC}${CYAN}║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"

source /etc/vps-config 2>/dev/null || { err "Run full install first."; exit 1; }

# ════════════════════════════════════════════════════════════════
step "1 — Kill everything on ports 80 / 8880"
# ════════════════════════════════════════════════════════════════
systemctl stop ws-epro nginx 2>/dev/null
fuser -k 80/tcp   2>/dev/null
fuser -k 8880/tcp 2>/dev/null
sleep 1
log "Ports cleared."

# ════════════════════════════════════════════════════════════════
step "2 — Write & compile C ws-epro"
# ════════════════════════════════════════════════════════════════
apt-get install -y -qq gcc 2>/dev/null

cat > /tmp/ws-epro.c <<'CSRC'
/*
 * ws-epro.c — HTTP Custom multi-split payload handler
 *
 * GET /cdn-cgi/...  →  HTTP/1.1 200 OK  (CDN probe, stay alive, loop)
 * ANYTHING ELSE     →  HTTP/1.1 101 Switching Protocols → SSH pipe
 *
 * CDN proxies strip Connection/Upgrade headers before reaching the origin.
 * The UNLOCK WebDAV method — or ANY non-probe request — is the tunnel signal.
 * We never read the body, never check Content-Length, never return 413.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define SSH_HOST  "127.0.0.1"
#define SSH_PORT  22
#define BACKLOG   4096
#define PIPEBUF   65536

static int PORTS[] = {80, 8880};
static int NPORTS  = 2;

static const char R101[] =
    "HTTP/1.1 101 Switching Protocols\r\n"
    "Upgrade: websocket\r\n"
    "Connection: Upgrade\r\n"
    "\r\n";

static const char R200[] =
    "HTTP/1.1 200 OK\r\n"
    "Content-Type: text/plain\r\n"
    "Content-Length: 2\r\n"
    "Connection: keep-alive\r\n"
    "\r\n"
    "OK";

static void nodelay(int fd) {
    int f = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &f, sizeof f);
}

/* Bidirectional pipe until either side closes */
static void bridge(int a, int b) {
    char buf[PIPEBUF];
    fd_set r;
    int mx = (a > b ? a : b) + 1;
    while (1) {
        FD_ZERO(&r); FD_SET(a,&r); FD_SET(b,&r);
        if (select(mx, &r, NULL, NULL, NULL) < 0) break;
        if (FD_ISSET(a,&r)) {
            ssize_t n = recv(a, buf, sizeof buf, 0);
            if (n <= 0) break;
            if (send(b, buf, n, MSG_NOSIGNAL) < 0) break;
        }
        if (FD_ISSET(b,&r)) {
            ssize_t n = recv(b, buf, sizeof buf, 0);
            if (n <= 0) break;
            if (send(a, buf, n, MSG_NOSIGNAL) < 0) break;
        }
    }
}

static int ssh_connect(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET;
    sa.sin_port   = htons(SSH_PORT);
    sa.sin_addr.s_addr = inet_addr(SSH_HOST);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) < 0) { close(fd); return -1; }
    nodelay(fd);
    return fd;
}

static void *handle(void *arg) {
    int cfd = *(int *)arg;
    free(arg);
    pthread_detach(pthread_self());
    nodelay(cfd);

    while (1) {
        /* Read one HTTP header block byte-by-byte until \r\n\r\n */
        char hdr[8192]; int hlen = 0; int ok = 0;
        while (hlen < (int)sizeof(hdr)-1) {
            ssize_t n = recv(cfd, hdr+hlen, 1, 0);
            if (n <= 0) goto done;
            hlen++;
            if (hlen >= 4 &&
                hdr[hlen-4]=='\r' && hdr[hlen-3]=='\n' &&
                hdr[hlen-2]=='\r' && hdr[hlen-1]=='\n') { ok=1; break; }
        }
        if (!ok) goto done;
        hdr[hlen] = '\0';

        /* Extract first line, uppercase */
        char fl[256]={0}; int i;
        for (i=0; i<hlen && i<255 && hdr[i]!='\r' && hdr[i]!='\n'; i++)
            fl[i] = (hdr[i]>='a'&&hdr[i]<='z') ? hdr[i]-32 : hdr[i];

        /* CDN probe: GET /cdn-cgi/ → 200, loop for next split */
        if (strncmp(fl,"GET ",4)==0 &&
            (strstr(fl,"/CDN-CGI")||strstr(fl,"TRACE"))) {
            send(cfd, R200, sizeof R200 - 1, MSG_NOSIGNAL);
            continue;  /* read next HTTP request on same connection */
        }

        /* Everything else → 101 + SSH tunnel */
        send(cfd, R101, sizeof R101 - 1, MSG_NOSIGNAL);
        int sfd = ssh_connect();
        if (sfd < 0) goto done;
        bridge(cfd, sfd);
        close(sfd);
        goto done;
    }
done:
    close(cfd);
    return NULL;
}

static void *listen_thread(void *arg) {
    int port = *(int *)arg; free(arg);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) return NULL;
    int on = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
    setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof on);
    struct sockaddr_in sa = {0};
    sa.sin_family = AF_INET; sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port = htons(port);
    if (bind(lfd,(struct sockaddr*)&sa,sizeof sa)<0) {
        fprintf(stderr,"[ws-epro] bind :%d failed: %s\n",port,strerror(errno));
        close(lfd); return NULL;
    }
    listen(lfd, BACKLOG);
    printf("[ws-epro] listening on :%d\n", port); fflush(stdout);

    while (1) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) continue;
        int *p = malloc(sizeof(int)); if (!p){close(cfd);continue;} *p=cfd;
        pthread_t t; pthread_create(&t,NULL,handle,p);
    }
}

int main(void) {
    signal(SIGPIPE, SIG_IGN);
    for (int i=0; i<NPORTS; i++) {
        int *p = malloc(sizeof(int)); *p = PORTS[i];
        pthread_t t; pthread_create(&t,NULL,listen_thread,p); pthread_detach(t);
    }
    printf("[ws-epro] C binary running. GET /cdn-cgi→200, else→101+SSH\n");
    fflush(stdout);
    while (1) sleep(3600);
}
CSRC

gcc -O2 -o /usr/local/bin/ws-epro /tmp/ws-epro.c -lpthread 2>&1 && \
    log "ws-epro C binary compiled → /usr/local/bin/ws-epro" || \
    { err "Compilation failed"; exit 1; }

chmod +x /usr/local/bin/ws-epro

# ════════════════════════════════════════════════════════════════
step "3 — Install ws-epro systemd service"
# ════════════════════════════════════════════════════════════════
# Remove old Python ws-epro
rm -f /usr/local/bin/ws-epro.py

cat > /etc/systemd/system/ws-epro.service <<'SVC'
[Unit]
Description=ws-epro C binary — HTTP Custom SSH tunnel proxy
After=network.target
Before=nginx.service

[Service]
Type=simple
ExecStart=/usr/local/bin/ws-epro
Restart=always
RestartSec=2
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable --quiet ws-epro
systemctl start ws-epro
sleep 2
systemctl is-active ws-epro --quiet && log "ws-epro service ACTIVE" \
    || { err "ws-epro failed to start — check: journalctl -u ws-epro -n 20"; }

# ════════════════════════════════════════════════════════════════
step "4 — Self-test: verify port 80 returns 101 on UNLOCK"
# ════════════════════════════════════════════════════════════════
echo -e "${CYAN}Testing UNLOCK → 101...${NC}"
RESP=$(printf 'UNLOCK /? HTTP/1.1\r\nHost: %s\r\n\r\n' "${DOMAIN}" \
       | timeout 3 nc -q1 127.0.0.1 80 2>/dev/null | head -1)
echo -e "  Port 80   response: ${WHITE}${RESP:-<no response>}${NC}"

if echo "$RESP" | grep -q "101"; then
    log "✓ Port 80 returns 101 on UNLOCK — HTTP Custom will work!"
else
    err "Port 80 not returning 101. Diagnosing..."
    echo -e "  What is on port 80:"
    ss -tlnp | grep ':80 ' || echo "  NOTHING on port 80!"
    echo -e "  ws-epro status:"
    systemctl status ws-epro --no-pager -l | tail -10
fi

echo -e "${CYAN}Testing CDN probe (GET /cdn-cgi/trace) → 200...${NC}"
RESP2=$(printf 'GET /cdn-cgi/trace HTTP/1.1\r\nHost: %s\r\n\r\n' "${DOMAIN}" \
        | timeout 3 nc -q1 127.0.0.1 80 2>/dev/null | head -1)
echo -e "  Port 80   response: ${WHITE}${RESP2:-<no response>}${NC}"
echo "$RESP2" | grep -q "200" && log "✓ CDN probe returns 200 correctly" \
    || warn "CDN probe not returning 200"

echo -e "${CYAN}Testing port 8880...${NC}"
RESP3=$(printf 'UNLOCK /? HTTP/1.1\r\nHost: %s\r\n\r\n' "${DOMAIN}" \
        | timeout 3 nc -q1 127.0.0.1 8880 2>/dev/null | head -1)
echo -e "  Port 8880 response: ${WHITE}${RESP3:-<no response>}${NC}"
echo "$RESP3" | grep -q "101" && log "✓ Port 8880 OK" || warn "Port 8880 not responding"

# ════════════════════════════════════════════════════════════════
step "5 — Fix NGINX (off port 80, on 8181)"
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
        return 200 'ws-epro OK';
        add_header Content-Type text/plain;
    }
}

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

nginx -t 2>/dev/null && systemctl restart nginx && log "NGINX on 8181/8080" \
    || err "NGINX config error — run: nginx -t"

# ════════════════════════════════════════════════════════════════
step "6 — Update XRay VMESS/VLESS/Trojan (proper WS paths)"
# ════════════════════════════════════════════════════════════════
VMESS_UUID=$(grep -A3 '"vmess"' /etc/xray/config.json 2>/dev/null | grep '"id"' | head -1 | cut -d'"' -f4)
VLESS_UUID=$(grep -A3 '"vless"' /etc/xray/config.json 2>/dev/null | grep '"id"' | head -1 | cut -d'"' -f4)
TROJAN_PASS=$(grep '"password"' /etc/xray/config.json 2>/dev/null | head -1 | cut -d'"' -f4)
SS_PASS=$(grep '"password"' /etc/xray/config.json 2>/dev/null | tail -1 | cut -d'"' -f4)
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
      }
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

systemctl restart xray && log "XRay restarted" || err "XRay failed"

# Save credentials
grep -v 'VMESS_UUID\|VLESS_UUID\|TROJAN_PASS\|SS_PASS' /etc/vps-config > /tmp/vps-config.tmp
{
    echo "VMESS_UUID=${VMESS_UUID}"
    echo "VLESS_UUID=${VLESS_UUID}"
    echo "TROJAN_PASS=${TROJAN_PASS}"
    echo "SS_PASS=${SS_PASS}"
} >> /tmp/vps-config.tmp
mv /tmp/vps-config.tmp /etc/vps-config

# ════════════════════════════════════════════════════════════════
step "7 — Final port status"
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
echo -e "${CYAN}  ┌─ SSH / HTTP Custom ─────────────────────────────────┐${NC}"
echo -e "${CYAN}  │${NC}  Host    : ${WHITE}${DOMAIN}${NC}"
echo -e "${CYAN}  │${NC}  Port    : ${WHITE}22${NC}"
echo -e "${CYAN}  │${NC}  Proxy   : ${WHITE}imagedelivery.net:80${NC} (CDN bug host)"
echo -e "${CYAN}  │${NC}  Payload :"
echo -e "${CYAN}  │${NC}    GET /cdn-cgi/trace HTTP/1.1[crlf]"
echo -e "${CYAN}  │${NC}    Host: [bug-host][crlf][crlf][split]"
echo -e "${CYAN}  │${NC}    UNLOCK /? HTTP/1.1[crlf]"
echo -e "${CYAN}  │${NC}    Host: ${DOMAIN}[crlf]"
echo -e "${CYAN}  │${NC}    Upgrade: websocket[crlf][crlf][split]"
echo -e "${CYAN}  │${NC}    UNLOCK /? HTTP/1.1[crlf]"
echo -e "${CYAN}  │${NC}    Host: [bug-host][crlf]"
echo -e "${CYAN}  │${NC}    Content-Length: 999999999999[crlf]"
echo -e "${CYAN}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${CYAN}  ┌─ VMESS client config ───────────────────────────────┐${NC}"
echo -e "${CYAN}  │${NC}  bug host : ${WHITE}imagedelivery.net${NC}  port: ${WHITE}443${NC}"
echo -e "${CYAN}  │${NC}  SNI/Host : ${WHITE}${DOMAIN}${NC}"
echo -e "${CYAN}  │${NC}  UUID     : ${WHITE}${VMESS_UUID}${NC}"
echo -e "${CYAN}  │${NC}  alterId  : 0   security: auto   level: 8"
echo -e "${CYAN}  │${NC}  network  : ws  path: /vmess/"
echo -e "${CYAN}  │${NC}  TLS      : tls allowInsecure: true"
echo -e "${CYAN}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${CYAN}  ┌─ VLESS ─────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}  │${NC}  UUID: ${WHITE}${VLESS_UUID}${NC}  path: /vless/  network: ws"
echo -e "${CYAN}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${CYAN}  ┌─ Trojan ────────────────────────────────────────────┐${NC}"
echo -e "${CYAN}  │${NC}  Pass: ${WHITE}${TROJAN_PASS}${NC}  path: /trojan/  network: ws"
echo -e "${CYAN}  └──────────────────────────────────────────────────────┘${NC}"
echo ""
echo -e "${YELLOW}  ⚠  ${DOMAIN} must be Cloudflare-proxied (🟠 orange cloud)${NC}"
echo -e "${YELLOW}     for CDN bug tunneling to work on port 80.${NC}"
echo ""
