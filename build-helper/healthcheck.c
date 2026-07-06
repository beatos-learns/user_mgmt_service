/*
 * healthcheck.c | tiny static HTTP probe for the scratch runtime image.
 *
 * The runtime image has no shell/curl/wget, so the Docker healthcheck needs a
 * self-contained binary. It GETs http://127.0.0.1:${SERVER_PORT:-8080}/ and
 * exits 0 while the app answers with any HTTP status below 500 (this app has
 * no actuator; Spring Security's 403 still proves the HTTP stack is serving).
 *
 * Compiled in the builder stage: x86_64-linux-musl-gcc -Os -static
 */
#include <arpa/inet.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

int main(void) {
    long port = 8080;
    const char *env = getenv("SERVER_PORT");
    if (env != NULL && *env != '\0') {
        port = strtol(env, NULL, 10);
        if (port <= 0 || port > 65535) {
            return 1;
        }
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return 1;
    }

    /* Bound every socket operation; Docker's healthcheck timeout is the backstop. */
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof addr);
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short) port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (connect(fd, (struct sockaddr *) &addr, sizeof addr) != 0) {
        return 1;
    }

    char req[96];
    int len = snprintf(req, sizeof req,
                       "GET / HTTP/1.1\r\nHost: 127.0.0.1:%ld\r\nConnection: close\r\n\r\n",
                       port);
    if (len <= 0 || (size_t) len >= sizeof req || write(fd, req, (size_t) len) != len) {
        return 1;
    }

    /* "HTTP/1.1 403" needs 12 bytes; read until we have the status line start. */
    char buf[16] = {0};
    ssize_t got = 0;
    while (got < (ssize_t) sizeof buf - 1) {
        ssize_t r = read(fd, buf + got, sizeof buf - 1 - (size_t) got);
        if (r <= 0) {
            break;
        }
        got += r;
    }
    close(fd);

    int status = 0;
    if (got < 12 || sscanf(buf, "HTTP/%*3s %3d", &status) != 1) {
        return 1;
    }
    return (status >= 100 && status < 500) ? 0 : 1;
}
