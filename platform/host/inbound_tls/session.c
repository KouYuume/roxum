#include "session.h"
#include <mbedtls/net_sockets.h>
#include <stdlib.h>
#include <string.h>

struct roxum_tls_session {
    mbedtls_ssl_context ssl;
    mbedtls_net_context peer;
};

void roxum_tls_session_free(roxum_tls_session *session) {
    if (!session) return;
    mbedtls_ssl_free(&session->ssl);
    free(session);
}

roxum_tls_session *roxum_tls_session_open(const roxum_tls_credentials *credentials, int fd) {
    roxum_tls_session *session = malloc(sizeof(*session));
    if (!session) return NULL;
    session->peer.fd = fd;
    mbedtls_ssl_init(&session->ssl);
    if (mbedtls_ssl_setup(&session->ssl, roxum_tls_credentials_config(credentials)) != 0) {
        roxum_tls_session_free(session);
        return NULL;
    }
    mbedtls_ssl_set_bio(&session->ssl, &session->peer, mbedtls_net_send, mbedtls_net_recv, NULL);
    return session;
}

roxum_tls_handshake_result roxum_tls_handshake(roxum_tls_session *session) {
    int rc = mbedtls_ssl_handshake(&session->ssl);
    if (rc == MBEDTLS_ERR_SSL_WANT_READ) return ROXUM_TLS_WANT_READ;
    if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) return ROXUM_TLS_WANT_WRITE;
    if (rc != 0) return ROXUM_TLS_FAILED;
    const char *protocol = mbedtls_ssl_get_alpn_protocol(&session->ssl);
    if (!protocol || strcmp(protocol, "http/1.1") == 0) return ROXUM_TLS_HTTP1;
    if (strcmp(protocol, "h2") == 0) return ROXUM_TLS_HTTP2;
    return ROXUM_TLS_FAILED;
}
