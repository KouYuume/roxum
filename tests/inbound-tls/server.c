// One inherited nonblocking socket. The parent waits for the first read wait
// before sending ClientHello, so the test observes a suspended handshake.
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>

static int select_protocol(SSL *ssl, const unsigned char **out,
                           unsigned char *out_len, const unsigned char *offers,
                           unsigned int length, void *arg) {
    (void)ssl;
    (void)arg;
    static const unsigned char protocols[] = "\x02h2\x08http/1.1";
    unsigned char *selected;
    if (SSL_select_next_proto(&selected, out_len, protocols, sizeof(protocols) - 1,
                              offers, length) != OPENSSL_NPN_NEGOTIATED)
        return SSL_TLSEXT_ERR_ALERT_FATAL;
    *out = selected;
    return SSL_TLSEXT_ERR_OK;
}

int main(int argc, char **argv) {
    if (argc != 4) return 1;
    int fd = atoi(argv[1]);
    int status = 1;
    SSL *session = NULL;
    SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
    if (!ctx || !SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION) ||
        SSL_CTX_use_certificate_chain_file(ctx, argv[2]) != 1 ||
        SSL_CTX_use_PrivateKey_file(ctx, argv[3], SSL_FILETYPE_PEM) != 1 ||
        SSL_CTX_check_private_key(ctx) != 1)
        goto done;
    SSL_CTX_set_alpn_select_cb(ctx, select_protocol, NULL);
    session = SSL_new(ctx);
    if (!session || SSL_set_fd(session, fd) != 1) goto done;
    int announced = 0;
    for (;;) {
        ERR_clear_error();
        int result = SSL_accept(session);
        if (result == 1) break;
        int error = SSL_get_error(session, result);
        if (error != SSL_ERROR_WANT_READ && error != SSL_ERROR_WANT_WRITE)
            goto done;
        if (!announced && error == SSL_ERROR_WANT_READ) {
            puts("waiting for ClientHello");
            fflush(stdout);
            announced = 1;
        }
        struct pollfd wait = {fd, error == SSL_ERROR_WANT_READ ? POLLIN : POLLOUT, 0};
        if (poll(&wait, 1, 5000) <= 0) goto done;
    }
    const unsigned char *protocol;
    unsigned int length;
    SSL_get0_alpn_selected(session, &protocol, &length);
    // With no extension the TLS session has no ALPN value; the listener
    // dispatches that connection to HTTP/1.1.
    printf("%.*s\n", length ? (int)length : 8,
           length ? (const char *)protocol : "http/1.1");
    status = 0;
done:
    if (status) ERR_print_errors_fp(stderr);
    SSL_free(session);
    SSL_CTX_free(ctx);
    return status;
}
