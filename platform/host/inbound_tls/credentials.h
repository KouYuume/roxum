#ifndef ROXUM_TLS_CREDENTIALS_H
#define ROXUM_TLS_CREDENTIALS_H

#include <mbedtls/ssl.h>

typedef struct roxum_tls_credentials roxum_tls_credentials;

// One owner per worker, initialized after fork and before accepting sessions.
// Destroy only after all sessions using the borrowed config have ended.
roxum_tls_credentials *roxum_tls_credentials_load(const char *cert, const char *key);
const mbedtls_ssl_config *roxum_tls_credentials_config(const roxum_tls_credentials *credentials);
void roxum_tls_credentials_free(roxum_tls_credentials *credentials);

#endif
