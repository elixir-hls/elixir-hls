/*
 * The AtomVM runtime backend of elixir-hls: NIFs driving the LiteX backend's hwstream
 * (priv/backend/litex/hls_litex.py):
 *
 *   hwstream:pipe_enable(Pipeline :: non_neg_integer(), On :: boolean()) -> ok
 *       Starts / stops instance number Pipeline (hw_kernels:pipeline/1), running from reset; a start
 *       restarts the state of its stateful kernels.
 *   hwstream:end_send(End, Pipeline, Name, Tag, Input) -> ok | busy | stopped
 *       Gives Input (packed elements) to CPU end number End (hw_kernels:cpu_end/2) of
 *       instance Pipeline, without waiting. {Name, Tag, sent} comes to the caller once the DMA has read it.
 *       While one is being read the end takes one more, started as soon as the first has been read (busy
 *       beyond that, or when the two leave a different number of bytes unused in their last words).
 *   hwstream:end_request(End, Pipeline, Name, Tag, Bytes) -> ok | busy | stopped
 *       Asks CPU end number End for its next Bytes, without waiting. {Name, Tag, Binary} comes to the
 *       caller once they have arrived. While one is being written the end takes one more, started as soon as
 *       the first is in memory (busy beyond that).
 *   hwstream:end_cancel(End) -> ok
 *       Cancels what is in flight on the end: no message follows.
 *   hwstream:peek(Stage, Words) -> [non_neg_integer()]
 *       The Words words of stage number Stage (hw_kernels:state/2, hold/2), taken at one clock.
 *   hwstream:mem_read(Stage, Addr, Count) -> [non_neg_integer()]
 *       Count words from Addr of the memory space of stage number Stage (a named state's memories,
 *       hw_kernels:state/2), each as it is when read (the kernel runs on).
 *   hwstream:level_start(Level, Pipeline, Words) -> non_neg_integer() | stopped
 *       Writes Words as the arguments of instance of levels number Level (hw_kernels:level/1), then
 *       its start write, all in this NIF, so another process's call cannot come in between: the
 *       count of the start, or stopped when instance Pipeline is stopped.
 *   hwstream:end_push(End, Pipeline, Words) -> ok | full | stopped
 *       One element given to input end End without DMA: its packed bytes as 32-bit words (low first),
 *       put into the end's small FIFO; full when it has no room.
 *   hwstream:event_subscribe(Topic, Name, Bits, Signed, Pid, Active, Stamps) -> ok | full
 *       Pid gets {Name, Value} for each event of topic number Topic (hw_kernels:topic/1), Value its
 *       Bits wide, signed or not; up to 4 subscribers per topic. Active: -1 every event, n the next n (the
 *       ones after kept, 16 at most, until it is asked again; {ehls_lost, Name, N} says how many did not fit).
 *       Stamps: {Name, Value, Us} instead, Us when the event came, on erlang:monotonic_time(microsecond)'s clock.
 *       Asked again by the same Pid: the options change, and what was kept comes first.
 *   hwstream:event_unsubscribe(Topic, Pid) -> ok
 *   hwstream:reg_read(Reg) -> non_neg_integer()
 *   hwstream:reg_write(Reg, Value) -> ok
 *       A block package's register by number (hw_kernels:reg/2; ehls_regs.h has the addresses).
 *
 * A transfer runs after its NIF returned, while garbage collections can move a heap binary. So an
 * output is a refc binary of the driver's until it goes in the message, and an input stays in place only
 * if it is a refc binary, aligned and in SDRAM (one more reference until the end); anything else (small,
 * a literal in flash, misaligned) is copied first. The end of a transfer is an interrupt: it hands
 * the pending ends to the system work queue, which sends the messages, as EHLS.GPIO's changes do. The
 * CPU's D-cache is write-through, so only an invalidate is needed after the DMA wrote an output.
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <context.h>
#include <defaultatoms.h>
#include <globalcontext.h>
#include <memory.h>
#include <nifs.h>
#include <portnifloader.h>
#include <refc_binary.h>
#include <synclist.h>
#include <sys.h>
#include <term.h>

#include <zephyr/irq.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/atomic.h>
#include <zephyr/sys/sys_io.h>

#include "ehls_regs.h"
#include "hwstream_csr.h"

#ifdef HWSTREAM_INTERRUPT

struct EndRegs
{
    uint32_t base, length, enable, finished;
};

struct End
{
    bool busy;
    int32_t owner;
    term name, tag;             /* atoms: immediate, valid in any process */
    struct RefcBinary *output;  /* the output being written */
    struct RefcBinary *input;   /* the refc binary being read in place */
    void *copy;                 /* or the copy of the input being read */
    const void *data;           /* an input's bytes and size: to start it when it is the next */
    uint32_t len;
};

/* one more than the ends: an application with events and no CPU end has none (a zero-sized array is no C) */
static const struct EndRegs end_regs[HWSTREAM_ENDS_COUNT + 1] = HWSTREAM_ENDS;
static struct End ends[HWSTREAM_ENDS_COUNT + 1];
/* an end's next transfer, given while one is in flight: started by the completion handler, so that the DMA goes on
 * without waiting for the VM to run the process that would give it */
static struct End nexts[HWSTREAM_ENDS_COUNT + 1];
static GlobalContext *global;
static atomic_t pending;

static inline void dcache_invalidate_all(void)
{
    __asm__ volatile(".word(0x500F)" ::: "memory"); /* VexRiscv: invalidate the whole D-cache */
}

static inline bool in_main_ram(const void *p, size_t len)
{
    uintptr_t a = (uintptr_t) p;
    return ((a & 3) == 0) && a >= HWSTREAM_MAIN_RAM_BASE && a + len <= HWSTREAM_MAIN_RAM_BASE + HWSTREAM_MAIN_RAM_SIZE;
}

static void release(struct End *e)
{
    if (e->output) {
        refc_binary_decrement_refcount(e->output, global);
        e->output = NULL;
    }
    if (e->input) {
        refc_binary_decrement_refcount(e->input, global);
        e->input = NULL;
    }
    free(e->copy);
    e->copy = NULL;
}

/* a term on the given heap for a refc binary of the driver's, as term_alloc_refc_binary makes one */
static term refc_term(struct RefcBinary *refc, Heap *heap)
{
    term *boxed = memory_heap_alloc(heap, TERM_BOXED_REFC_BINARY_SIZE);
    boxed[0] = ((TERM_BOXED_REFC_BINARY_SIZE - 1) << 6) | TERM_BOXED_REFC_BINARY;
    boxed[1] = (term) refc->size;
    boxed[2] = (term) RefcNoFlags;
    boxed[3] = (term) refc;
    term ret = ((term) boxed) | TERM_PRIMARY_BOXED;
    refc_binary_increment_refcount(refc); /* the MSO list's reference, dropped when the stack heap ends */
    heap->root->mso_list = term_list_init_prepend(boxed + REFC_BINARY_CONS_OFFSET, ret, heap->root->mso_list);
    return ret;
}

static void start(avm_int_t i, const void *data, uint32_t len);

/* The work queue: the ends finished, a message each. The end is free again before its message goes. */
static void work_handler(struct k_work *work)
{
    UNUSED(work);
    uint32_t bits = (uint32_t) atomic_set(&pending, 0);

    while (bits) {
        int i = __builtin_ctz(bits);
        bits &= bits - 1;
        struct End *e = &ends[i];

        unsigned key = irq_lock();
        /* cancelled and asked again since: the interrupt is the old transfer's */
        if (!e->busy || !sys_read32(end_regs[i].finished)) {
            irq_unlock(key);
            continue;
        }
        struct End done = *e;
        if (nexts[i].busy) {
            /* the next input goes at once: the circuit is not left without elements */
            *e = nexts[i];
            nexts[i] = (struct End) { .busy = false };
            start(i, e->data, e->len);
        } else {
            *e = (struct End) { .busy = false };
            sys_write32(0, end_regs[i].enable);
        }
        irq_unlock(key);

        BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3) + TERM_BOXED_REFC_BINARY_SIZE, heap);
        term value;
        if (done.output) {
            dcache_invalidate_all();
            value = refc_term(done.output, &heap);
        } else {
            value = globalcontext_make_atom(global, ATOM_STR("\x4", "sent"));
        }
        term message = term_alloc_tuple(3, &heap);
        term_put_tuple_element(message, 0, done.name);
        term_put_tuple_element(message, 1, done.tag);
        term_put_tuple_element(message, 2, value);
        globalcontext_send_message_from_task(global, done.owner, NormalMessage, message);
        END_WITH_STACK_HEAP(heap, global);
        release(&done);
    }
}

static K_WORK_DEFINE(end_work, work_handler);

#ifdef HWSTREAM_EVENTS_LEVEL
/*
 * Events (EHLS.PubSub.broadcast(topic) stages): the interrupt drains the FPGA's queue into a ring here (no allocation, the
 * events kept in order with their times), the work queue sends each to its topic's subscribers. What the ring
 * has no room for is counted in ring_lost.
 */
#define TOPICS 256
#define SUBSCRIBERS 4
#define RING 256
#define HELD 16

struct Event
{
    uint32_t topic, value, time;
};

/* an event kept for a subscriber whose `active` count has run out: its value and its time (µs, monotonic) */
struct Kept
{
    int64_t value, us;
};

struct Subscriber
{
    int32_t pid;              /* 0: none */
    int32_t active;           /* -1: every event; n: the next n, then they are kept until it is asked again */
    bool stamps;              /* {topic, value, us} rather than {topic, value} */
    struct Kept *kept;        /* HELD of them, allocated for an `active` count */
    uint8_t kept_head, kept_count;
    uint32_t lost;            /* events that did not fit in kept, said at the next delivery */
};

struct Topic
{
    term name;                /* an atom: immediate, valid in any process */
    uint8_t bits;
    bool is_signed;
    struct Subscriber subs[SUBSCRIBERS];
};

static struct Event ring[RING];
static uint32_t ring_head, ring_tail, ring_lost;
static struct Topic topics[TOPICS];

static void events_drain(void)
{
    while (sys_read32(HWSTREAM_EVENTS_LEVEL)) {
        struct Event ev = { sys_read32(HWSTREAM_EVENTS_TOPIC), sys_read32(HWSTREAM_EVENTS_VALUE), sys_read32(HWSTREAM_EVENTS_TIME) };
        sys_write32(1, HWSTREAM_EVENTS_POP);
        uint32_t next = (ring_head + 1) % RING;
        if (next == ring_tail) {
            ring_lost++;
            continue;
        }
        ring[ring_head] = ev;
        ring_head = next;
    }
}

/* AtomVM's monotonic clock in µs, as :erlang.monotonic_time(:microsecond) */
static int64_t monotonic_us(void)
{
    struct timespec ts;
    sys_monotonic_time(&ts);
    return (int64_t) ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

/* {name, value} or {name, value, us} to a subscriber; from the work queue (from_task) or a NIF */
static void deliver(GlobalContext *glb, term name, const struct Subscriber *sub, int64_t value, int64_t us, bool from_task)
{
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3) + 2 * BOXED_INT64_SIZE, heap);
    term message;
    if (sub->stamps) {
        message = term_alloc_tuple(3, &heap);
        term_put_tuple_element(message, 2, term_make_maybe_boxed_int64(us, &heap));
    } else {
        message = term_alloc_tuple(2, &heap);
    }
    term_put_tuple_element(message, 0, name);
    term_put_tuple_element(message, 1, term_make_maybe_boxed_int64(value, &heap));
    if (from_task) {
        globalcontext_send_message_from_task(glb, sub->pid, NormalMessage, message);
    } else {
        globalcontext_send_message(glb, sub->pid, message);
    }
    END_WITH_STACK_HEAP(heap, glb);
}

/* {ehls_lost, name, n}: events of the topic that did not fit while delivery was paused */
static void deliver_lost(GlobalContext *glb, term name, int32_t pid, uint32_t n, bool from_task)
{
    BEGIN_WITH_STACK_HEAP(TUPLE_SIZE(3) + BOXED_INT64_SIZE, heap);
    term message = term_alloc_tuple(3, &heap);
    term_put_tuple_element(message, 0, globalcontext_make_atom(glb, ATOM_STR("\x9", "ehls_lost")));
    term_put_tuple_element(message, 1, name);
    term_put_tuple_element(message, 2, term_make_maybe_boxed_int64(n, &heap));
    if (from_task) {
        globalcontext_send_message_from_task(glb, pid, NormalMessage, message);
    } else {
        globalcontext_send_message(glb, pid, message);
    }
    END_WITH_STACK_HEAP(heap, glb);
}

static void events_work_handler(struct k_work *work)
{
    UNUSED(work);
    for (;;) {
        unsigned key = irq_lock();
        if (ring_tail == ring_head) {
            irq_unlock(key);
            return;
        }
        struct Event ev = ring[ring_tail];
        ring_tail = (ring_tail + 1) % RING;
        /* the two clocks read together: how long ago the event came, on AtomVM's monotonic clock */
        uint32_t ago = sys_read32(HWSTREAM_EVENTS_NOW) - ev.time;
        int64_t us = monotonic_us() - (int64_t) ago / (HWSTREAM_SYS_CLK_FREQ / 1000000);
        struct Topic *t = &topics[ev.topic % TOPICS];

        int64_t value = ev.value;
        if (t->bits && t->bits < 32) {
            value &= (1u << t->bits) - 1;
        }
        if (t->is_signed && t->bits && (value >> (t->bits - 1)) & 1) {
            value -= (int64_t) 1 << t->bits;
        }
        /* each subscriber, as its `active` says: delivered, or kept until it asks again */
        struct Subscriber subs[SUBSCRIBERS];
        for (int i = 0; i < SUBSCRIBERS; i++) {
            struct Subscriber *sub = &t->subs[i];
            subs[i] = (struct Subscriber) { .pid = 0 };
            if (sub->pid == 0) {
                continue;
            }
            if (sub->active == 0) {
                if (sub->kept_count < HELD && sub->kept) {
                    sub->kept[(sub->kept_head + sub->kept_count) % HELD] = (struct Kept) { value, us };
                    sub->kept_count++;
                } else {
                    sub->lost++;
                }
                continue;
            }
            if (sub->active > 0) {
                sub->active--;
            }
            subs[i] = *sub;
        }
        term name = t->name;
        irq_unlock(key);

        for (int i = 0; i < SUBSCRIBERS; i++) {
            if (subs[i].pid) {
                deliver(global, name, &subs[i], value, us, true);
            }
        }
    }
}

static K_WORK_DEFINE(events_work, events_work_handler);
#endif

static void isr(const void *arg)
{
    UNUSED(arg);
    uint32_t bits = sys_read32(HWSTREAM_EV_PENDING);
    sys_write32(bits, HWSTREAM_EV_PENDING);
#ifdef HWSTREAM_EVENTS_LEVEL
    /* the events' source comes after the ends' */
    if (bits & BIT(HWSTREAM_ENDS_COUNT)) {
        events_drain();
        k_work_submit(&events_work);
    }
#endif
    bits &= BIT_MASK(HWSTREAM_ENDS_COUNT);
    if (bits) {
        atomic_or(&pending, (atomic_val_t) bits);
        k_work_submit(&end_work);
    }
}

static void connect_irq(GlobalContext *glb)
{
    static bool connected;
    if (!connected) {
        connected = true;
        global = glb;
        IRQ_CONNECT(HWSTREAM_INTERRUPT, 1, isr, NULL, 0);
        irq_enable(HWSTREAM_INTERRUPT);
#ifdef HWSTREAM_EVENTS_LEVEL
        sys_write32(BIT_MASK(HWSTREAM_ENDS_COUNT) | BIT(HWSTREAM_ENDS_COUNT), HWSTREAM_EV_ENABLE);
#else
        sys_write32(BIT_MASK(HWSTREAM_ENDS_COUNT), HWSTREAM_EV_ENABLE);
#endif
    }
}

/* The DMA moves whole words and looks only at length's upper bits: the size rounded up to words, and
 * in the low 2 bits the bytes the last word does not use, for the circuit that packs the elements. */
static inline size_t whole_words(size_t len)
{
    return (len + 3) & ~(size_t) 3;
}

#define PAD(len) ((0u - (len)) & 3u)

static void start(avm_int_t i, const void *data, uint32_t len)
{
    const struct EndRegs *r = &end_regs[i];
    sys_write32(0, r->enable);
    sys_write32((uint32_t) (uintptr_t) data - HWSTREAM_MAIN_RAM_BASE, r->base);
    sys_write32((uint32_t) whole_words(len) | PAD(len), r->length);
    /* the old transfer's event, if it was cancelled just as it finished */
    sys_write32(BIT(i), HWSTREAM_EV_PENDING);
    atomic_and(&pending, ~(atomic_val_t) BIT(i));
    sys_write32(1, r->enable);
}

static term nif_end_send(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_integer);
    VALIDATE_VALUE(argv[2], term_is_atom);
    VALIDATE_VALUE(argv[3], term_is_atom);
    VALIDATE_VALUE(argv[4], term_is_binary);
    avm_int_t i = term_to_int(argv[0]);
    avm_int_t pipe = term_to_int(argv[1]);
    size_t len = term_binary_size(argv[4]);
    if (i < 0 || i >= HWSTREAM_ENDS_COUNT || pipe < 0 || pipe > 31 || len == 0) {
        RAISE_ERROR(BADARG_ATOM);
    }
    connect_irq(ctx->global);
    if (!(sys_read32(HWSTREAM_PIPE_ENABLE) & (1u << pipe))) {
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x7", "stopped"));
    }
    if (ends[i].busy && nexts[i].busy) {
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x4", "busy"));
    }

    const char *data = term_binary_data(argv[4]);
    struct RefcBinary *input = NULL;
    void *copy = NULL;
    if (term_is_refc_binary(argv[4]) && !term_refc_binary_is_const(argv[4]) && in_main_ram(data, whole_words(len))) {
        input = term_refc_binary_ptr(argv[4]);
        refc_binary_increment_refcount(input);
    } else {
        copy = malloc(whole_words(len));
        if (IS_NULL_PTR(copy)) {
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        if (!in_main_ram(copy, whole_words(len))) {
            free(copy);
            RAISE_ERROR(OUT_OF_MEMORY_ATOM);
        }
        memcpy(copy, data, len);
        data = copy;
    }

    struct End given = { .busy = true, .owner = ctx->process_id, .name = argv[2], .tag = argv[3], .input = input, .copy = copy,
                         .data = data, .len = (uint32_t) len };
    unsigned key = irq_lock();
    if (!ends[i].busy) {
        ends[i] = given;
        start(i, data, (uint32_t) len);
    } else if (!nexts[i].busy && PAD(ends[i].len) == PAD((uint32_t) len)) {
        /* (the circuit that splits words into elements takes the pad of the last word from the length register:
         * the next transfer starts while the last word of this one may still be split, so they must agree) */
        nexts[i] = given;
    } else {
        irq_unlock(key);
        release(&given);
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x4", "busy"));
    }
    irq_unlock(key);
    return OK_ATOM;
}

static term nif_end_request(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_integer);
    VALIDATE_VALUE(argv[2], term_is_atom);
    VALIDATE_VALUE(argv[3], term_is_atom);
    VALIDATE_VALUE(argv[4], term_is_integer);
    avm_int_t i = term_to_int(argv[0]);
    avm_int_t pipe = term_to_int(argv[1]);
    avm_int_t len = term_to_int(argv[4]);
    if (i < 0 || i >= HWSTREAM_ENDS_COUNT || pipe < 0 || pipe > 31 || len <= 0) {
        RAISE_ERROR(BADARG_ATOM);
    }
    connect_irq(ctx->global);
    if (!(sys_read32(HWSTREAM_PIPE_ENABLE) & (1u << pipe))) {
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x7", "stopped"));
    }
    if (ends[i].busy && nexts[i].busy) {
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x4", "busy"));
    }

    /* the driver's reference, as term_alloc_refc_binary makes one for a process */
    /* the last word is written whole: room for it, and the binary's size is the exact one */
    struct RefcBinary *output = refc_binary_create_refc(whole_words((size_t) len));
    if (IS_NULL_PTR(output)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    output->ref_count = 1;
    output->size = (size_t) len;
    synclist_append(&ctx->global->refc_binaries, &output->head);
    if (!in_main_ram(output->data, whole_words((size_t) len))) {
        refc_binary_decrement_refcount(output, ctx->global);
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }

    struct End asked = { .busy = true, .owner = ctx->process_id, .name = argv[2], .tag = argv[3], .output = output,
                         .data = output->data, .len = (uint32_t) len };
    unsigned key = irq_lock();
    if (!ends[i].busy) {
        ends[i] = asked;
        start(i, output->data, (uint32_t) len);
    } else if (!nexts[i].busy) {
        /* started by the completion handler once this one is in memory: with `overflow: :drop` nothing is lost
         * while the process that would ask again waits for the VM */
        nexts[i] = asked;
    } else {
        irq_unlock(key);
        release(&asked);
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x4", "busy"));
    }
    irq_unlock(key);
    return OK_ATOM;
}

static term nif_end_cancel(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    avm_int_t i = term_to_int(argv[0]);
    if (i < 0 || i >= HWSTREAM_ENDS_COUNT) {
        RAISE_ERROR(BADARG_ATOM);
    }
    unsigned key = irq_lock();
    struct End done = ends[i];
    struct End next = nexts[i];
    ends[i] = (struct End) { .busy = false };
    nexts[i] = (struct End) { .busy = false };
    sys_write32(0, end_regs[i].enable);
    irq_unlock(key);
    if (done.busy) {
        /* the writes of the words the DMA holds still go to the output */
        k_busy_wait(10);
        release(&done);
    }
    if (next.busy) {
        release(&next);
    }
    return OK_ATOM;
}

static const struct Nif end_send_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_end_send };
static const struct Nif end_request_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_end_request };
static const struct Nif end_cancel_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_end_cancel };

#endif

static term nif_hwstream_pipe_enable(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    avm_int_t p = term_to_int(argv[0]);
    if (p < 0 || p > 31 || (argv[1] != TRUE_ATOM && argv[1] != FALSE_ATOM)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    uint32_t mask = sys_read32(HWSTREAM_PIPE_ENABLE);
    mask = argv[1] == TRUE_ATOM ? (mask | (1u << p)) : (mask & ~(1u << p));
    sys_write32(mask, HWSTREAM_PIPE_ENABLE);
    return OK_ATOM;
}

#ifdef HWSTREAM_PEEK_VALUE
static term nif_hwstream_peek(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_integer);
    avm_int_t stage = term_to_int(argv[0]);
    avm_int_t words = term_to_int(argv[1]);
    if (stage < 0 || stage > 255 || words < 1 || words > 255) {
        RAISE_ERROR(BADARG_ATOM);
    }
    if (UNLIKELY(memory_ensure_free(ctx, LIST_SIZE(words, BOXED_INT64_SIZE)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    sys_write32((uint32_t) stage, HWSTREAM_PEEK_STAGE); /* the circuit takes all the words at one clock */
    (void) sys_read32(HWSTREAM_PEEK_VALUE);             /* ... by the end of this access */
    term list = term_nil();
    for (avm_int_t w = words - 1; w >= 0; w--) {
        sys_write32((uint32_t) w, HWSTREAM_PEEK_SEL);
        (void) sys_read32(HWSTREAM_PEEK_VALUE); /* the value is registered: one clock later */
        uint32_t v = sys_read32(HWSTREAM_PEEK_VALUE);
        list = term_list_prepend(term_make_maybe_boxed_int64((int64_t) v, &ctx->heap), list, &ctx->heap);
    }
    return list;
}
#endif

#ifdef HWSTREAM_MEM_DATA
static term nif_hwstream_mem_read(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_integer);
    VALIDATE_VALUE(argv[2], term_is_integer);
    avm_int_t stage = term_to_int(argv[0]);
    avm_int_t addr = term_to_int(argv[1]);
    avm_int_t count = term_to_int(argv[2]);
    if (stage < 0 || stage > 255 || addr < 0 || count < 1 || addr + count > 65536) {
        RAISE_ERROR(BADARG_ATOM);
    }
    if (UNLIKELY(memory_ensure_free(ctx, LIST_SIZE(count, BOXED_INT64_SIZE)) != MEMORY_GC_OK)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    sys_write32((uint32_t) stage, HWSTREAM_PEEK_STAGE);
    term list = term_nil();
    for (avm_int_t i = count - 1; i >= 0; i--) {
        sys_write32((uint32_t) (addr + i), HWSTREAM_MEM_ADDR);
        /* a few clocks: the CPU's read waits at most one clock for the kernel (or for the memory's zero-fill
         * at a start); never set: the stage has no memory, badarg */
        int polls = 0;
        while (!(sys_read32(HWSTREAM_MEM_DONE) & 1)) {
            if (++polls > 100000) {
                RAISE_ERROR(BADARG_ATOM);
            }
        }
        uint32_t v = sys_read32(HWSTREAM_MEM_DATA);
        list = term_list_prepend(term_make_maybe_boxed_int64((int64_t) v, &ctx->heap), list, &ctx->heap);
    }
    return list;
}
#endif

#ifdef HWSTREAM_LEVEL_START
static term nif_hwstream_level_start(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_integer);
    VALIDATE_VALUE(argv[2], term_is_list);
    avm_int_t level = term_to_int(argv[0]);
    avm_int_t p = term_to_int(argv[1]);
    if (level < 0 || level > 255 || p < 0 || p > 31) {
        RAISE_ERROR(BADARG_ATOM);
    }
    if (!(sys_read32(HWSTREAM_PIPE_ENABLE) & (1u << p))) {
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x7", "stopped"));
    }
    sys_write32((uint32_t) level, HWSTREAM_LEVEL_SEL);
    uint32_t w = 0;
    for (term l = argv[2]; !term_is_nil(l); l = term_get_list_tail(l), w++) {
        if (!term_is_nonempty_list(l) || w > 255) {
            RAISE_ERROR(BADARG_ATOM);
        }
        term v = term_get_list_head(l);
        if (!term_is_any_integer(v)) {
            RAISE_ERROR(BADARG_ATOM);
        }
        sys_write32(w, HWSTREAM_LEVEL_WORD_SEL);
        sys_write32((uint32_t) term_maybe_unbox_int64(v), HWSTREAM_LEVEL_WORD);
    }
    sys_write32(1, HWSTREAM_LEVEL_START);
    (void) sys_read32(HWSTREAM_LEVEL_ISSUED);   /* the count is registered: a clock later */
    avm_int64_t issued = sys_read32(HWSTREAM_LEVEL_ISSUED);
    if (memory_ensure_free_opt(ctx, term_boxed_integer_size(issued), MEMORY_NO_GC) != MEMORY_GC_OK) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    return term_make_maybe_boxed_int64(issued, &ctx->heap);
}

static const struct Nif hwstream_level_start_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_hwstream_level_start };
#endif

#if defined(HWSTREAM_INTERRUPT) && defined(HWSTREAM_EVENTS_LEVEL)
static term nif_event_subscribe(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_atom);
    VALIDATE_VALUE(argv[2], term_is_integer);
    VALIDATE_VALUE(argv[4], term_is_local_pid);
    VALIDATE_VALUE(argv[5], term_is_integer);
    avm_int_t topic = term_to_int(argv[0]);
    avm_int_t bits = term_to_int(argv[2]);
    avm_int_t active = term_to_int(argv[5]);
    if (topic < 0 || topic >= TOPICS || bits < 1 || bits > 32 || (argv[3] != TRUE_ATOM && argv[3] != FALSE_ATOM)
        || active < -1 || active > 0x7fffffff || (argv[6] != TRUE_ATOM && argv[6] != FALSE_ATOM)) {
        RAISE_ERROR(BADARG_ATOM);
    }
    connect_irq(ctx->global);
    int32_t pid = term_to_local_process_id(argv[4]);
    /* a count keeps what comes beyond it: room for that, before the lock */
    struct Kept *room = active >= 0 ? malloc(HELD * sizeof(struct Kept)) : NULL;
    if (active >= 0 && IS_NULL_PTR(room)) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    unsigned key = irq_lock();
    struct Topic *t = &topics[topic];
    t->name = argv[1];
    t->bits = (uint8_t) bits;
    t->is_signed = argv[3] == TRUE_ATOM;
    struct Subscriber *sub = NULL;
    for (int i = 0; i < SUBSCRIBERS && !sub; i++) {
        if (t->subs[i].pid == pid) {
            sub = &t->subs[i];
        }
    }
    for (int i = 0; i < SUBSCRIBERS && !sub; i++) {
        if (t->subs[i].pid == 0) {
            sub = &t->subs[i];
            *sub = (struct Subscriber) { .pid = pid };
        }
    }
    if (!sub) {
        irq_unlock(key);
        free(room);
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x4", "full"));
    }
    /* asked again: the options now, and what was kept goes first, oldest first, as far as `active` allows (taken out
     * under the lock, sent after it: a message allocates) */
    sub->active = (int32_t) active;
    sub->stamps = argv[6] == TRUE_ATOM;
    if (!sub->kept && room) {
        sub->kept = room;
        room = NULL;
    }
    struct Kept out[HELD];
    int n = 0;
    while (sub->kept_count && sub->active != 0) {
        out[n++] = sub->kept[sub->kept_head];
        sub->kept_head = (sub->kept_head + 1) % HELD;
        sub->kept_count--;
        if (sub->active > 0) {
            sub->active--;
        }
    }
    uint32_t lost = n || sub->active != 0 ? sub->lost : 0;
    if (lost) {
        sub->lost = 0;
    }
    struct Subscriber to = *sub;
    term name = t->name;
    irq_unlock(key);
    free(room);
    if (lost) {
        deliver_lost(ctx->global, name, pid, lost, false);
    }
    for (int i = 0; i < n; i++) {
        deliver(ctx->global, name, &to, out[i].value, out[i].us, false);
    }
    return OK_ATOM;
}

static term nif_event_unsubscribe(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_local_pid);
    avm_int_t topic = term_to_int(argv[0]);
    if (topic < 0 || topic >= TOPICS) {
        RAISE_ERROR(BADARG_ATOM);
    }
    int32_t pid = term_to_local_process_id(argv[1]);
    struct Kept *gone[SUBSCRIBERS] = { NULL };
    unsigned key = irq_lock();
    for (int i = 0; i < SUBSCRIBERS; i++) {
        if (topics[topic].subs[i].pid == pid) {
            gone[i] = topics[topic].subs[i].kept;
            topics[topic].subs[i] = (struct Subscriber) { .pid = 0 };
        }
    }
    irq_unlock(key);
    for (int i = 0; i < SUBSCRIBERS; i++) {
        free(gone[i]);
    }
    return OK_ATOM;
}

static const struct Nif event_subscribe_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_event_subscribe };
static const struct Nif event_unsubscribe_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_event_unsubscribe };
#endif

#ifdef HWSTREAM_PUSH
static term nif_end_push(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_integer);
    VALIDATE_VALUE(argv[2], term_is_list);
    avm_int_t e = term_to_int(argv[0]);
    avm_int_t p = term_to_int(argv[1]);
    if (e < 0 || e >= HWSTREAM_ENDS_COUNT || p < 0 || p > 31) {
        RAISE_ERROR(BADARG_ATOM);
    }
    if (!(sys_read32(HWSTREAM_PIPE_ENABLE) & (1u << p))) {
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x7", "stopped"));
    }
    sys_write32((uint32_t) e, HWSTREAM_PUSH_SEL);
    (void) sys_read32(HWSTREAM_PUSH_ROOM); /* registered: a clock after the selection */
    if (sys_read32(HWSTREAM_PUSH_ROOM) == 0) {
        return globalcontext_make_atom(ctx->global, ATOM_STR("\x4", "full"));
    }
    uint32_t w = 0;
    for (term l = argv[2]; !term_is_nil(l); l = term_get_list_tail(l), w++) {
        if (!term_is_nonempty_list(l) || w > 255 || !term_is_any_integer(term_get_list_head(l))) {
            RAISE_ERROR(BADARG_ATOM);
        }
        sys_write32(w, HWSTREAM_PUSH_WORD_SEL);
        sys_write32((uint32_t) term_maybe_unbox_int64(term_get_list_head(l)), HWSTREAM_PUSH_WORD);
    }
    sys_write32(1, HWSTREAM_PUSH);
    return OK_ATOM;
}

static const struct Nif end_push_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_end_push };
#endif

#if EHLS_REGS_COUNT > 0
static const uint32_t ehls_regs[] = EHLS_REGS;

static term nif_hwstream_reg_read(Context *ctx, int argc, term argv[])
{
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    avm_int_t r = term_to_int(argv[0]);
    if (r < 0 || r >= EHLS_REGS_COUNT) {
        RAISE_ERROR(BADARG_ATOM);
    }
    avm_int64_t v = sys_read32(ehls_regs[r]);
    size_t size = term_boxed_integer_size(v);
    if (memory_ensure_free_opt(ctx, size, MEMORY_NO_GC) != MEMORY_GC_OK) {
        RAISE_ERROR(OUT_OF_MEMORY_ATOM);
    }
    return term_make_maybe_boxed_int64(v, &ctx->heap);
}

static term nif_hwstream_reg_write(Context *ctx, int argc, term argv[])
{
    UNUSED(ctx);
    UNUSED(argc);
    VALIDATE_VALUE(argv[0], term_is_integer);
    VALIDATE_VALUE(argv[1], term_is_any_integer);
    avm_int_t r = term_to_int(argv[0]);
    if (r < 0 || r >= EHLS_REGS_COUNT) {
        RAISE_ERROR(BADARG_ATOM);
    }
    sys_write32((uint32_t) term_maybe_unbox_int64(argv[1]), ehls_regs[r]);
    return OK_ATOM;
}

static const struct Nif hwstream_reg_read_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_hwstream_reg_read };
static const struct Nif hwstream_reg_write_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_hwstream_reg_write };
#endif

static const struct Nif hwstream_pipe_enable_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_hwstream_pipe_enable };
#ifdef HWSTREAM_PEEK_VALUE
static const struct Nif hwstream_peek_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_hwstream_peek };
#endif
#ifdef HWSTREAM_MEM_DATA
static const struct Nif hwstream_mem_read_nif = { .base.type = NIFFunctionType, .nif_ptr = nif_hwstream_mem_read };
#endif

static const struct Nif *hwstream_get_nif(const char *nifname)
{
#ifdef HWSTREAM_INTERRUPT
    if (strcmp("hwstream:end_send/5", nifname) == 0) {
        return &end_send_nif;
    }
    if (strcmp("hwstream:end_request/5", nifname) == 0) {
        return &end_request_nif;
    }
    if (strcmp("hwstream:end_cancel/1", nifname) == 0) {
        return &end_cancel_nif;
    }
#endif
#if defined(HWSTREAM_INTERRUPT) && defined(HWSTREAM_EVENTS_LEVEL)
    if (strcmp("hwstream:event_subscribe/7", nifname) == 0) {
        return &event_subscribe_nif;
    }
    if (strcmp("hwstream:event_unsubscribe/2", nifname) == 0) {
        return &event_unsubscribe_nif;
    }
#endif
#ifdef HWSTREAM_PUSH
    if (strcmp("hwstream:end_push/3", nifname) == 0) {
        return &end_push_nif;
    }
#endif
#ifdef HWSTREAM_LEVEL_START
    if (strcmp("hwstream:level_start/3", nifname) == 0) {
        return &hwstream_level_start_nif;
    }
#endif
#if EHLS_REGS_COUNT > 0
    if (strcmp("hwstream:reg_read/1", nifname) == 0) {
        return &hwstream_reg_read_nif;
    }
    if (strcmp("hwstream:reg_write/2", nifname) == 0) {
        return &hwstream_reg_write_nif;
    }
#endif
    if (strcmp("hwstream:pipe_enable/2", nifname) == 0) {
        return &hwstream_pipe_enable_nif;
    }
#ifdef HWSTREAM_PEEK_VALUE
    if (strcmp("hwstream:peek/2", nifname) == 0) {
        return &hwstream_peek_nif;
    }
#endif
#ifdef HWSTREAM_MEM_DATA
    if (strcmp("hwstream:mem_read/3", nifname) == 0) {
        return &hwstream_mem_read_nif;
    }
#endif
    return NULL;
}

#if defined(HWSTREAM_INTERRUPT) && defined(HWSTREAM_EVENTS_LEVEL)
/* With events, the interrupt from the start: what nobody subscribes to is dropped as it comes, so a
 * subscriber gets the events from its subscribing on, not what gathered before */
static void hwstream_init(GlobalContext *glb)
{
    connect_irq(glb);
}
#define HWSTREAM_INIT hwstream_init
#else
#define HWSTREAM_INIT NULL
#endif

REGISTER_NIF_COLLECTION(hwstream, HWSTREAM_INIT, NULL, hwstream_get_nif)
