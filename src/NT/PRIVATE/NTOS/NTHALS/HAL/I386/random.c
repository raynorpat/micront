/*
 * random.c - HAL entropy gatherer for the in-kernel RNG subsystem.
 *
 * The RNG subsystem (NTOS/RNG) owns a clean, deterministic Xoodyak pool.  The
 * HAL is the messy real-world side: it reads whatever hardware entropy the
 * platform offers and hands the raw values, verbatim, to RngAddEntropy.  We do
 * NOT estimate how much entropy a value carries or condition it -- the duplex
 * concentrates whatever real entropy is present.  Sources, per boot point:
 *
 *   - TSC: the low bits, plus the variation in when each boot point is
 *     reached, are the jitter source on platforms without a hardware RNG.
 *   - The boot wall-clock seed (HalpBootSystemTime), read once via the HAL's
 *     detected clock-source backend -- NOT re-read here, so there is no CMOS
 *     port-I/O on this path.
 *   - RDRAND, once, when CPUID advertises it (the hypervisor exposes it on the
 *     KVM/QEMU workload host, giving a full-entropy floor).  RDRAND executes
 *     natively under KVM and is fast; the earlier boot stalls were the CMOS
 *     RTC UIP spin, not RDRAND.
 *
 * The boot path no longer reads the PIT directly: latching channel 0 here
 * races the live clock ISR (which latches it every tick for timekeeping) and
 * could corrupt the system-time delta.  Instead the clock ISR -- the sole
 * legitimate owner of channel 0 -- folds the counter it already reads into
 * HalpTickJitter (a cheap integer fold, no lock, no permute), and the reseed
 * thread drains that word into the pool.  PIT interrupt-latency jitter is thus
 * still captured, but only the clock owner ever touches the hardware.
 *
 * Ongoing reseeding (periodic RDRAND + the accumulated tick jitter, off the
 * critical path) is the job of the entropy thread below.
 *
 * CL 8.50 predates RDTSC/CPUID/RDRAND, so those are hand-emitted as opcode
 * bytes, exactly as stubs.c already does for RDTSC and CPUID.
 */

#include "halp.h"

static BOOLEAN HalpRandProbed   = FALSE;
static BOOLEAN HalpHaveRdrand   = FALSE;
static BOOLEAN HalpHaveRdseed   = FALSE;
static BOOLEAN HalpRdrandSeeded = FALSE;   /* RDRAND folded into the seed once */

/* PIT interrupt-latency jitter, accumulated by the clock ISR (time.c) and
 * drained into the pool by the reseed thread.  Written blind from the ISR at
 * CLOCK2_LEVEL; a torn read/clear on the (UP-only) drain side only loses a
 * sample's worth of entropy, never corrupts. */
volatile ULONG HalpTickJitter = 0;

/* RDTSC -> EDX:EAX (0F 31), as in stubs.c. */
static ULONGLONG
HalpRandReadTsc(VOID)
{
    ULONG lo, hi;
    _asm { _emit 0x0F }
    _asm { _emit 0x31 }
    _asm { mov lo, eax }
    _asm { mov hi, edx }
    return ((ULONGLONG)hi << 32) | lo;
}

/* RDRAND r32 = 0F C7 /6 (ModRM F0 -> EAX).  CF=1 on success; the sbb captures
 * CF as 0 / 0xFFFFFFFF without relying on setcc.  MOV does not disturb CF, so
 * it is safe between RDRAND and the sbb. */
static BOOLEAN
HalpRandRdrand(OUT PULONG Value)
{
    ULONG v  = 0;
    ULONG ok = 0;
    _asm {
        _emit 0x0F
        _emit 0xC7
        _emit 0xF0
        mov   v, eax
        sbb   eax, eax    ; eax = 0 - CF (MOV above leaves CF intact)
        mov   ok, eax
    }
    *Value = v;
    return (BOOLEAN)(ok != 0);
}

/* Probe CPUID once: RDRAND (leaf 1 ECX[30]) and RDSEED (leaf 7 EBX[18]). */
static VOID
HalpRandProbe(VOID)
{
    ULONG maxLeaf = 0;
    ULONG ebx = 0, ecx = 0;

    HalpCpuid(0, 0, &maxLeaf, NULL, NULL, NULL);
    HalpCpuid(1, 0, NULL, NULL, &ecx, NULL);
    HalpHaveRdrand = (BOOLEAN)((ecx >> 30) & 1);

    if (maxLeaf >= 7) {
        HalpCpuid(7, 0, NULL, &ebx, NULL, NULL);
        HalpHaveRdseed = (BOOLEAN)((ebx >> 18) & 1);
    }

    HalpRandProbed = TRUE;
    HalpSerialPrint("HAL: RDRAND ");
    HalpSerialPrint(HalpHaveRdrand ? "yes" : "no");
    HalpSerialPrint(", RDSEED ");
    HalpSerialPrint(HalpHaveRdseed ? "yes\r\n" : "no\r\n");
}

/*
 * Sample the available sources and absorb them into the pool.  Called from
 * several points across HAL init; each call reaches a slightly different point
 * in time, so the TSC samples differ run-to-run.  Cheap and lock-free apart
 * from the brief RngAddEntropy critical section; the one-shot RDRAND batch is
 * gathered into the local buffer (no pool lock held) the first time through.
 */
VOID
HalpAbsorbBootEntropy(VOID)
{
    UCHAR buf[64];
    ULONG n = 0;
    ULONGLONG tsc;

    if (!HalpRandProbed) {
        HalpRandProbe();
    }

    /* 1. TSC at entry. */
    tsc = HalpRandReadTsc();
    RtlCopyMemory(buf + n, &tsc, sizeof(tsc));
    n += sizeof(tsc);

    /* 2. Boot wall-clock seed (0 until HalpInitTscClock runs in Phase 1). */
    RtlCopyMemory(buf + n, &HalpBootSystemTime, sizeof(HalpBootSystemTime));
    n += sizeof(HalpBootSystemTime);

    /* 3. RDRAND, folded in once.  Native + fast under KVM. */
    if (HalpHaveRdrand && !HalpRdrandSeeded) {
        ULONG i, tries, val;
        for (i = 0; i < 8; i += 1) {
            val = 0;
            for (tries = 0; tries < 10; tries += 1) {
                if (HalpRandRdrand(&val)) {
                    break;
                }
            }
            RtlCopyMemory(buf + n, &val, sizeof(val));
            n += sizeof(val);
        }
        HalpRdrandSeeded = TRUE;
    }

    /* 4. TSC again -- folds in the time spent gathering the above. */
    tsc = HalpRandReadTsc();
    RtlCopyMemory(buf + n, &tsc, sizeof(tsc));
    n += sizeof(tsc);

    RngAddEntropy(buf, n);

    /* Don't leave raw entropy (notably the RDRAND batch) on the stack. */
    RtlZeroMemory(buf, sizeof(buf));
}

/* ~60s reseed cadence, as negative (relative) 100ns units. */
#define HALP_RESEED_INTERVAL_100NS  (-((LONGLONG)60 * 10 * 1000 * 1000))

/* nthal.h doesn't carry THREAD_ALL_ACCESS (it's a DDK macro); the handle is
 * closed immediately so its rights don't matter, but spell it out anyway. */
#ifndef THREAD_ALL_ACCESS
#define THREAD_ALL_ACCESS  0x001F03FFUL
#endif

/*
 * Periodic reseed thread. Off the boot critical path, it folds fresh CPU
 * entropy into the pool roughly every minute: the scheduling jitter of when
 * the thread actually wakes (two TSC samples bracketing the work) plus an
 * RDRAND batch when available. RDRAND is gathered into the local buffer with
 * no lock held, so even a slow/trapping draw never stalls a pool user.
 *
 * It deliberately does NOT read the PIT: the live clock ISR latches PIT
 * channel 0 every tick, and a concurrent latch here would corrupt timekeeping.
 */
static VOID
HalpEntropyThread(IN PVOID Context)
{
    LARGE_INTEGER interval;
    UCHAR     buf[64];
    ULONG     n, i, tries, v, jit;
    ULONGLONG tsc;

    UNREFERENCED_PARAMETER(Context);
    interval.QuadPart = HALP_RESEED_INTERVAL_100NS;

    for (;;) {
        KeDelayExecutionThread(KernelMode, FALSE, &interval);

        n = 0;
        tsc = HalpRandReadTsc();
        RtlCopyMemory(buf + n, &tsc, sizeof(tsc));
        n += sizeof(tsc);

        if (HalpHaveRdrand) {
            for (i = 0; i < 4; i += 1) {
                v = 0;
                for (tries = 0; tries < 10; tries += 1) {
                    if (HalpRandRdrand(&v)) {
                        break;
                    }
                }
                RtlCopyMemory(buf + n, &v, sizeof(v));
                n += sizeof(v);
            }
        }

        tsc = HalpRandReadTsc();   /* second sample: wake-to-here jitter */
        RtlCopyMemory(buf + n, &tsc, sizeof(tsc));
        n += sizeof(tsc);

        /* Drain the PIT interrupt-latency jitter the clock ISR has folded into
         * HalpTickJitter since our last pass.  Plain read+clear: a tick landing
         * between the two only loses one sample's entropy (UP today; SMP would
         * want an interlocked exchange). */
        jit = HalpTickJitter;
        HalpTickJitter = 0;
        RtlCopyMemory(buf + n, &jit, sizeof(jit));
        n += sizeof(jit);

        RngAddEntropy(buf, n);

        /* Don't leave raw entropy (notably the RDRAND batch) on the stack. */
        RtlZeroMemory(buf, sizeof(buf));
    }
}

/*
 * Start the reseed thread. Called from the executive once the process
 * subsystem is up (system threads can't be created earlier), which is why
 * this is its own export rather than part of HalInitSystem phase 1.
 */
VOID
HalStartEntropyThread(VOID)
{
    HANDLE   h;
    NTSTATUS st;

    st = PsCreateSystemThread(&h, THREAD_ALL_ACCESS, NULL, NULL, NULL,
                              HalpEntropyThread, NULL);
    if (NT_SUCCESS(st)) {
        ZwClose(h);                 /* detached; we never join it */
    } else {
        HalpSerialPrint("HAL: reseed thread create failed\r\n");
    }
}
