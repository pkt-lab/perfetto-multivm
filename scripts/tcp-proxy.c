/*
 * tcp-proxy.c — Minimal TCP proxy for QNX HV host
 *
 * Listens on 0.0.0.0:LISTEN_PORT, forwards each connection to
 * DEST_IP:DEST_PORT. Needed because QNX guest (10.10.10.2) can't
 * reach Linux guest (10.10.10.3) directly over vdevpeer-net.
 *
 * Build (QNX):  qcc -o tcp-proxy tcp-proxy.c -lsocket
 * Build (Linux): gcc -o tcp-proxy tcp-proxy.c -lpthread
 *
 * Usage: tcp-proxy [listen_port] [dest_ip] [dest_port]
 *   Defaults: 20001 10.10.10.3 20001
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <errno.h>

static const char *g_dest_ip   = "10.10.10.3";
static int         g_dest_port = 20001;

struct proxy_pair {
    int client_fd;
    int upstream_fd;
};

/* Shovel bytes from src to dst until EOF or error */
static void *shovel(void *arg) {
    int *fds = (int *)arg;
    int src = fds[0], dst = fds[1];
    char buf[8192];
    ssize_t n;
    while ((n = read(src, buf, sizeof(buf))) > 0) {
        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(dst, buf + off, n - off);
            if (w <= 0) goto done;
            off += w;
        }
    }
done:
    shutdown(src, SHUT_RD);
    shutdown(dst, SHUT_WR);
    free(arg);
    return NULL;
}

static void *handle_conn(void *arg) {
    struct proxy_pair *p = (struct proxy_pair *)arg;
    int client_fd = p->client_fd;
    free(p);

    /* Connect to upstream (Linux guest traced) */
    int up_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (up_fd < 0) { close(client_fd); return NULL; }

    struct sockaddr_in dest = {0};
    dest.sin_family = AF_INET;
    dest.sin_port = htons(g_dest_port);
    inet_pton(AF_INET, g_dest_ip, &dest.sin_addr);

    if (connect(up_fd, (struct sockaddr *)&dest, sizeof(dest)) < 0) {
        fprintf(stderr, "proxy: connect to %s:%d failed: %s\n",
                g_dest_ip, g_dest_port, strerror(errno));
        close(up_fd);
        close(client_fd);
        return NULL;
    }
    fprintf(stderr, "proxy: connected client_fd=%d → %s:%d\n",
            client_fd, g_dest_ip, g_dest_port);

    /* Bidirectional shovel: client→upstream and upstream→client */
    pthread_t t1, t2;
    int *fds1 = malloc(2 * sizeof(int));
    int *fds2 = malloc(2 * sizeof(int));
    fds1[0] = client_fd; fds1[1] = up_fd;
    fds2[0] = up_fd;     fds2[1] = client_fd;

    pthread_create(&t1, NULL, shovel, fds1);
    pthread_create(&t2, NULL, shovel, fds2);
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    close(client_fd);
    close(up_fd);
    fprintf(stderr, "proxy: connection closed\n");
    return NULL;
}

int main(int argc, char **argv) {
    int listen_port = 20001;
    if (argc > 1) listen_port = atoi(argv[1]);
    if (argc > 2) g_dest_ip   = argv[2];
    if (argc > 3) g_dest_port = atoi(argv[3]);

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));

    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(listen_port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    listen(srv, 8);
    fprintf(stderr, "tcp-proxy: listening on 0.0.0.0:%d → %s:%d\n",
            listen_port, g_dest_ip, g_dest_port);

    for (;;) {
        struct sockaddr_in peer;
        socklen_t plen = sizeof(peer);
        int fd = accept(srv, (struct sockaddr *)&peer, &plen);
        if (fd < 0) { perror("accept"); continue; }

        struct proxy_pair *p = malloc(sizeof(*p));
        p->client_fd = fd;
        pthread_t t;
        pthread_create(&t, NULL, handle_conn, p);
        pthread_detach(t);
    }
}
