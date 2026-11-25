#ifndef ROXUM_TLS_SESSION_H
#define ROXUM_TLS_SESSION_H

#include "credentials.h"
#include <stddef.h>

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
// Record operations follow a completed handshake. Positive counts consume that
// many plaintext bytes. Retry the same operation on WANT, with the same write
// pointer and length. Any FAILED result ends the session.
enum {
    ROXUM_TLS_IO_FAILED = -1,
    ROXUM_TLS_IO_WANT_READ = -2,
    ROXUM_TLS_IO_WANT_WRITE = -3
};
// Buffers must be nonempty. A zero read denotes an authenticated close_notify.
// A transport EOF without close_notify is a failure.
int roxum_tls_read(roxum_tls_session *session, unsigned char *data, size_t len);
int roxum_tls_write(roxum_tls_session *session, const unsigned char *data, size_t len);
// HTTP/2 only: zero means TLS accepted the plaintext but the socket still owes
// ciphertext. Reads may proceed. Retry with the same slice until positive.
int roxum_tls_http2_write(roxum_tls_session *session, const unsigned char *data, size_t len);
// Check before waiting on the socket after a successful read. The library
// may hold another record or part of the current one.
int roxum_tls_check_pending(const roxum_tls_session *session);
// Returns zero once the outbound close_notify has been sent.
int roxum_tls_close_notify(roxum_tls_session *session);

void roxum_tls_session_free(roxum_tls_session *session);

#endif
