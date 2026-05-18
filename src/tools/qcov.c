/*
 * qcov.c -- QEMU TCG plugin: per-translation-block execution histogram.
 *
 * Records, for every guest translation block whose start address falls
 * in a configured range, the block's instruction addresses and how many
 * times it executed.  Dumped at guest exit as a text trace that
 * cov2lcov.py joins against the boot-efi serial log (module bases) and
 * the per-module .dwf DWARF to produce lcov coverage.
 *
 * No QEMU headers required.  The plugin only touches the original
 * version-1 plugin API (stable since QEMU 4.2); the prototypes it needs
 * are declared inline below.  QEMU resolves the qemu_plugin_* symbols at
 * dlopen time, so there is no build- or link-time dependency on QEMU --
 * the same .so loads on any plugin-enabled QEMU regardless of version.
 *
 * Build:
 *     gcc -O2 -fPIC -shared -o qcov.so qcov.c
 *
 * Use (added to the qemu line by `boot.sh --coverage`):
 *     -plugin /path/to/qcov.so,out=hist.txt,lo=0x80000000,hi=0xffffffff
 *
 *   out=  output trace path           (default "qcov.trace")
 *   lo=   record TBs starting at >= lo (default 0x80000000, NT kernel space)
 *   hi=   record TBs starting at <= hi (default 0xffffffff)
 *
 * The lo/hi window discards the 64-bit EFI loader phase and user-mode
 * execution, keeping only 32-bit NT kernel + driver code.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ------------------------------------------------------------------ *
 * QEMU plugin API, version 1 -- inline declarations.
 *
 * This is the subset qcov uses, transcribed from the public
 * include/qemu/qemu-plugin.h.  Signatures have been stable since
 * QEMU 4.2; do not extend this with version-2+ symbols (register
 * access, scoreboard inline ops) without reintroducing a version pin.
 * ------------------------------------------------------------------ */

#define QEMU_PLUGIN_EXPORT  __attribute__((visibility("default")))
#define QEMU_PLUGIN_VERSION 1

typedef uint64_t qemu_plugin_id_t;

struct qemu_plugin_tb;
struct qemu_plugin_insn;

enum qemu_plugin_cb_flags {
    QEMU_PLUGIN_CB_NO_REGS,     /* callback reads/writes no guest registers */
    QEMU_PLUGIN_CB_R_REGS,
    QEMU_PLUGIN_CB_RW_REGS,
};

typedef void (*qemu_plugin_vcpu_tb_trans_cb_t)(qemu_plugin_id_t id,
                                               struct qemu_plugin_tb *tb);
typedef void (*qemu_plugin_vcpu_udata_cb_t)(unsigned int vcpu_index,
                                            void *userdata);
typedef void (*qemu_plugin_udata_cb_t)(qemu_plugin_id_t id, void *userdata);

extern void qemu_plugin_register_vcpu_tb_trans_cb(
    qemu_plugin_id_t id, qemu_plugin_vcpu_tb_trans_cb_t cb);
extern void qemu_plugin_register_vcpu_tb_exec_cb(
    struct qemu_plugin_tb *tb, qemu_plugin_vcpu_udata_cb_t cb,
    enum qemu_plugin_cb_flags flags, void *userdata);
extern void qemu_plugin_register_atexit_cb(
    qemu_plugin_id_t id, qemu_plugin_udata_cb_t cb, void *userdata);

extern size_t qemu_plugin_tb_n_insns(const struct qemu_plugin_tb *tb);
extern struct qemu_plugin_insn *qemu_plugin_tb_get_insn(
    const struct qemu_plugin_tb *tb, size_t idx);
extern uint64_t qemu_plugin_insn_vaddr(const struct qemu_plugin_insn *insn);

/* QEMU reads this symbol to version-check the plugin at load time. */
QEMU_PLUGIN_EXPORT int qemu_plugin_version = QEMU_PLUGIN_VERSION;

/* ------------------------------------------------------------------ *
 * Plugin state
 * ------------------------------------------------------------------ */

/*
 * One record per translated block.  Allocated individually and never
 * moved: the record pointer is handed to QEMU as the exec callback's
 * userdata, so its address must stay stable for the run.  `insn` is a
 * flexible array of the block's guest instruction addresses, captured
 * once at translation time.
 */
struct tb_rec {
    uint64_t count;             /* times this translation executed */
    uint32_t n;                 /* instruction count */
    uint32_t insn[];            /* guest virtual addresses */
};

/*
 * Growable array of record *pointers*.  Reallocating this array is safe
 * -- QEMU only ever holds the record pointers, never an index into it.
 */
static struct tb_rec **g_recs;
static size_t          g_nrecs;
static size_t          g_caprecs;

static uint64_t g_lo  = 0x80000000ULL;  /* NT kernel space lower bound */
static uint64_t g_hi  = 0xffffffffULL;
static char     g_out[1024] = "qcov.trace";

/* Set once the trace has been written.  The flush is reachable from two
 * exit paths (see flush_trace); whichever fires first writes, the other
 * sees this flag and returns. */
static int g_flushed;

/* ------------------------------------------------------------------ *
 * Callbacks
 * ------------------------------------------------------------------ */

/* Per-execution: bump the block's counter.  Atomic so an MTTCG / SMP
 * guest stays correct; on the UP NT kernel this is a single thread. */
static void vcpu_tb_exec(unsigned int vcpu_index, void *userdata)
{
    (void)vcpu_index;
    struct tb_rec *r = userdata;
    __atomic_add_fetch(&r->count, 1, __ATOMIC_RELAXED);
}

/* Per-translation: snapshot the block's instruction addresses and arm
 * the exec callback.  Blocks of out-of-window code are dropped here so
 * they cost nothing at run time. */
static void vcpu_tb_trans(qemu_plugin_id_t id, struct qemu_plugin_tb *tb)
{
    (void)id;
    size_t n = qemu_plugin_tb_n_insns(tb);
    if (n == 0) {
        return;
    }

    uint64_t start = qemu_plugin_insn_vaddr(qemu_plugin_tb_get_insn(tb, 0));
    if (start < g_lo || start > g_hi) {
        return;
    }

    struct tb_rec *r = malloc(sizeof(*r) + n * sizeof(uint32_t));
    if (!r) {
        return;                 /* drop this block rather than abort */
    }
    r->count = 0;
    r->n = (uint32_t)n;
    for (size_t i = 0; i < n; i++) {
        r->insn[i] = (uint32_t)qemu_plugin_insn_vaddr(
                         qemu_plugin_tb_get_insn(tb, i));
    }

    /* Translation is single-threaded for the UP guest, so this append
     * needs no lock.  Revisit if an SMP kernel ever runs under MTTCG. */
    if (g_nrecs == g_caprecs) {
        size_t cap = g_caprecs ? g_caprecs * 2 : 4096;
        struct tb_rec **grown = realloc(g_recs, cap * sizeof(*grown));
        if (!grown) {
            free(r);
            return;
        }
        g_recs = grown;
        g_caprecs = cap;
    }
    g_recs[g_nrecs++] = r;

    qemu_plugin_register_vcpu_tb_exec_cb(tb, vcpu_tb_exec,
                                         QEMU_PLUGIN_CB_NO_REGS, r);
}

/* Write every executed block as one line of hex `count n v0 v1 ...`.
 *
 * Reached from two registrations (see qemu_plugin_install):
 *   - QEMU's qemu_plugin_register_atexit_cb, which fires on the clean
 *     qemu_cleanup() shutdown path; and
 *   - libc atexit(), which fires on every exit() -- including the
 *     isa-debug-exit poweroff the NT selftest uses, which calls exit()
 *     directly and bypasses qemu_cleanup().
 * g_flushed makes the body run exactly once whichever (or both) fire. */
static void flush_trace(void)
{
    if (g_flushed) {
        return;
    }
    g_flushed = 1;

    FILE *f = fopen(g_out, "w");
    if (!f) {
        fprintf(stderr, "qcov: cannot write %s\n", g_out);
        return;
    }

    fprintf(f, "qcov-trace v1\n");

    uint64_t emitted = 0;
    for (size_t i = 0; i < g_nrecs; i++) {
        struct tb_rec *r = g_recs[i];
        if (r->count == 0) {
            continue;           /* translated but never executed */
        }
        fprintf(f, "%llx %x", (unsigned long long)r->count, r->n);
        for (uint32_t j = 0; j < r->n; j++) {
            fprintf(f, " %x", r->insn[j]);
        }
        fputc('\n', f);
        emitted++;
    }

    fclose(f);
    fprintf(stderr, "qcov: wrote %llu executed block(s) of %zu translated "
                    "to %s\n", (unsigned long long)emitted, g_nrecs, g_out);
}

/* QEMU plugin-atexit callback — thin shim onto flush_trace(). */
static void plugin_atexit(qemu_plugin_id_t id, void *userdata)
{
    (void)id;
    (void)userdata;
    flush_trace();
}

/* ------------------------------------------------------------------ *
 * Entry point
 * ------------------------------------------------------------------ */

static uint64_t parse_u64(const char *s)
{
    return (uint64_t)strtoull(s, NULL, 0);
}

QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,
                                           const void *info,
                                           int argc, char **argv)
{
    (void)info;

    for (int i = 0; i < argc; i++) {
        const char *a = argv[i];
        if (!strncmp(a, "out=", 4)) {
            snprintf(g_out, sizeof(g_out), "%s", a + 4);
        } else if (!strncmp(a, "lo=", 3)) {
            g_lo = parse_u64(a + 3);
        } else if (!strncmp(a, "hi=", 3)) {
            g_hi = parse_u64(a + 3);
        } else {
            fprintf(stderr, "qcov: unknown argument '%s'\n", a);
            return -1;
        }
    }

    fprintf(stderr, "qcov: window [0x%llx, 0x%llx], output %s\n",
            (unsigned long long)g_lo, (unsigned long long)g_hi, g_out);

    qemu_plugin_register_vcpu_tb_trans_cb(id, vcpu_tb_trans);
    qemu_plugin_register_atexit_cb(id, plugin_atexit, NULL);  /* clean shutdown */
    atexit(flush_trace);                                      /* isa-debug-exit */
    return 0;
}
