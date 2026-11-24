#include "credentials.h"
#include <psa/crypto.h>
#include <stdlib.h>

struct roxum_tls_credentials {
    mbedtls_x509_crt chain;
    mbedtls_pk_context key;
    mbedtls_ssl_config config;
};

void roxum_tls_credentials_free(roxum_tls_credentials *credentials) {
    if (!credentials) return;
    mbedtls_ssl_config_free(&credentials->config);
    mbedtls_pk_free(&credentials->key);
    mbedtls_x509_crt_free(&credentials->chain);
    free(credentials);
    mbedtls_psa_crypto_free();
}

roxum_tls_credentials *roxum_tls_credentials_load(const char *cert, const char *key) {
    static const char *protocols[] = {"h2", "http/1.1", NULL};
    if (!cert || !*cert || !key || !*key) return NULL;
    roxum_tls_credentials *credentials = malloc(sizeof(*credentials));
    if (!credentials) return NULL;
    mbedtls_x509_crt_init(&credentials->chain);
    mbedtls_pk_init(&credentials->key);
    mbedtls_ssl_config_init(&credentials->config);
    if (psa_crypto_init() != PSA_SUCCESS ||
        mbedtls_x509_crt_parse_file(&credentials->chain, cert) != 0 ||
        mbedtls_pk_parse_keyfile(&credentials->key, key, NULL) != 0 ||
        mbedtls_pk_check_pair(&credentials->chain.pk, &credentials->key) != 0 ||
        mbedtls_ssl_config_defaults(&credentials->config, MBEDTLS_SSL_IS_SERVER,
                                    MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT) != 0 ||
        mbedtls_ssl_conf_own_cert(&credentials->config, &credentials->chain, &credentials->key) != 0 ||
        mbedtls_ssl_conf_alpn_protocols(&credentials->config, protocols) != 0) {
        roxum_tls_credentials_free(credentials);
        return NULL;
    }
    mbedtls_ssl_conf_min_tls_version(&credentials->config, MBEDTLS_SSL_VERSION_TLS1_2);
    return credentials;
}

const mbedtls_ssl_config *roxum_tls_credentials_config(const roxum_tls_credentials *credentials) {
    return &credentials->config;
}
