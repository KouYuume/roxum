// The verifier supplies one nonblocking socket and waits for WANT_READ before
// it sends ClientHello, just as it does for the OpenSSL probe.
#include <mbedtls/net_sockets.h>
#include <psa/crypto.h>
#include <mbedtls/ssl.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>

static int handshake(int fd, const char *cert, const char *key_path, int announce_wait) {
    static const char *protocols[] = {"h2", "http/1.1", NULL};
    mbedtls_net_context peer = { .fd = fd };
    mbedtls_ssl_config config;
    mbedtls_ssl_context session;
    mbedtls_x509_crt chain;
    mbedtls_pk_context key;
    mbedtls_ssl_config_init(&config);
    mbedtls_ssl_init(&session);
    mbedtls_x509_crt_init(&chain);
    mbedtls_pk_init(&key);
    int status = 1;
    if (psa_crypto_init() != PSA_SUCCESS ||
        mbedtls_x509_crt_parse_file(&chain, cert) != 0 ||
        mbedtls_pk_parse_keyfile(&key, key_path, NULL) != 0 ||
        mbedtls_pk_check_pair(&chain.pk, &key) != 0 ||
        mbedtls_ssl_config_defaults(&config, MBEDTLS_SSL_IS_SERVER,
                                    MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0)
        goto done;
    mbedtls_ssl_conf_min_tls_version(&config, MBEDTLS_SSL_VERSION_TLS1_2);
    if (mbedtls_ssl_conf_own_cert(&config, &chain, &key) != 0 ||
        mbedtls_ssl_conf_alpn_protocols(&config, protocols) != 0 ||
        mbedtls_ssl_setup(&session, &config) != 0)
        goto done;

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
    mbedtls_ssl_config_free(&config);
    mbedtls_pk_free(&key);
    mbedtls_x509_crt_free(&chain);
    mbedtls_net_free(&peer);
    mbedtls_psa_crypto_free();
    return status;
}

#ifdef ROXUM_TRIAL_HOST
// Called only by the disposable trial worker. A handled socket is closed by
// handshake, including on credential or negotiation failure.
int roxum_trial_accept(int fd) {
    const char *cert = getenv("ROXUM_TRIAL_CERT");
    const char *key = getenv("ROXUM_TRIAL_KEY");
    if (!cert && !key) return 0;
    if (handshake(fd, cert ? cert : "", key ? key : "", 0) != 0) {
        puts("failed");
        fflush(stdout);
    }
    return 1;
}
#else
int main(int argc, char **argv) {
    if (argc != 4) return 1;
    return handshake(atoi(argv[1]), argv[2], argv[3], 1);
}
#endif
