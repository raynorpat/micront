/*
 * kvmclock.c - KVM paravirtual clock as a wall-clock seed backend.
 *
 * On KVM (qemu, EC2 Nitro, GCE, Linode, ...) the host exposes a
 * paravirtual clock through two MSRs.  We use it for one thing only:
 * seeding HalpBootSystemTime with the host's wall-clock time at boot.
 * It registers ahead of the CMOS RTC in HalpDetectClockSource (time.c),
 * so a microvm with no UEFI seed and no MC146818 still gets an accurate,
 * host-synced wall clock instead of starting at the 1601 epoch — and we
 * never touch (or stall on) an absent RTC.
 *
 * The live clock (HalQueryRealTimeClock) and InterruptTime stay on the
 * PIT; kvmclock here is purely the boot seed.
 *
 * ABI (Linux Documentation/virt/kvm/x86/msr.rst):
 *   MSR_KVM_SYSTEM_TIME_NEW (0x4b564d01): write PA|1 of a per-vCPU
 *       pvclock_vcpu_time_info; the host keeps it live.  system_time
 *       counts nanoseconds since the host set the clock up (≈ VM start).
 *   MSR_KVM_WALL_CLOCK_NEW (0x4b564d00): write PA of a pvclock_wall_clock;
 *       the host fills it with the wall time at the instant system_time
 *       reads 0.  So current wall = wall_clock + system_time.
 * Both structures are read under their even-version seqlock.
 *
 * SMP note: pvclock_vcpu_time_info is per-vCPU and would need a structure
 * + MSR write on each processor.  MicroNT is UP-only today (see the same
 * note on HalpClockTickIncrement); revisit when SMP lands.
 */

#define _NTSYSTEM_
#include "halp.h"

/* poppack.h in the NT 3.5 DDK headers leaks #pragma pack(2) into this TU.
 * The pvclock structures are a host ABI laid out at fixed byte offsets, so
 * pin natural packing.  The explicit pad fields below make pack(2) and
 * natural layout identical regardless, but be explicit — and the runtime
 * sizeof check in HalpKvmClockInit catches any mismatch at boot. */
#pragma pack()

#define MSR_KVM_WALL_CLOCK_NEW   0x4b564d00
#define MSR_KVM_SYSTEM_TIME_NEW  0x4b564d01

/* CPUID 0x40000001:EAX feature bits. */
#define KVM_FEATURE_CLOCKSOURCE2 (1 << 3)   /* the _NEW MSRs above */

/* 100-ns ticks from 1601-01-01 (NT epoch) to 1970-01-01 (Unix epoch):
 * 11644473600 seconds * 10^7. */
#define NT_1601_TO_1970_100NS  ((ULONGLONG)116444736000000000)

typedef struct _PVCLOCK_VCPU_TIME_INFO {
    ULONG     Version;          /* +0   odd while host is updating */
    ULONG     Pad0;             /* +4 */
    ULONGLONG TscTimestamp;     /* +8   TSC at the SystemTime sample */
    ULONGLONG SystemTime;       /* +16  ns since host reference */
    ULONG     TscToSystemMul;   /* +24  mul factor, see scale below */
    CHAR      TscShift;         /* +28  signed pre-shift */
    UCHAR     Flags;            /* +29 */
    UCHAR     Pad[2];           /* +30 */
} PVCLOCK_VCPU_TIME_INFO;       /* 32 bytes */

typedef struct _PVCLOCK_WALL_CLOCK {
    ULONG Version;              /* +0   odd while host is updating */
    ULONG Sec;                  /* +4   seconds since 1970 at system_time==0 */
    ULONG Nsec;                 /* +8 */
} PVCLOCK_WALL_CLOCK;           /* 12 bytes */

/* Backing store for both structures.  They live in the HAL image; the MSRs
 * want their guest-physical address, which we recover from the page-table
 * self-map (HalpKvmVaToPa) — the same mechanism apic.c uses this early in
 * HalInitSystem, with no memory manager and no assumption about a linear
 * kernel mapping.  Reserve slack so we can hand the host a 64-byte-aligned
 * pair (alignment also keeps bit 0 of the system_time PA clear, since bit 0
 * is the MSR enable flag). */
static UCHAR HalpKvmPvRaw[192];
static volatile PVCLOCK_VCPU_TIME_INFO *HalpKvmPvti  = NULL;
static volatile PVCLOCK_WALL_CLOCK     *HalpKvmPvWall = NULL;

BOOLEAN HalpKvmClockAvailable = FALSE;

/* RDMSR (0F 32): ecx = MSR index -> edx:eax.  WRMSR (0F 30): ecx = index,
 * edx:eax = value.  CL 8.50's inline assembler predates both mnemonics, so
 * hand-emit the opcode bytes exactly like HalpReadTsc/HalpCpuid in time.c. */
static ULONGLONG
HalpReadMsr(ULONG Msr)
{
    ULONG lo, hi;
    _asm {
        mov   ecx, Msr
        _emit 0x0F
        _emit 0x32
        mov   lo, eax
        mov   hi, edx
    }
    return ((ULONGLONG)hi << 32) | lo;
}

static VOID
HalpWriteMsr(ULONG Msr, ULONGLONG Value)
{
    ULONG lo = (ULONG)Value;
    ULONG hi = (ULONG)(Value >> 32);
    _asm {
        mov   ecx, Msr
        mov   eax, lo
        mov   edx, hi
        _emit 0x0F
        _emit 0x30
    }
}

/* Guest-physical address of a kernel VA via the PD/PT self-map.  Treat the
 * PTE as a raw ULONG (as apic.c does): high 20 bits are the page frame, low
 * 12 bits of the VA are the in-page offset. */
static ULONG
HalpKvmVaToPa(PVOID Va)
{
    ULONG va  = (ULONG)Va;
    ULONG pte = *(volatile ULONG *)MiGetPteAddress(va);
    return (pte & 0xFFFFF000) | (va & 0xFFF);
}

static ULONGLONG
HalpKvmReadTsc(VOID)
{
    ULONG lo, hi;
    _asm { _emit 0x0F }     /* RDTSC = 0F 31 -> edx:eax */
    _asm { _emit 0x31 }
    _asm { mov lo, eax }
    _asm { mov hi, edx }
    return ((ULONGLONG)hi << 32) | lo;
}

/* pvclock delta scale: ns = (delta << shift) * mul >> 32, computed without a
 * 96-bit intermediate.  Split delta into 32-bit halves so each partial
 * product fits in 64 bits:  (deltaLo*mul >> 32) + deltaHi*mul. */
static ULONGLONG
HalpKvmScaleDelta(ULONGLONG Delta, ULONG Mul, CHAR Shift)
{
    ULONGLONG lo, hi;

    if (Shift >= 0) {
        Delta <<= Shift;
    } else {
        Delta >>= (-Shift);
    }
    lo = (ULONGLONG)(ULONG)Delta * Mul;
    hi = (ULONGLONG)(ULONG)(Delta >> 32) * Mul;
    return (lo >> 32) + hi;
}

/* Read system_time-since-host-reference in ns under the seqlock. */
static BOOLEAN
HalpKvmReadSystemNs(OUT ULONGLONG *SystemNs)
{
    ULONG i;

    for (i = 0; i < 100; i++) {
        ULONG     v1, v2, mul;
        CHAR      shift;
        ULONGLONG tsc_ts, sys, tsc;

        v1 = HalpKvmPvti->Version;
        if (v1 & 1) {
            continue;               /* host mid-update */
        }
        tsc_ts = HalpKvmPvti->TscTimestamp;
        sys    = HalpKvmPvti->SystemTime;
        mul    = HalpKvmPvti->TscToSystemMul;
        shift  = HalpKvmPvti->TscShift;
        tsc    = HalpKvmReadTsc();
        v2     = HalpKvmPvti->Version;
        if (v1 != v2) {
            continue;               /* raced an update; retry */
        }
        *SystemNs = sys + HalpKvmScaleDelta(tsc - tsc_ts, mul, shift);
        return TRUE;
    }
    return FALSE;
}

/* Read the wall-clock base (seconds/ns since 1970) under the seqlock. */
static BOOLEAN
HalpKvmReadWall(OUT ULONG *Sec, OUT ULONG *Nsec)
{
    ULONG i;

    for (i = 0; i < 100; i++) {
        ULONG v1, v2;

        v1 = HalpKvmPvWall->Version;
        if (v1 & 1) {
            continue;
        }
        *Sec  = HalpKvmPvWall->Sec;
        *Nsec = HalpKvmPvWall->Nsec;
        v2    = HalpKvmPvWall->Version;
        if (v1 == v2) {
            return TRUE;
        }
    }
    return FALSE;
}

/*
 * Epoch backend (PHALP_EPOCH_READ): current wall = wall_clock_base +
 * system_time, expressed as NT 100-ns since 1601.  Called once at clock
 * init through HalpEpochRead when kvmclock is the selected source.
 */
BOOLEAN
HalpEpochReadKvm(OUT PLARGE_INTEGER SystemTime)
{
    ULONG     sec = 0, nsec = 0;
    ULONGLONG sys_ns = 0, total_ns, nt100;

    if (!HalpKvmClockAvailable) {
        return FALSE;
    }
    if (!HalpKvmReadWall(&sec, &nsec) || !HalpKvmReadSystemNs(&sys_ns)) {
        return FALSE;
    }
    /* Sanity: a plausible host clock is well after 2017 (1.5e9).  Guards
     * against a host that advertised the feature but left the page zeroed. */
    if (sec < 1500000000UL) {
        return FALSE;
    }

    total_ns = (ULONGLONG)sec * 1000000000 + nsec + sys_ns;
    nt100    = total_ns / 100 + NT_1601_TO_1970_100NS;
    SystemTime->QuadPart = (LONGLONG)nt100;
    return TRUE;
}

/*
 * Probe for kvmclock and, if present, point the two MSRs at our shared
 * structures.  Called from HalpInitTscClock before HalpDetectClockSource.
 * Sets HalpKvmClockAvailable; returns the same value.
 */
BOOLEAN
HalpKvmClockInit(VOID)
{
    ULONG maxleaf = 0, ebx = 0, ecx = 0, edx = 0, feat = 0;
    ULONG base, pa_sys, pa_wall;
    CHAR  sig[12];

    /* pvclock layout is a host ABI; if the compiler packed it differently
     * the host would scribble at the wrong offsets.  Fail closed. */
    if (sizeof(PVCLOCK_VCPU_TIME_INFO) != 32 ||
        sizeof(PVCLOCK_WALL_CLOCK)     != 12) {
        HalpSerialPrint("HAL: kvmclock: pvclock struct size mismatch — disabled\r\n");
        return FALSE;
    }

    /* KVM hypervisor signature on leaf 0x40000000 ("KVMKVMKVM"), and the
     * KVM feature leaf must exist. */
    HalpCpuid(0x40000000, 0, &maxleaf, &ebx, &ecx, &edx);
    if (maxleaf < 0x40000001) {
        return FALSE;
    }
    sig[0] = (CHAR)ebx;        sig[1] = (CHAR)(ebx >> 8);
    sig[2] = (CHAR)(ebx >> 16); sig[3] = (CHAR)(ebx >> 24);
    sig[4] = (CHAR)ecx;        sig[5] = (CHAR)(ecx >> 8);
    sig[6] = (CHAR)(ecx >> 16); sig[7] = (CHAR)(ecx >> 24);
    sig[8] = (CHAR)edx;        sig[9] = (CHAR)(edx >> 8);
    sig[10] = (CHAR)(edx >> 16); sig[11] = (CHAR)(edx >> 24);
    if (sig[0] != 'K' || sig[1] != 'V' || sig[2] != 'M' || sig[3] != 'K' ||
        sig[4] != 'V' || sig[5] != 'M' || sig[6] != 'K' || sig[7] != 'V' ||
        sig[8] != 'M') {
        return FALSE;          /* not KVM — bare metal or another hypervisor */
    }

    HalpCpuid(0x40000001, 0, &feat, NULL, NULL, NULL);
    if (!(feat & KVM_FEATURE_CLOCKSOURCE2)) {
        HalpSerialPrint("HAL: kvmclock: CLOCKSOURCE2 not advertised\r\n");
        return FALSE;
    }

    /* Carve a 64-byte-aligned pvti, with wall_clock one line above it. */
    base = ((ULONG)HalpKvmPvRaw + 63) & ~((ULONG)63);
    HalpKvmPvti   = (volatile PVCLOCK_VCPU_TIME_INFO *)base;
    HalpKvmPvWall = (volatile PVCLOCK_WALL_CLOCK *)(base + 64);
    RtlZeroMemory((PVOID)base, 128);

    /* Hand the host the guest-physical addresses.  Bit 0 of the system_time
     * address is the MSR enable flag (our 64-byte alignment keeps it clear). */
    pa_sys  = HalpKvmVaToPa((PVOID)HalpKvmPvti);
    pa_wall = HalpKvmVaToPa((PVOID)HalpKvmPvWall);

    HalpWriteMsr(MSR_KVM_SYSTEM_TIME_NEW, (ULONGLONG)(pa_sys | 1));
    HalpWriteMsr(MSR_KVM_WALL_CLOCK_NEW,  (ULONGLONG)pa_wall);

    HalpKvmClockAvailable = TRUE;
    HalpSerialPrint("HAL: clock source candidate = kvmclock\r\n");
    return TRUE;
}
