// The verifier supplies one nonblocking socket and waits for WANT_READ before
// it sends ClientHello, just as it does for the OpenSSL probe.
#include <mbedtls/net_sockets.h>
#include "credentials.h"
#include <mbedtls/ssl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>

static int handshake(int fd, const roxum_tls_credentials *credentials, int announce_wait) {
    mbedtls_net_context peer = { .fd = fd };
    mbedtls_ssl_context session;
    mbedtls_ssl_init(&session);
    int status = 1;
    if (mbedtls_ssl_setup(&session, roxum_tls_credentials_config(credentials)) != 0) goto done;
    mbedtls_ssl_set_bio(&session, &peer, mbedtls_net_send, mbedtls_net_recv, NULL);
    for (;;) {
        int rc = mbedtls_ssl_handshake(&session);
        if (rc == 0) break;
        if (rc != MBEDTLS_ERR_SSL_WANT_READ && rc != MBEDTLS_ERR_SSL_WANT_WRITE) {
            fprintf(stderr, "mbedtls_ssl_handshake returned %d\n", rc);
            goto done;
        }
        if (announce_wait && rc == MBEDTLS_ERR_SSL_WANT_READ) {
            puts("waiting for ClientHello");
            fflush(stdout);
            announce_wait = 0;
        }
        struct pollfd wait = {peer.fd, rc == MBEDTLS_ERR_SSL_WANT_READ ? POLLIN : POLLOUT, 0};
        if (poll(&wait, 1, 5000) <= 0) goto done;
    }
    const char *selected = mbedtls_ssl_get_alpn_protocol(&session);
    puts(selected ? selected : "http/1.1");
    fflush(stdout);
    status = 0;
done:
    mbedtls_ssl_free(&session);
    mbedtls_net_free(&peer);
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
    roxum_tls_credentials *credentials = roxum_tls_credentials_load(argv[2], argv[3]);
    if (!credentials) return 1;
    int status = handshake(atoi(argv[1]), credentials, 1);
    roxum_tls_credentials_free(credentials);
    return status;
}
#endif
