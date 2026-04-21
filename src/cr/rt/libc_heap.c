/*
 * libc_heap.c — malloc family, backed by RtlAllocateHeap on the process
 * heap captured in ntshim_init (libc_init.c).
 */

#include "libc_internal.h"

HANDLE _libc_heap;

extern PVOID   NTAPI RtlAllocateHeap  (HANDLE, ULONG, SIZE_T);
extern PVOID   NTAPI RtlReAllocateHeap(HANDLE, ULONG, PVOID, SIZE_T);
extern BOOLEAN NTAPI RtlFreeHeap      (HANDLE, ULONG, PVOID);

void *malloc(size_t n)
{
    return RtlAllocateHeap(_libc_heap, 0, (SIZE_T)n);
}

void *calloc(size_t n, size_t m)
{
    return RtlAllocateHeap(_libc_heap, HEAP_ZERO_MEMORY, (SIZE_T)(n * m));
}

void *realloc(void *p, size_t n)
{
    if (p == 0) return malloc(n);
    if (n == 0) { free(p); return 0; }
    return RtlReAllocateHeap(_libc_heap, 0, p, (SIZE_T)n);
}

void free(void *p)
{
    if (p) RtlFreeHeap(_libc_heap, 0, p);
}
