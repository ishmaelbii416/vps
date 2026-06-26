/*
 * ws-epro.c — HTTP Custom WebSocket-SSH tunnel proxy
 *
 * Logic:
 *   GET /cdn-cgi/...  →  HTTP/1.1 200 OK  (CDN liveness probe, stay alive)
 *   ANYTHING ELSE     →  HTTP/1.1 101 Switching Protocols → raw SSH pipe
 *
 * CDN proxies (Cloudflare) strip Connection/Upgrade headers before reaching
 * the origin, so we cannot rely on seeing "Upgrade: websocket". The UNLOCK
 * WebDAV method — or any non-probe request — is the tunnel signal.
 *
 * Compile:
 *   gcc -O2 -o ws-epro ws-epro.c -lpthread
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

/* ── Configuration ────────────────────────────────────────────── */
#define SSH_HOST   "127.0.0.1"
#define SSH_PORT   22
#define BACKLOG    4096
#define BUF        65536

static int listen_ports[] = {80, 8880};
static int n_ports = 2;

/* ── Canned responses ──────────────────────────────────────────── */
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

/* ── Helpers ──────────────────────────────────────────────────── */
static void set_tcp_nodelay(int fd) {
    int flag = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &flag, sizeof(flag));
}

/* Bidirectional pipe between two fds until either closes */
static void bridge(int a, int b) {
    fd_set fds;
    char buf[BUF];
    int maxfd = (a > b ? a : b) + 1;

    while (1) {
        FD_ZERO(&fds);
        FD_SET(a, &fds);
        FD_SET(b, &fds);

        if (select(maxfd, &fds, NULL, NULL, NULL) < 0)
            break;

        if (FD_ISSET(a, &fds)) {
            ssize_t n = recv(a, buf, sizeof(buf), 0);
            if (n <= 0) break;
            if (send(b, buf, n, MSG_NOSIGNAL) < 0) break;
        }
        if (FD_ISSET(b, &fds)) {
            ssize_t n = recv(b, buf, sizeof(buf), 0);
            if (n <= 0) break;
            if (send(a, buf, n, MSG_NOSIGNAL) < 0) break;
        }
    }
}

/* Connect to local SSH */
static int connect_ssh(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in sa = {0};
    sa.sin_family      = AF_INET;
    sa.sin_port        = htons(SSH_PORT);
    sa.sin_addr.s_addr = inet_addr(SSH_HOST);

    if (connect(fd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        close(fd);
        return -1;
    }
    set_tcp_nodelay(fd);
    return fd;
}

/* ── Per-connection handler (runs in a thread) ────────────────── */
typedef struct { int client_fd; } conn_t;

static void *handle(void *arg) {
    conn_t *c = (conn_t *)arg;
    int cfd = c->client_fd;
    free(c);

    pthread_detach(pthread_self());
    set_tcp_nodelay(cfd);

    /* Read HTTP request(s) in a loop (multi-split payload) */
    while (1) {
        char hdr[8192];
        int  hlen = 0;
        int  found = 0;

        /* Read until blank line (\r\n\r\n) */
        while (hlen < (int)sizeof(hdr) - 1) {
            ssize_t n = recv(cfd, hdr + hlen, 1, 0);
            if (n <= 0) goto done;
            hlen++;
            hdr[hlen] = '\0';
            if (hlen >= 4 &&
                hdr[hlen-4] == '\r' && hdr[hlen-3] == '\n' &&
                hdr[hlen-2] == '\r' && hdr[hlen-1] == '\n') {
                found = 1;
                break;
            }
        }
        if (!found) goto done;

        /* Check first line — uppercase for case-insensitive compare */
        int is_probe = 0;
        char upper[256] = {0};
        int i;
        for (i = 0; i < hlen && i < 255 && hdr[i] != '\r' && hdr[i] != '\n'; i++)
            upper[i] = (hdr[i] >= 'a' && hdr[i] <= 'z')
                       ? hdr[i] - 32 : hdr[i];

        /* CDN probe: GET /cdn-cgi/ OR GET with /trace */
        if (strncmp(upper, "GET ", 4) == 0 &&
            (strstr(upper, "/CDN-CGI") || strstr(upper, "/TRACE"))) {
            is_probe = 1;
        }

        if (is_probe) {
            /* 200 OK — stay alive, read next split */
            send(cfd, R200, strlen(R200), MSG_NOSIGNAL);
            continue;
        }

        /* Everything else → 101, open SSH, bridge */
        send(cfd, R101, strlen(R101), MSG_NOSIGNAL);

        int sfd = connect_ssh();
        if (sfd < 0) goto done;

        bridge(cfd, sfd);
        close(sfd);
        goto done;
    }

done:
    close(cfd);
    return NULL;
}

/* ── Per-port listener (runs in a thread) ─────────────────────── */
static void *listen_on(void *arg) {
    int port = *(int *)arg;
    free(arg);

    int lfd = socket(AF_INET, SOCK_STREAM, 0);
    if (lfd < 0) { perror("socket"); return NULL; }

    int opt = 1;
    setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));
    setsockopt(lfd, SOL_SOCKET, SO_REUSEPORT, &opt, sizeof(opt));

    struct sockaddr_in sa = {0};
    sa.sin_family      = AF_INET;
    sa.sin_addr.s_addr = INADDR_ANY;
    sa.sin_port        = htons(port);

    if (bind(lfd, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
        fprintf(stderr, "[ws-epro] cannot bind :%d — %s\n", port, strerror(errno));
        close(lfd);
        return NULL;
    }
    listen(lfd, BACKLOG);
    printf("[ws-epro] listening on :%d\n", port);
    fflush(stdout);

    while (1) {
        int cfd = accept(lfd, NULL, NULL);
        if (cfd < 0) continue;

        conn_t *c = malloc(sizeof(conn_t));
        if (!c) { close(cfd); continue; }
        c->client_fd = cfd;

        pthread_t tid;
        if (pthread_create(&tid, NULL, handle, c) != 0) {
            free(c);
            close(cfd);
        }
    }
    return NULL;
}

/* ── main ─────────────────────────────────────────────────────── */
int main(void) {
    signal(SIGPIPE, SIG_IGN);
    signal(SIGCHLD, SIG_IGN);

    for (int i = 0; i < n_ports; i++) {
        int *p = malloc(sizeof(int));
        *p = listen_ports[i];
        pthread_t tid;
        pthread_create(&tid, NULL, listen_on, p);
        pthread_detach(tid);
    }

    printf("[ws-epro] started. GET /cdn-cgi → 200, else → 101+SSH\n");
    fflush(stdout);

    /* Sleep forever — threads do all the work */
    while (1) sleep(3600);
    return 0;
}
