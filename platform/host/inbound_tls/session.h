#ifndef ROXUM_TLS_SESSION_H
#define ROXUM_TLS_SESSION_H

#include "credentials.h"

typedef struct roxum_tls_session roxum_tls_session;

typedef enum {
    ROXUM_TLS_FAILED,
    ROXUM_TLS_WANT_READ,
    ROXUM_TLS_WANT_WRITE,
    ROXUM_TLS_HTTP1,
    ROXUM_TLS_HTTP2
} roxum_tls_handshake_result;

// The caller owns the nonblocking socket and credentials for the session lifetime.
roxum_tls_session *roxum_tls_session_open(const roxum_tls_credentials *credentials, int fd);
// Retry after the requested readiness. All other results end the handshake.
roxum_tls_handshake_result roxum_tls_handshake(roxum_tls_session *session);
void roxum_tls_session_free(roxum_tls_session *session);

#endif
