// The verifier supplies one nonblocking socket and waits for WANT_READ before
// it sends ClientHello, just as it does for the OpenSSL probe.
#include "session.h"
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

static int handshake(int fd, const roxum_tls_credentials *credentials, int probe) {
    roxum_tls_session *session = roxum_tls_session_open(credentials, fd);
    int announce_read = probe;
    int announce_write = probe;
    // The verifier distinguishes a TLS failure from a setup, wait or cleanup error.
    int status = 2;
    while (session) {
        roxum_tls_handshake_result result = roxum_tls_handshake(session);
        if (result == ROXUM_TLS_FAILED) {
            status = 1;
            break;
        }
        if (result == ROXUM_TLS_HTTP1 || result == ROXUM_TLS_HTTP2) {
            puts(result == ROXUM_TLS_HTTP2 ? "h2" : "http/1.1");
            fflush(stdout);
            status = 0;
            break;
        }
        if (announce_read && result == ROXUM_TLS_WANT_READ) {
            puts("waiting for ClientHello");
            fflush(stdout);
            announce_read = 0;
        }
        if (announce_write && result == ROXUM_TLS_WANT_WRITE) {
            fputs("waiting for writable socket\n", stderr);
            fflush(stderr);
            announce_write = 0;
        }
        struct pollfd wait = {fd, result == ROXUM_TLS_WANT_READ ? POLLIN : POLLOUT, 0};
        if (poll(&wait, 1, 5000) <= 0) break;
    }
    roxum_tls_session_free(session);
    if (close(fd) != 0) return 2;
    return status;
}

#ifdef ROXUM_TRIAL_HOST
static roxum_tls_credentials *worker_credentials;

int roxum_trial_start(void) {
    const char *cert = getenv("ROXUM_TRIAL_CERT");
    const char *key = getenv("ROXUM_TRIAL_KEY");
    if (!cert && !key) return 0;
    worker_credentials = roxum_tls_credentials_load(cert, key);
    return worker_credentials ? 0 : 1;
}

void roxum_trial_stop(void) {
    roxum_tls_credentials_free(worker_credentials);
    worker_credentials = NULL;
}

int roxum_trial_accept(int fd) {
    if (!worker_credentials) return 0;
    if (handshake(fd, worker_credentials, 0) != 0) {
        puts("failed");
        fflush(stdout);
    }
    return 1;
}
#else
int main(int argc, char **argv) {
    if (argc != 4) return 1;
    // Workers inherit this disposition from the supervisor.
    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) return 1;
    roxum_tls_credentials *credentials = roxum_tls_credentials_load(argv[2], argv[3]);
    if (!credentials) return 1;
    int status = handshake(atoi(argv[1]), credentials, 1);
    roxum_tls_credentials_free(credentials);
    return status;
}
#endif
