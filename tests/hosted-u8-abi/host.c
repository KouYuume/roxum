#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    uint8_t *bytes;
    uintptr_t capacity_or_alloc_ptr;
    uintptr_t length;
} RocStr;

void *roc_alloc(uintptr_t length, uintptr_t alignment) {
    (void)alignment;
    return malloc(length);
}

void roc_dealloc(void *ptr, uintptr_t alignment) {
    (void)alignment;
    free(ptr);
}

void *roc_realloc(void *ptr, uintptr_t new_length, uintptr_t alignment) {
    (void)alignment;
    return realloc(ptr, new_length);
}

void roc_dbg(const uint8_t *bytes, uintptr_t length) {
    fwrite(bytes, 1, length, stderr);
}

void roc_expect_failed(const uint8_t *bytes, uintptr_t length) {
    fwrite(bytes, 1, length, stderr);
    exit(2);
}

void roc_crashed(const uint8_t *bytes, uintptr_t length) {
    fwrite(bytes, 1, length, stderr);
    exit(3);
}

void roc_observe(uint8_t level, RocStr message) {
    (void)message;

    if (level > 3) {
        fprintf(stderr, "invalid level: 0x%x\n", level);
        exit(4);
    }

    fprintf(stderr, "level: %u\n", level);
}

extern int64_t roc_main(int64_t value);

int main(void) {
    return (int)roc_main(0);
}
