#include "tls_memory.h"
#include <stdint.h>
#include <stdlib.h>
#include <sys/mman.h>

typedef union {
    max_align_t alignment;
    size_t size;
} allocation_header;

// The musl target's C allocator can retain freed PSA record buffers in its
// thread caches. Return larger allocations directly to the kernel on free.
#define MAP_THRESHOLD (4 * 1024)

void *roxum_tls_calloc(size_t count, size_t size) {
    if (count && size > (SIZE_MAX - sizeof(allocation_header)) / count) return NULL;
    size_t bytes = count * size;
    size_t total = sizeof(allocation_header) + bytes;
    allocation_header *block;
    if (bytes >= MAP_THRESHOLD) {
        block = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (block == MAP_FAILED) return NULL;
    } else {
        block = calloc(1, total);
        if (!block) return NULL;
    }
    block->size = bytes;
    return block + 1;
}

void roxum_tls_free(void *ptr) {
    if (!ptr) return;
    allocation_header *block = (allocation_header *)ptr - 1;
    if (block->size >= MAP_THRESHOLD) munmap(block, sizeof(*block) + block->size);
    else free(block);
}
