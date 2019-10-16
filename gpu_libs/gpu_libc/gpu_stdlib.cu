#include "stdlib.h.cuh"

#include "assert.h.cuh"

__device__ void qsort(void *base, size_t nmemb, size_t size,
                      int (*compar)(const void *, const void *))
{
    NOT_IMPLEMENTED
}

__device__ int atoi(const char *nptr) {
    NOT_IMPLEMENTED
    return 0;
}

__device__ long atol(const char *nptr) {
    NOT_IMPLEMENTED
    return 0;
}

__device__ void *realloc(void *ptr, size_t size) {
    NOT_IMPLEMENTED
    return ptr;
}


__device__ void srand(unsigned int seed) {
    NOT_IMPLEMENTED
}

__device__ int rand(void) {
    NOT_IMPLEMENTED
    return 10;
}

__device__ char stub[] = "stub";

__device__ char *getenv(const char *name) {
    NOT_IMPLEMENTED
    return stub;
}

__device__ void exit(int status) {
    NOT_IMPLEMENTED
}


__device__ double strtod(const char *nptr, char **endptr) {
    NOT_IMPLEMENTED
    return 0.0;
}

__device__ int posix_memalign(void **memptr, size_t alignment, size_t size) {
    NOT_IMPLEMENTED
    return 0;
}