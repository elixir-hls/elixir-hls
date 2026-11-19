/*
 * The AtomVM runtime backend of elixir-hls: the kernels of `--target cpu` (gen/ehls_nif_kernels.c,
 * ehls_nif.h) as NIFs. A kernel's state is a binary the caller keeps and gives back, so the NIFs
 * hold nothing between calls:
 *
 *   hwnif:info(Kernel) -> {InBytes, OutBytes, Levels, StateBytes, MaxIn}
 *   hwnif:init(Kernel) -> State                       the initial state, a binary
 *   hwnif:init(Kernel, Words) -> State                its state words set from a list of integers
 *   hwnif:run(Kernel, State, In, Levels) -> {Out, State1}
 *       In: whole packed elements (EHLS.packed_size/1); Levels: a list of Levels integers.
 *
 * Kernel is the number hw_nif:kernel/1 gives. A call runs to its end and the VM does nothing else
 * meanwhile (a NIF is not preempted), so In is limited to EHLS_NIF_MAX_IN bytes: the caller
 * (EHLS.NIFRun) cuts a longer input into chunks and the VM runs its other processes between
 * them. No hardware here: this builds for any AtomVM platform.
 *
 * The table is gen/ehls_nif_kernels.c, included here: a firmware built without `--target cpu` has none,
 * and then this file is empty (no hwnif NIFs), so every application's build links.
 */
#if __has_include("ehls_nif_kernels.c")
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <intn.h>
#include <memory.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

#include "ehls_nif.h"
#include "ehls_nif_kernels.c"

#ifndef EHLS_NIF_MAX_IN
#define EHLS_NIF_MAX_IN 16384
#endif
#define MAX_LEVELS 16

static const struct ehls_nif_kernel *kernel_of(term t)
{
    if (!term_is_integer(t)) {
        return NULL;
    }
    avm_int_t i = term_to_int(t);
    return i >= 0 && i < ehls_nif_count ? &ehls_nif_kernels[i] : NULL;
}

/* an integer's low 64 bits, as two's complement */
static bool low_bits(term t, uint64_t *out)
{
    if (term_is_integer(t)) {
        *out = (uint64_t) (int64_t) term_to_int(t);
        return true;
    }
    /* a big integer (beyond int64) is not a word: its digits are not an int64 box */
    if (term_is_any_integer(t) && !term_is_bigint(t)) {
        *out = (uint64_t) term_maybe_unbox_int64(t);
        return true;
    }
    return false;
}

static term nif_info(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    const struct ehls_nif_kernel *k = kernel_of(argv[0]);
    if (!k) {
        RAISE_ERROR(BADARG_ATOM);
    }
    if (UNLIKELY(memory_ensure_free_with_roots(ctx, TUPLE_SIZE(5), 1, argv, MEMORY_CAN_SHRINK) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term t = term_alloc_tuple(5, &ctx->heap);
    term_put_tuple_element(t, 0, term_from_int(k->in_bytes));
    term_put_tuple_element(t, 1, term_from_int(k->out_bytes));
    term_put_tuple_element(t, 2, term_from_int(k->nlevels));
    term_put_tuple_element(t, 3, term_from_int(k->state_bytes));
    term_put_tuple_element(t, 4, term_from_int(EHLS_NIF_MAX_IN));
    return t;
}

/* the initial state as a binary; with `words` (a list, or nil) its first state words set from it (each up to 64 bits) */
static term init_state(Context *ctx, term argv[], int nroots, const struct ehls_nif_kernel *k, term words)
{
    void *st = calloc(1, k->state_bytes);
    if (!st) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    k->init(st);
    uint64_t *w = (uint64_t *) st; /* the state's words come first in it */
    uint32_t i = 0;
    for (; term_is_nonempty_list(words); words = term_get_list_tail(words), i++) {
        uint64_t v;
        if (i >= k->nstate || !low_bits(term_get_list_head(words), &v)) {
            free(st);
            RAISE_ERROR(BADARG_ATOM);
        }
        w[i] = v; /* the kernel cuts it to the state's width where it uses it */
    }
    if (!term_is_nil(words)) {
        free(st);
        RAISE_ERROR(BADARG_ATOM);
    }
    if (UNLIKELY(memory_ensure_free_with_roots(ctx, term_binary_heap_size(k->state_bytes), nroots, argv, MEMORY_CAN_SHRINK) != MEMORY_GC_OK)) {
        free(st);
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term bin = term_create_uninitialized_binary(k->state_bytes, &ctx->heap, ctx->global);
    memcpy((void *) term_binary_data(bin), st, k->state_bytes);
    free(st);
    return bin;
}

static term nif_init(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    const struct ehls_nif_kernel *k = kernel_of(argv[0]);
    if (!k) {
        RAISE_ERROR(BADARG_ATOM);
    }
    return init_state(ctx, argv, 1, k, term_nil());
}

static term nif_init_words(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[1], term_is_list);
    const struct ehls_nif_kernel *k = kernel_of(argv[0]);
    if (!k) {
        RAISE_ERROR(BADARG_ATOM);
    }
    return init_state(ctx, argv, 2, k, argv[1]);
}

static term nif_run(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    const struct ehls_nif_kernel *k = kernel_of(argv[0]);
    VALIDATE_VALUE(argv[1], term_is_binary);
    VALIDATE_VALUE(argv[2], term_is_binary);
    VALIDATE_VALUE(argv[3], term_is_list);
    if (!k || term_binary_size(argv[1]) != k->state_bytes) {
        RAISE_ERROR(BADARG_ATOM);
    }
    size_t len = term_binary_size(argv[2]);
    if (len % k->in_bytes != 0 || len > EHLS_NIF_MAX_IN) {
        RAISE_ERROR(BADARG_ATOM);
    }
    size_t n = len / k->in_bytes;

    uint64_t lv[MAX_LEVELS];
    uint32_t nl = 0;
    term l = argv[3];
    for (; term_is_nonempty_list(l); l = term_get_list_tail(l), nl++) {
        if (nl == MAX_LEVELS || !low_bits(term_get_list_head(l), &lv[nl])) {
            RAISE_ERROR(BADARG_ATOM);
        }
    }
    if (!term_is_nil(l) || nl != k->nlevels) {
        RAISE_ERROR(BADARG_ATOM);
    }

    /* the state is copied (aligned, and the caller's binary stays as it was), the output collected
       aside: the heap may move when the results are made */
    void *st = malloc(k->state_bytes);
    uint8_t *out = malloc(n * k->out_bytes + 1);
    if (!st || !out) {
        free(st);
        free(out);
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    memcpy(st, term_binary_data(argv[1]), k->state_bytes);
    size_t got = k->run(st, (const uint8_t *) term_binary_data(argv[2]), n, out, lv);

    size_t need = term_binary_heap_size(got) + term_binary_heap_size(k->state_bytes) + TUPLE_SIZE(2);
    if (UNLIKELY(memory_ensure_free_with_roots(ctx, need, 0, argv, MEMORY_CAN_SHRINK) != MEMORY_GC_OK)) {
        free(st);
        free(out);
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term obin = term_create_uninitialized_binary(got, &ctx->heap, ctx->global);
    memcpy((void *) term_binary_data(obin), out, got);
    term sbin = term_create_uninitialized_binary(k->state_bytes, &ctx->heap, ctx->global);
    memcpy((void *) term_binary_data(sbin), st, k->state_bytes);
    free(st);
    free(out);
    term t = term_alloc_tuple(2, &ctx->heap);
    term_put_tuple_element(t, 0, obin);
    term_put_tuple_element(t, 1, sbin);
    return t;
}

static const struct Nif info_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_info };
static const struct Nif init_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_init };
static const struct Nif init_words_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_init_words };
static const struct Nif run_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_run };

static const struct Nif *hwnif_get_nif(const char *nifname)
{
    if (strcmp("hwnif:info/1", nifname) == 0) {
        return &info_nif;
    }
    if (strcmp("hwnif:init/1", nifname) == 0) {
        return &init_nif;
    }
    if (strcmp("hwnif:init/2", nifname) == 0) {
        return &init_words_nif;
    }
    if (strcmp("hwnif:run/4", nifname) == 0) {
        return &run_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(hwnif, NULL, NULL, hwnif_get_nif)

#endif
