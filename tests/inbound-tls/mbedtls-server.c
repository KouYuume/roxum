// The verifier supplies one nonblocking socket and waits for WANT_READ before
// it sends ClientHello, just as it does for the OpenSSL probe.
#include "session.h"
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef ROXUM_TRIAL_HOST
void roxum_trial_finished(roxum_tls_handshake_result result) {
    puts(result == ROXUM_TLS_HTTP2 ? "h2" : result == ROXUM_TLS_HTTP1 ? "http/1.1" : "failed");
    fflush(stdout);
}
#else
static int wait_for_io(int fd, int result) {
    if (result != ROXUM_TLS_IO_WANT_READ && result != ROXUM_TLS_IO_WANT_WRITE) return 0;
    struct pollfd wait = {fd, result == ROXUM_TLS_IO_WANT_READ ? POLLIN : POLLOUT, 0};
    return poll(&wait, 1, 5000) > 0;
}

static int records(int fd, roxum_tls_session *session, int truncated, int duplex) {
    unsigned char byte;
    int rc = roxum_tls_read(session, &byte, 1);
    if (rc != ROXUM_TLS_IO_WANT_READ) return 2;
    puts("waiting for plaintext");
    fflush(stdout);
    while (wait_for_io(fd, rc)) rc = roxum_tls_read(session, &byte, 1);
    if (rc != 1 || byte != 'a' || !roxum_tls_check_pending(session)) return 2;
    if (roxum_tls_read(session, &byte, 1) != 1 || byte != 'b') return 2;

    if (roxum_tls_check_pending(session)) return 2;
    do {
        rc = roxum_tls_write(session, &byte, 1);
    } while (wait_for_io(fd, rc));
    if (rc != 1) return 2;

    static unsigned char reply[256 * 1024];
    for (size_t i = 0; i < sizeof(reply); i++) reply[i] = (unsigned char)(i % 251);
    size_t sent = 0;
    int blocked = 0;
    while (sent < sizeof(reply)) {
        rc = duplex ? roxum_tls_http2_write(session, reply + sent, sizeof(reply) - sent)
                    : roxum_tls_write(session, reply + sent, sizeof(reply) - sent);
        if (rc > 0) {
            // The reply exceeds a TLS record, so at least one write must be partial.
            if ((size_t)rc == sizeof(reply) || (size_t)rc > sizeof(reply) - sent) return 2;
            sent += (size_t)rc;
            continue;
        }
        if (!blocked && rc == (duplex ? 0 : ROXUM_TLS_IO_WANT_WRITE)) {
            puts("waiting to write plaintext");
            fflush(stdout);
            blocked = 1;
            if (duplex) {
                int received;
                do {
                    received = roxum_tls_read(session, &byte, 1);
                } while (wait_for_io(fd, received));
                if (received != 1 || byte != 'c') return 2;
                puts("read while blocked");
                fflush(stdout);
            }
        }
        if (!wait_for_io(fd, duplex && rc == 0 ? ROXUM_TLS_IO_WANT_WRITE : rc)) return 2;
    }
    if (!blocked) return 2;
    do {
        rc = roxum_tls_close_notify(session);
    } while (wait_for_io(fd, rc));
    if (rc != 0) return 2;
    do {
        rc = roxum_tls_read(session, &byte, 1);
    } while (wait_for_io(fd, rc));
    return rc == (truncated ? ROXUM_TLS_IO_FAILED : 0) ? 0 : 2;
}

static int handshake(int fd, const roxum_tls_credentials *credentials, const char *mode) {
    roxum_tls_session *session = roxum_tls_session_open(credentials, fd);
    int announce_read = 1;
    int announce_write = 1;
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
            unsigned char byte = 0;
            if (!mode) status = 0;
            else if (strcmp(mode, "empty-read") == 0) status = roxum_tls_read(session, &byte, 0) == ROXUM_TLS_IO_FAILED ? 0 : 2;
            else if (strcmp(mode, "empty-write") == 0) status = roxum_tls_write(session, &byte, 0) == ROXUM_TLS_IO_FAILED ? 0 : 2;
            else status = records(fd, session, strcmp(mode, "truncated") == 0, strcmp(mode, "duplex") == 0);
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

#ifdef ROXUM_TEST_TLS_MEMORY
#include "tls_memory.h"
#include <stdint.h>

static int check_tls_memory(void) {
    // Cover empty allocations, both sides of the mapping threshold and a record.
    const size_t sizes[] = {0, 4095, 4096, 4097, 16384};
    for (size_t i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
        unsigned char *p = roxum_tls_calloc(sizes[i], 1);
        if (!p || (uintptr_t)p % _Alignof(max_align_t)) return 0;
        for (size_t j = 0; j < sizes[i]; j++) if (p[j]) return 0;
        memset(p, 0xff, sizes[i]);
        roxum_tls_free(p);
    }
    roxum_tls_free(NULL);
    return !roxum_tls_calloc(2, SIZE_MAX / 2 + 1) && !roxum_tls_calloc(1, SIZE_MAX);
}
#endif

int main(int argc, char **argv) {
#ifdef ROXUM_TEST_TLS_MEMORY
    if (!check_tls_memory()) return 2;
#endif
    if (argc != 4 && argc != 5) return 1;
    // Workers inherit this disposition from the supervisor.
    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) return 1;
    roxum_tls_credentials *credentials = roxum_tls_credentials_load(argv[2], argv[3]);
    if (!credentials) return 1;
    int status = handshake(atoi(argv[1]), credentials, argc == 5 ? argv[4] : NULL);
    roxum_tls_credentials_free(credentials);
    return status;
}
#endif
