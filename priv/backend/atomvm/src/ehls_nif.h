/*
 * The kernels of `mix ehls.compile --target cpu` as the AtomVM NIF sees them: one table, written by
 * the runtime backend (gen/ehls_nif_kernels.c) from the C of EHLS.NIF. No AtomVM here, so the
 * table and the kernels build and run on the host too.
 */
#ifndef EHLS_NIF_H
#define EHLS_NIF_H

#include <stddef.h>
#include <stdint.h>

struct ehls_nif_kernel
{
    const char *name;          /* "Module.function" */
    uint32_t in_bytes;         /* one element in, packed */
    uint32_t out_bytes;        /* one element out, packed (fewer outputs than inputs when emit) */
    uint32_t nlevels;          /* the level arguments after the stream */
    uint32_t nstate;           /* its state words: the first uint64_t's of the state */
    uint32_t state_bytes;      /* sizeof the kernel's state (its words and memory space) */
    int emit;
    void (*init)(void *state);
    size_t (*run)(void *state, const uint8_t *in, size_t n, uint8_t *out, const uint64_t *levels);
};

extern const struct ehls_nif_kernel ehls_nif_kernels[];
extern const int ehls_nif_count;

#endif
