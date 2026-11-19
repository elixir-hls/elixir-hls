/*
 * The AtomVM runtime backend of elixir-hls: an instance's elements between a list and the packed
 * format of its CPU ends (EHLS.packed_size/1), in C:
 *
 *   hwstream:pack(List, Layout) -> binary()
 *       The elements of List in the packed format, each value wrapped to its type.
 *   hwstream:unpack(Binary, Layout) -> list()
 *       The elements of a packed Binary, signed values negative, tuples as tuples. badarg if it is
 *       not a whole number of elements.
 *
 * Layout is the element's type as EHLS.layout/1 gives it: a scalar is its bits (1..64), negative when
 * signed; a tuple is a tuple of those. Each scalar takes 1, 2, 4 or 8 bytes, the smallest that holds
 * it, little-endian; a tuple left to right, no padding. EHLS.pack/2 and EHLS.unpack/2 do the same
 * in Elixir, to check this against.
 *
 * No hardware here: this builds for any AtomVM platform.
 */
#include <stdint.h>
#include <string.h>

#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <intn.h>
#include <memory.h>
#include <nifs.h>
#include <portnifloader.h>
#include <term.h>

#define MAX_SCALARS 64
#define MAX_DEPTH 8

struct Scalar
{
    uint8_t bits, bytes;
    bool sign;
};

struct Layout
{
    struct Scalar scalars[MAX_SCALARS];
    int count;
    size_t size;      /* bytes of one element */
    size_t heap;      /* the most heap one element can take as a term, its list cell included */
};

/* bytes of a scalar of the given bits */
static inline uint8_t scalar_bytes(int bits)
{
    return bits <= 8 ? 1 : bits <= 16 ? 2 : bits <= 32 ? 4 : 8;
}

/* the most heap a value of this scalar takes as a term */
static size_t scalar_heap(const struct Scalar *s)
{
    if (!s->sign && s->bits == 64) {
        size_t data, digits;
        term_bigint_size_requirements(INTN_UINT64_LEN, &data, &digits);
        return BOXED_BIGINT_HEAP_SIZE(data);
    }
    return BOXED_INT64_SIZE;
}

static bool parse(term l, struct Layout *out, int depth)
{
    if (term_is_integer(l)) {
        avm_int_t v = term_to_int(l);
        bool sign = v < 0;
        avm_int_t bits = sign ? -v : v;
        if (bits < 1 || bits > 64 || out->count == MAX_SCALARS) {
            return false;
        }
        struct Scalar *s = &out->scalars[out->count++];
        s->bits = (uint8_t) bits;
        s->bytes = scalar_bytes((int) bits);
        s->sign = sign;
        out->size += s->bytes;
        out->heap += scalar_heap(s);
        return true;
    }
    if (term_is_tuple(l) && depth < MAX_DEPTH) {
        int arity = term_get_tuple_arity(l);
        if (arity < 1) {
            return false;
        }
        out->heap += TUPLE_SIZE(arity);
        for (int i = 0; i < arity; i++) {
            if (!parse(term_get_tuple_element(l, i), out, depth + 1)) {
                return false;
            }
        }
        return true;
    }
    return false;
}

static bool parse_layout(term l, struct Layout *out)
{
    memset(out, 0, sizeof(*out));
    if (!parse(l, out, 0)) {
        return false;
    }
    out->heap += CONS_SIZE;
    return true;
}

/* an integer's low 64 bits, as two's complement */
static bool low_bits(term t, uint64_t *out)
{
    if (term_is_integer(t)) {
        *out = (uint64_t) (int64_t) term_to_int(t);
        return true;
    }
    if (term_is_bigint(t)) {
        const intn_digit_t *d;
        size_t len;
        intn_integer_sign_t sign;
        term_to_bigint(t, &d, &len, &sign);
        uint64_t m = (uint64_t) d[0] | (len > 1 ? (uint64_t) d[1] << 32 : 0);
        *out = sign == IntNNegativeInteger ? (uint64_t) 0 - m : m;
        return true;
    }
    if (term_is_any_integer(t)) {
        *out = (uint64_t) term_maybe_unbox_int64(t);
        return true;
    }
    return false;
}

/* v wrapped to the scalar: its low bits, sign-extended when signed */
static inline uint64_t wrap(uint64_t v, const struct Scalar *s)
{
    if (s->bits == 64) {
        return v;
    }
    uint64_t mask = ((uint64_t) 1 << s->bits) - 1;
    v &= mask;
    if (s->sign && (v >> (s->bits - 1))) {
        v |= ~mask;
    }
    return v;
}

/* one value or tuple of the element at *k (the scalars in order), written at *p */
static bool pack_value(term x, term l, const struct Layout *lay, int *k, uint8_t **p)
{
    if (term_is_integer(l)) {
        uint64_t v;
        if (!low_bits(x, &v)) {
            return false;
        }
        const struct Scalar *s = &lay->scalars[(*k)++];
        v = wrap(v, s);
        for (int b = 0; b < s->bytes; b++) {
            *(*p)++ = (uint8_t) (v >> (8 * b));
        }
        return true;
    }
    int arity = term_get_tuple_arity(l);
    if (!term_is_tuple(x) || term_get_tuple_arity(x) != arity) {
        return false;
    }
    for (int i = 0; i < arity; i++) {
        if (!pack_value(term_get_tuple_element(x, i), term_get_tuple_element(l, i), lay, k, p)) {
            return false;
        }
    }
    return true;
}

static term nif_pack(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    struct Layout lay;
    if (!parse_layout(argv[1], &lay)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    size_t n = 0;
    term t = argv[0];
    while (term_is_nonempty_list(t)) {
        n++;
        t = term_get_list_tail(t);
    }
    if (!term_is_nil(t)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    size_t len = n * lay.size;
    if (UNLIKELY(memory_ensure_free_with_roots(ctx, term_binary_heap_size(len), 2, argv, MEMORY_CAN_SHRINK) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    term bin = term_create_uninitialized_binary(len, &ctx->heap, ctx->global);
    uint8_t *p = (uint8_t *) term_binary_data(bin);
    for (t = argv[0]; term_is_nonempty_list(t); t = term_get_list_tail(t)) {
        int k = 0;
        if (!pack_value(term_get_list_head(t), argv[1], &lay, &k, &p)) {
            RAISE_ERROR(BADARG_ATOM);
        }
    }
    return bin;
}

/* one value or tuple of the element at *k, read from *p; the heap was made large enough */
static term unpack_value(term l, const struct Layout *lay, int *k, const uint8_t **p, Heap *heap)
{
    if (term_is_integer(l)) {
        const struct Scalar *s = &lay->scalars[(*k)++];
        uint64_t v = 0;
        for (int b = 0; b < s->bytes; b++) {
            v |= (uint64_t) *(*p)++ << (8 * b);
        }
        v = wrap(v, s);
        if (!s->sign && v > (uint64_t) INT64_MAX) {
            intn_digit_t digits[INTN_UINT64_LEN];
            intn_from_uint64(v, digits);
            size_t data, rounded;
            term_bigint_size_requirements(INTN_UINT64_LEN, &data, &rounded);
            term big = term_create_uninitialized_bigint(data, TermPositiveInteger, heap);
            term_initialize_bigint(big, digits, INTN_UINT64_LEN, rounded);
            return big;
        }
        return term_make_maybe_boxed_int64((avm_int64_t) v, heap);
    }
    int arity = term_get_tuple_arity(l);
    term tuple = term_alloc_tuple(arity, heap);
    for (int i = 0; i < arity; i++) {
        term_put_tuple_element(tuple, i, unpack_value(term_get_tuple_element(l, i), lay, k, p, heap));
    }
    return tuple;
}

static term nif_unpack(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_binary);
    struct Layout lay;
    if (!parse_layout(argv[1], &lay)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    size_t len = term_binary_size(argv[0]);
    if (len % lay.size != 0) {
        RAISE_ERROR(BADARG_ATOM);
    }
    size_t n = len / lay.size;
    if (UNLIKELY(memory_ensure_free_with_roots(ctx, n * lay.heap, 2, argv, MEMORY_CAN_SHRINK) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    /* a heap binary may have moved with the collection: its data is read after it */
    const uint8_t *base = (const uint8_t *) term_binary_data(argv[0]);
    term list = term_nil();
    for (size_t i = n; i > 0; i--) {
        const uint8_t *p = base + (i - 1) * lay.size;
        int k = 0;
        term x = unpack_value(argv[1], &lay, &k, &p, &ctx->heap);
        list = term_list_prepend(x, list, &ctx->heap);
    }
    return list;
}

static const struct Nif pack_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_pack };
static const struct Nif unpack_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_unpack };

static const struct Nif *hwstream_pack_get_nif(const char *nifname)
{
    if (strcmp("hwstream:pack/2", nifname) == 0) {
        return &pack_nif;
    }
    if (strcmp("hwstream:unpack/2", nifname) == 0) {
        return &unpack_nif;
    }
    return NULL;
}

REGISTER_NIF_COLLECTION(hwstream_pack, NULL, NULL, hwstream_pack_get_nif)
