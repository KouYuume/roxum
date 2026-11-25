#include "session.h"
#include <mbedtls/ssl.h>
#include <mbedtls/net_sockets.h>
#include <stdlib.h>
#include <string.h>

struct roxum_tls_session {
    mbedtls_ssl_context ssl;
    mbedtls_net_context peer;
    unsigned char *pending;
    size_t sent, length;
    int write_result;
};

void roxum_tls_session_free(roxum_tls_session *session) {
    if (!session) return;
    mbedtls_ssl_free(&session->ssl);
    free(session->pending);
    free(session);
}

roxum_tls_session *roxum_tls_session_open(const roxum_tls_credentials *credentials, int fd) {
    roxum_tls_session *session = calloc(1, sizeof(*session));
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

static int io_result(int rc) {
    if (rc == MBEDTLS_ERR_SSL_WANT_READ) return ROXUM_TLS_IO_WANT_READ;
    if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) return ROXUM_TLS_IO_WANT_WRITE;
    return ROXUM_TLS_IO_FAILED;
}

int roxum_tls_read(roxum_tls_session *session, unsigned char *data, size_t len) {
    if (!len) return ROXUM_TLS_IO_FAILED;
    int rc = mbedtls_ssl_read(&session->ssl, data, len);
    if (rc == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY) return 0;
    return rc > 0 ? rc : io_result(rc);
}

int roxum_tls_write(roxum_tls_session *session, const unsigned char *data, size_t len) {
    if (!len) return ROXUM_TLS_IO_FAILED;
    int rc = mbedtls_ssl_write(&session->ssl, data, len);
    return rc > 0 ? rc : io_result(rc);
}

// A completed TLS write leaves the SSL context available for reading even
// when the socket cannot accept the whole encrypted record. Retain at most
// one record suffix, allocated only when an HTTP/2 socket hits backpressure.
static int send_http2(void *context, const unsigned char *buf, size_t len) {
    roxum_tls_session *session = context;
    if (session->pending) return MBEDTLS_ERR_SSL_WANT_WRITE;
    int rc = mbedtls_net_send(&session->peer, buf, len);
    if (rc == MBEDTLS_ERR_SSL_WANT_WRITE) rc = 0;
    if (rc < 0 || (size_t)rc == len) return rc;
    session->pending = malloc(len - (size_t)rc);
    if (!session->pending) return MBEDTLS_ERR_SSL_ALLOC_FAILED;
    session->length = len - (size_t)rc;
    session->sent = 0;
    memcpy(session->pending, buf + rc, session->length);
    return (int)len;
}

static int recv_http2(void *context, unsigned char *buf, size_t len) {
    roxum_tls_session *session = context;
    return mbedtls_net_recv(&session->peer, buf, len);
}

int roxum_tls_http2_write(roxum_tls_session *session, const unsigned char *data, size_t len) {
    if (session->pending) {
        while (session->sent < session->length) {
            int rc = mbedtls_net_send(&session->peer, session->pending + session->sent,
                                      session->length - session->sent);
            if (rc == MBEDTLS_ERR_SSL_WANT_WRITE)
                return session->write_result > 0 ? 0 : ROXUM_TLS_IO_WANT_WRITE;
            if (rc <= 0) return ROXUM_TLS_IO_FAILED;
            session->sent += (size_t)rc;
        }
        free(session->pending);
        session->pending = NULL;
        if (session->write_result > 0) {
            mbedtls_ssl_set_bio(&session->ssl, &session->peer, mbedtls_net_send, mbedtls_net_recv, NULL);
            return session->write_result;
        }
        // A TLS control record preceded the application write. Resume the
        // incomplete operation with the caller's original plaintext slice.
    }
    mbedtls_ssl_set_bio(&session->ssl, session, send_http2, recv_http2, NULL);
    session->write_result = roxum_tls_write(session, data, len);
    if (session->pending && session->write_result != ROXUM_TLS_IO_FAILED)
        return session->write_result > 0 ? 0 : ROXUM_TLS_IO_WANT_WRITE;
    mbedtls_ssl_set_bio(&session->ssl, &session->peer, mbedtls_net_send, mbedtls_net_recv, NULL);
    return session->write_result;
}

int roxum_tls_check_pending(const roxum_tls_session *session) {
    return mbedtls_ssl_check_pending(&session->ssl);
}

int roxum_tls_close_notify(roxum_tls_session *session) {
    int rc = mbedtls_ssl_close_notify(&session->ssl);
    return rc == 0 ? 0 : io_result(rc);
}
