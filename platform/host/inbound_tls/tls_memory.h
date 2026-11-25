#ifndef ROXUM_TLS_MEMORY_H
#define ROXUM_TLS_MEMORY_H

#include <stddef.h>

void *roxum_tls_calloc(size_t count, size_t size);
void roxum_tls_free(void *ptr);

#endif
