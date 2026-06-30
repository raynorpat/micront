/*
 * ixpcibus.c — PCI bus handler for MicroNT HAL
 *
 * Direct PCI Type 1 config space access via CF8/CFC ports.
 * Bypasses ARC firmware configuration tree — probes hardware directly.
 *
 * Based on NT 3.5 HALX86 IXPCIBUS.C (Microsoft, Ken Reneris 1994).
 */

#include "halp.h"
#include "pci.h"
#include "pcip.h"

/* Spinlock functions from ntoskrnl */
KIRQL FASTCALL KfAcquireSpinLock(PKSPIN_LOCK SpinLock);
VOID FASTCALL KfReleaseSpinLock(PKSPIN_LOCK SpinLock, KIRQL OldIrql);
#define KeAcquireSpinLock(a,b) *(b) = KfAcquireSpinLock(a)
#define KeReleaseSpinLock(a,b) KfReleaseSpinLock(a,b)

/* PCI Type 1 config ports */
#define PCI_TYPE1_ADDR_PORT     ((PULONG) 0xCF8)
#define PCI_TYPE1_DATA_PORT     0xCFC

/* Spinlock for PCI config access serialization */
static KSPIN_LOCK HalpPCIConfigLock;

/*
 * 32-bit MMIO window we reclaim into for BAR relocation.
 *
 * Floor 0xC0000000  - default i440fx pci-hole-low base. Below this is
 *                     RAM (or the legacy ISA hole at 0xA0000-0xFFFFF)
 *                     and the chipset's PAM region; not safe.
 * Ceiling 0xFEC00000 - below the conventional IO-APIC (0xFEC00000),
 *                     LAPIC (0xFEE00000) and HPET (0xFED00000) MMIO.
 *                     Even though our HAL is PIC-only and never touches
 *                     the IOAPIC, the chipset still claims those addresses.
 *
 * Plenty of room (~764 MiB) for a handful of virtio BARs that are
 * typically 4 KiB each.
 */
#define HALP_PCI_LOW_BASE   0xC0000000UL
#define HALP_PCI_LOW_TOP    0xFEC00000UL


/*
 * Raw CF8/CFC PCI dword access. Used only during HalpInitializePciBus
 * (single-threaded boot context) for the BAR-relocation pass that runs
 * before bus handlers are registered. After init, drivers call through
 * HalGetBusData / HalSetBusData -> HalpReadPCIConfig with proper
 * locking.
 */
static ULONG
HalpRawPCIRead32(ULONG Bus, ULONG Dev, ULONG Func, ULONG RegDword)
{
    PCI_TYPE1_CFG_BITS cfg;
    ULONG val;
    cfg.u.AsULONG = 0;
    cfg.u.bits.BusNumber = Bus;
    cfg.u.bits.DeviceNumber = Dev;
    cfg.u.bits.FunctionNumber = Func;
    cfg.u.bits.RegisterNumber = RegDword;
    cfg.u.bits.Enable = 1;
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
    val = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT);
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, 0);
    return val;
}

static VOID
HalpRawPCIWrite32(ULONG Bus, ULONG Dev, ULONG Func, ULONG RegDword, ULONG Value)
{
    PCI_TYPE1_CFG_BITS cfg;
    cfg.u.AsULONG = 0;
    cfg.u.bits.BusNumber = Bus;
    cfg.u.bits.DeviceNumber = Dev;
    cfg.u.bits.FunctionNumber = Func;
    cfg.u.bits.RegisterNumber = RegDword;
    cfg.u.bits.Enable = 1;
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
    WRITE_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT, Value);
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, 0);
}

/*
 * Probe BAR size: write all-ones, read back the mask, restore original.
 * Caller must have already cleared PCI_ENABLE_MEMORY_SPACE / IO_SPACE
 * in the Command register before calling.
 *
 * For 64-bit BARs, RegDword should be the low half; pass nonzero
 * IsHigh64 to also probe the upper dword. Returns size in bytes
 * (0 if BAR is unimplemented), and writes back the original value(s).
 */
static ULONGLONG
HalpProbePCIBarSize(ULONG Bus, ULONG Dev, ULONG Func,
                    ULONG RegDword, BOOLEAN Is64Bit,
                    PULONG OrigLow, PULONG OrigHigh)
{
    ULONG mlow, mhi = 0;
    ULONGLONG mask64;
    ULONGLONG size;

    *OrigLow = HalpRawPCIRead32(Bus, Dev, Func, RegDword);
    if (Is64Bit) {
        *OrigHigh = HalpRawPCIRead32(Bus, Dev, Func, RegDword + 1);
    } else {
        *OrigHigh = 0;
    }

    HalpRawPCIWrite32(Bus, Dev, Func, RegDword, 0xFFFFFFFF);
    mlow = HalpRawPCIRead32(Bus, Dev, Func, RegDword);
    if (Is64Bit) {
        HalpRawPCIWrite32(Bus, Dev, Func, RegDword + 1, 0xFFFFFFFF);
        mhi = HalpRawPCIRead32(Bus, Dev, Func, RegDword + 1);
    }

    /* Restore */
    HalpRawPCIWrite32(Bus, Dev, Func, RegDword, *OrigLow);
    if (Is64Bit) {
        HalpRawPCIWrite32(Bus, Dev, Func, RegDword + 1, *OrigHigh);
    }

    /* Mask off type bits and compute size from one's-complement. */
    if ((*OrigLow & PCI_ADDRESS_IO_SPACE) != 0) {
        mlow &= ~0x3UL;
        if (mlow == 0) return 0;
        return (ULONGLONG)((~mlow + 1) & 0xFFFFUL);
    }
    mlow &= ~0xFUL;
    if (Is64Bit) {
        mask64 = ((ULONGLONG)mhi << 32) | mlow;
        if (mask64 == 0) return 0;
        size = (~mask64) + 1;
    } else {
        if (mlow == 0) return 0;
        size = (ULONGLONG)((~mlow) + 1);
    }
    return size;
}


/*
 * Walk every device's BARs to find the highest currently-used 32-bit
 * MMIO end address. The relocation pass allocates above this so we
 * don't collide with BARs the firmware already placed in the low
 * window (e.g. transitional virtio's I/O BAR0 has a separate I/O
 * decode and BAR2 is sometimes a 32-bit MMIO BAR; legacy VGA at
 * 0xFE000000+ on QEMU; etc.).
 *
 * Returns a base aligned up to a 64 KiB boundary.
 */
static ULONG
HalpFindLow32BarTop(ULONG MaxBus)
{
    ULONG bus, dev, func;
    ULONG top = HALP_PCI_LOW_BASE;

    for (bus = 0; bus <= MaxBus; bus++) {
        for (dev = 0; dev < 32; dev++) {
            for (func = 0; func < 8; func++) {
                ULONG vd, hdr;
                ULONG i;

                vd = HalpRawPCIRead32(bus, dev, func, 0);
                if ((vd & 0xFFFF) == 0xFFFF || (vd & 0xFFFF) == 0) {
                    if (func == 0) break;
                    continue;
                }
                hdr = HalpRawPCIRead32(bus, dev, func, 3);

                /* Only Type 0 (regular endpoint) here. Type 1 bridges
                 * use offsets 0x10/0x14 only and live elsewhere; skip. */
                if (((hdr >> 16) & 0x7F) != PCI_DEVICE_TYPE) {
                    continue;
                }

                for (i = 0; i < PCI_TYPE0_ADDRESSES; i++) {
                    ULONG bar = HalpRawPCIRead32(bus, dev, func, 4 + i);
                    BOOLEAN is64;
                    ULONGLONG paddr, end;
                    ULONG dummy_lo, dummy_hi;
                    ULONGLONG bsize;

                    if (bar == 0) continue;
                    if ((bar & PCI_ADDRESS_IO_SPACE) != 0) continue;

                    is64 = (bar & PCI_ADDRESS_MEMORY_TYPE_MASK) == PCI_TYPE_64BIT;
                    if (is64) {
                        ULONG hi = HalpRawPCIRead32(bus, dev, func, 4 + i + 1);
                        paddr = ((ULONGLONG)hi << 32) | (bar & ~0xFUL);
                        if (paddr >= 0x100000000ui64) {
                            /* Lives above 4 GiB - relocation target,
                             * doesn't constrain low free space. */
                            i++; /* skip high half */
                            continue;
                        }
                        i++; /* skip high half on next iteration */
                    } else {
                        paddr = (ULONGLONG)(bar & ~0xFUL);
                    }

                    if (paddr == 0) continue; /* unprogrammed */

                    bsize = HalpProbePCIBarSize(bus, dev, func, 4 + (i - (is64 ? 1 : 0)),
                                                is64, &dummy_lo, &dummy_hi);
                    if (bsize == 0) continue;
                    end = paddr + bsize;
                    if (end > 0xFFFFFFFFui64) end = 0xFFFFFFFFui64;
                    if ((ULONG)end > top) top = (ULONG)end;
                }

                if (func == 0) {
                    /* Single-function device check */
                    if (!((hdr >> 16) & PCI_MULTIFUNCTION)) break;
                }
            }
        }
    }

    /* Round up to 64 KiB - cheap alignment, plenty of slack. */
    top = (top + 0xFFFFUL) & ~0xFFFFUL;
    return top;
}


/*
 * BAR relocation pass: rewrite any PCI BAR placed by firmware above
 * 4 GiB into the low 32-bit MMIO window. NT 3.5 is non-PAE; physical
 * addresses must fit in 32 bits.
 *
 * On QEMU -machine pc (i440fx + PIIX3) all PCI devices sit on bus 0
 * directly off the host bridge - no PCI-to-PCI bridges, so no bridge
 * memory windows to widen. The host bridge accepts any address in
 * its pci-hole. (q35 with its PCIe root ports would also need
 * upstream-bridge Memory Base/Limit widening; not implemented.)
 */
static VOID
HalpRelocateHighPciBars(ULONG MaxBus)
{
    ULONG bus, dev, func;
    ULONG free_base;
    ULONG relocated = 0;

    free_base = HalpFindLow32BarTop(MaxBus);
    DbgPrint("HAL: BAR relocation: low free starts at %08x\n", free_base);

    for (bus = 0; bus <= MaxBus; bus++) {
        for (dev = 0; dev < 32; dev++) {
            for (func = 0; func < 8; func++) {
                ULONG vd, hdr;
                ULONG cmd;
                ULONG i;

                vd = HalpRawPCIRead32(bus, dev, func, 0);
                if ((vd & 0xFFFF) == 0xFFFF || (vd & 0xFFFF) == 0) {
                    if (func == 0) break;
                    continue;
                }
                hdr = HalpRawPCIRead32(bus, dev, func, 3);
                if (((hdr >> 16) & 0x7F) != PCI_DEVICE_TYPE) continue;

                cmd = HalpRawPCIRead32(bus, dev, func, 1);

                for (i = 0; i < PCI_TYPE0_ADDRESSES; i++) {
                    ULONG bar = HalpRawPCIRead32(bus, dev, func, 4 + i);
                    ULONG hi;
                    BOOLEAN is64;
                    ULONGLONG paddr;
                    ULONGLONG bsize;
                    ULONG orig_lo, orig_hi;
                    ULONG new_base, mask;

                    if (bar == 0) continue;
                    if ((bar & PCI_ADDRESS_IO_SPACE) != 0) continue;

                    is64 = (bar & PCI_ADDRESS_MEMORY_TYPE_MASK) == PCI_TYPE_64BIT;
                    if (!is64) continue;  /* 32-bit BARs already addressable */

                    hi = HalpRawPCIRead32(bus, dev, func, 4 + i + 1);
                    paddr = ((ULONGLONG)hi << 32) | (bar & ~0xFUL);
                    if (paddr < 0x100000000ui64) {
                        /* 64-bit BAR but already in low 32 bits - leave alone */
                        i++;
                        continue;
                    }

                    /* Disable memory decode while we rewrite. */
                    HalpRawPCIWrite32(bus, dev, func, 1,
                                      cmd & ~(PCI_ENABLE_MEMORY_SPACE | PCI_ENABLE_BUS_MASTER));

                    bsize = HalpProbePCIBarSize(bus, dev, func, 4 + i,
                                                TRUE, &orig_lo, &orig_hi);
                    if (bsize == 0 || bsize > 0x40000000ui64 /* 1 GiB sanity cap */) {
                        DbgPrint("HAL: %d:%d.%d BAR%d sizing failed (size=%lx_%08lx), skipped\n",
                                 bus, dev, func, i,
                                 (ULONG)(bsize >> 32), (ULONG)bsize);
                        HalpRawPCIWrite32(bus, dev, func, 1, cmd);
                        i++;
                        continue;
                    }

                    /* Align free_base up to bsize boundary. */
                    mask = (ULONG)(bsize - 1);
                    new_base = (free_base + mask) & ~mask;

                    if ((ULONGLONG)new_base + bsize > (ULONGLONG)HALP_PCI_LOW_TOP) {
                        DbgPrint("HAL: %d:%d.%d BAR%d (size %lx_%08lx) - low MMIO window exhausted, skipped\n",
                                 bus, dev, func, i,
                                 (ULONG)(bsize >> 32), (ULONG)bsize);
                        HalpRawPCIWrite32(bus, dev, func, 1, cmd);
                        i++;
                        continue;
                    }

                    /* Preserve type bits (prefetch, 64-bit) from the original low half. */
                    HalpRawPCIWrite32(bus, dev, func, 4 + i,
                                      new_base | (orig_lo & 0xFUL));
                    HalpRawPCIWrite32(bus, dev, func, 4 + i + 1, 0);

                    DbgPrint("HAL: %d:%d.%d BAR%d relocated %08x_%08x -> %08x (size %lx_%08lx)\n",
                             bus, dev, func, i,
                             (ULONG)(paddr >> 32), (ULONG)paddr,
                             new_base,
                             (ULONG)(bsize >> 32), (ULONG)bsize);

                    free_base = new_base + (ULONG)bsize;
                    relocated++;

                    /* Restore Command register (re-enable memory decode). */
                    HalpRawPCIWrite32(bus, dev, func, 1, cmd | PCI_ENABLE_MEMORY_SPACE);

                    i++; /* skip high half */
                }

                if (func == 0 && !((hdr >> 16) & PCI_MULTIFUNCTION)) break;
            }
        }
    }

    DbgPrint("HAL: BAR relocation: %d BAR(s) moved into low window\n", relocated);
}

/* Config I/O function type: read or write one unit at Offset */
typedef ULONG (*FncConfigIO) (
    IN PPCIBUSDATA      BusData,
    IN PPCI_TYPE1_CFG_BITS PciCfg1,
    IN PUCHAR           Buffer,
    IN ULONG            Offset
    );

/* Dispatch table indexed by PCIDeref[Offset%4][Length%4] */
static UCHAR PCIDeref[4][4] = {
    { 0, 1, 2, 2 },
    { 1, 1, 1, 1 },
    { 2, 1, 2, 2 },
    { 1, 1, 1, 1 }
};

ULONG HalpGetPCIData (
    IN PBUSHANDLER BusHandler,
    IN PVOID RootHandler,
    IN ULONG SlotNumber,
    IN PVOID Buffer,
    IN ULONG Offset,
    IN ULONG Length
    );

ULONG HalpSetPCIData (
    IN PBUSHANDLER BusHandler,
    IN PVOID RootHandler,
    IN ULONG SlotNumber,
    IN PVOID Buffer,
    IN ULONG Offset,
    IN ULONG Length
    );

NTSTATUS HalpAssignPCISlotResources (
    IN PVOID BusHandler,
    IN PVOID RootHandler,
    IN PUNICODE_STRING RegistryPath,
    IN PUNICODE_STRING DriverClassName OPTIONAL,
    IN PDRIVER_OBJECT DriverObject,
    IN PDEVICE_OBJECT DeviceObject OPTIONAL,
    IN ULONG SlotNumber,
    IN OUT PCM_RESOURCE_LIST *AllocatedResources
    );


/*
 * Find the next free slot under \Hardware\Description\System\MultifunctionAdapter.
 *
 * NTDETECT's classic convention is numeric subkey names "0", "1", ... , one
 * per bus. Our UEFI loader's `hwtree.c` populates whatever it could
 * enumerate before ExitBootServices (currently the ISA bus at slot 0). The
 * HAL runs later and needs to append its own entries (PCI bus, eventually
 * ACPI-discovered buses) without colliding with the loader's work.
 *
 * We enumerate the existing subkeys, treat any all-digit name as a claimed
 * slot, and return max(claimed) + 1 (or 0 if nothing is present).
 */
static ULONG
HalpNextMultifunctionAdapterSlot(HANDLE MfKey)
{
    UCHAR Buffer[96];
    PKEY_BASIC_INFORMATION info = (PKEY_BASIC_INFORMATION)Buffer;
    ULONG i, retLength;
    ULONG maxSlot = 0;
    BOOLEAN foundAny = FALSE;

    for (i = 0; ; i++) {
        NTSTATUS st = ZwEnumerateKey(MfKey, i, KeyBasicInformation,
                                     info, sizeof(Buffer), &retLength);
        if (!NT_SUCCESS(st)) break;

        /* Parse Name as decimal integer. Non-digit names (shouldn't exist
         * under this key, but don't trust it) are skipped, not counted. */
        {
            ULONG nameChars = info->NameLength / sizeof(WCHAR);
            ULONG slot = 0;
            BOOLEAN valid = (nameChars > 0);
            ULONG k;
            for (k = 0; k < nameChars; k++) {
                WCHAR c = info->Name[k];
                if (c < L'0' || c > L'9') { valid = FALSE; break; }
                slot = slot * 10 + (c - L'0');
            }
            if (!valid) continue;
            if (!foundAny || slot > maxSlot) maxSlot = slot;
            foundAny = TRUE;
        }
    }

    return foundAny ? maxSlot + 1 : 0;
}

/*
 * HalpInitializePciBus — probe for PCI Type 1 config access and
 * register bus handler(s). Called from HalReportResourceUsage.
 */
VOID
HalpInitializePciBus(VOID)
{
    PBUSHANDLER Bus;
    PPCIBUSDATA BusData;
    ULONG VendorId;
    ULONG MaxBus;
    ULONG i;

    KeInitializeSpinLock(&HalpPCIConfigLock);

    /* Probe: write to CF8, read back to verify Type 1 access works */
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, 0x80000000);
    if (READ_PORT_ULONG(PCI_TYPE1_ADDR_PORT) != 0x80000000) {
        DbgPrint("HAL: PCI Type 1 config access not available\n");
        return;
    }
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, 0);

    /* Check bus 0 device 0 vendor ID */
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, 0x80000000);
    VendorId = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT) & 0xFFFF;
    if (VendorId == 0xFFFF || VendorId == 0) {
        DbgPrint("HAL: PCI bus 0 device 0 not present (vendor=%04lx)\n", VendorId);
        return;
    }

    DbgPrint("HAL: PCI Type 1 detected, bus 0 device 0 vendor=%04lx\n", VendorId);

    /* Scan for max bus number by checking bus N device 0.
     * Q35 typically has bus 0 only (unless PCI bridges exist). */
    MaxBus = 0;
    for (i = 1; i < 256; i++) {
        PCI_TYPE1_CFG_BITS cfg;
        ULONG vid;
        cfg.u.AsULONG = 0;
        cfg.u.bits.BusNumber = i;
        cfg.u.bits.Enable = 1;
        WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
        vid = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT) & 0xFFFF;
        if (vid != 0xFFFF && vid != 0) {
            MaxBus = i;
        }
    }
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, 0);

    DbgPrint("HAL: PCI max bus = %d\n", MaxBus);

    /* Dump all devices on each bus */
    for (i = 0; i <= MaxBus; i++) {
        ULONG dev, func;
        for (dev = 0; dev < 32; dev++) {
            for (func = 0; func < 8; func++) {
                PCI_TYPE1_CFG_BITS cfg;
                ULONG data;
                cfg.u.AsULONG = 0;
                cfg.u.bits.BusNumber = i;
                cfg.u.bits.DeviceNumber = dev;
                cfg.u.bits.FunctionNumber = func;
                cfg.u.bits.Enable = 1;
                WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
                data = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT);
                if ((data & 0xFFFF) != 0xFFFF && (data & 0xFFFF) != 0) {
                    ULONG class;
                    cfg.u.bits.RegisterNumber = 2;
                    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
                    class = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT);
                    {
                        ULONG bar0, bar1, bar2;
                        cfg.u.bits.RegisterNumber = 4; /* BAR0 at offset 0x10 */
                        WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
                        bar0 = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT);
                        cfg.u.bits.RegisterNumber = 5; /* BAR1 at offset 0x14 */
                        WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
                        bar1 = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT);
                        cfg.u.bits.RegisterNumber = 6; /* BAR2 at offset 0x18 */
                        WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, cfg.u.AsULONG);
                        bar2 = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT);
                        DbgPrint("HAL: PCI %d:%d.%d %04x:%04x class=%02x.%02x BAR=%08x/%08x/%08x\n",
                                 i, dev, func,
                                 data & 0xFFFF, (data >> 16) & 0xFFFF,
                                 (class >> 24) & 0xFF, (class >> 16) & 0xFF,
                                 bar0, bar1, bar2);
                    }
                }
                if (func == 0) {
                    PCI_TYPE1_CFG_BITS hdr;
                    ULONG hdrtype;
                    hdr.u.AsULONG = 0;
                    hdr.u.bits.BusNumber = i;
                    hdr.u.bits.DeviceNumber = dev;
                    hdr.u.bits.FunctionNumber = 0;
                    hdr.u.bits.RegisterNumber = 3;
                    hdr.u.bits.Enable = 1;
                    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, hdr.u.AsULONG);
                    hdrtype = READ_PORT_ULONG((PULONG)PCI_TYPE1_DATA_PORT);
                    if (!((hdrtype >> 16) & 0x80)) break;
                }
            }
        }
    }
    WRITE_PORT_ULONG(PCI_TYPE1_ADDR_PORT, 0);

    /* Pull any > 4 GiB BARs down into the low 32-bit MMIO window
     * before drivers see them. NT 3.5 is non-PAE so high BARs are
     * unreachable; firmware (OVMF) places virtio modern-transport
     * BARs in the 64-bit window by default. */
    HalpRelocateHighPciBars(MaxBus);

    /* Register PCI bus handlers */
    for (i = 0; i <= MaxBus; i++) {
        Bus = HalpAllocateBusHandler(
            PCIBus,                     /* InterfaceType */
            PCIConfiguration,           /* BusDataType */
            i,                          /* BusNumber */
            Internal,                   /* ParentBusDataType */
            0,                          /* ParentBusNumber */
            sizeof(PCIBUSDATA)          /* BusSpecificData */
        );

        BusData = (PPCIBUSDATA) Bus->BusData;
        BusData->Config.Type1.Address = PCI_TYPE1_ADDR_PORT;
        BusData->Config.Type1.Data = PCI_TYPE1_DATA_PORT;
        BusData->MaxDevice = PCI_MAX_DEVICES;

        /* Allow the full 32-bit address range for memory and I/O.
         * On UEFI/Q35 there are no ISA holes to worry about. */
        BusData->MemoryBase = 0;
        BusData->MemoryLimit = 0xFFFFFFFF;
        BusData->PFMemoryBase = 0;
        BusData->PFMemoryLimit = 0xFFFFFFFF;
        BusData->IOBase = 0;
        BusData->IOLimit = 0xFFFF;

        Bus->GetBusData = (PGETSETBUSDATA) HalpGetPCIData;
        Bus->SetBusData = (PGETSETBUSDATA) HalpSetPCIData;
        Bus->TranslateBusAddress = (PTRANSLATEBUSADDRESS) HalpTranslatePCIBusAddress;
        Bus->AdjustResourceList = (PADJUSTRESOURCELIST) HalpAdjustPCIResourceList;
        Bus->AssignSlotResources = (PASSIGNSLOTRESOURCES) HalpAssignPCISlotResources;
        Bus->GetInterruptVector = (PGETINTERRUPTVECTOR) HalpGetPCIIntOnISABus;

        HalpSetBusHandlerParent(Bus, Bus->ParentHandler);
    }

    DbgPrint("HAL: registered %d PCI bus(es)\n", MaxBus + 1);

    /*
     * Populate the ARC configuration tree so IoQueryDeviceDescription(PCIBus)
     * finds our bus. VideoPortInitialize uses this to discover adapters.
     *
     * Append at the next free MultifunctionAdapter\N slot — the UEFI loader
     * populated slots in hwtree.c (currently just ISA at 0), and we don't
     * want to clobber its work. The number we pick here is opaque to
     * callers: IoQueryDeviceDescription finds us by matching the bus's
     * InterfaceType (PCIBus) against the query argument.
     */
    {
        UNICODE_STRING Name;
        OBJECT_ATTRIBUTES ObjAttr;
        HANDLE MfKey, BusKey;
        NTSTATUS st;
        ULONG disp;

        /* Create intermediate keys if they don't exist */
        {
            static WCHAR *paths[] = {
                L"\\Registry\\Machine\\Hardware",
                L"\\Registry\\Machine\\Hardware\\Description",
                L"\\Registry\\Machine\\Hardware\\Description\\System",
                NULL
            };
            ULONG pi;
            for (pi = 0; paths[pi]; pi++) {
                HANDLE tmp;
                RtlInitUnicodeString(&Name, paths[pi]);
                InitializeObjectAttributes(&ObjAttr, &Name, OBJ_CASE_INSENSITIVE, NULL, NULL);
                if (NT_SUCCESS(ZwCreateKey(&tmp, KEY_WRITE, &ObjAttr, 0, NULL, REG_OPTION_VOLATILE, &disp))) {
                    ZwClose(tmp);
                }
            }
        }

        RtlInitUnicodeString(&Name,
            L"\\Registry\\Machine\\Hardware\\Description\\System\\MultifunctionAdapter");
        InitializeObjectAttributes(&ObjAttr, &Name, OBJ_CASE_INSENSITIVE, NULL, NULL);
        st = ZwCreateKey(&MfKey, KEY_READ | KEY_WRITE, &ObjAttr, 0, NULL,
                         REG_OPTION_VOLATILE, &disp);
        if (NT_SUCCESS(st)) {
            ULONG slot = HalpNextMultifunctionAdapterSlot(MfKey);
            WCHAR SlotBuffer[16];
            UNICODE_STRING SlotName;

            SlotName.Buffer = SlotBuffer;
            SlotName.MaximumLength = sizeof(SlotBuffer);
            SlotName.Length = 0;
            RtlIntegerToUnicodeString(slot, 10, &SlotName);

            InitializeObjectAttributes(&ObjAttr, &SlotName, OBJ_CASE_INSENSITIVE, MfKey, NULL);
            st = ZwCreateKey(&BusKey, KEY_WRITE, &ObjAttr, 0, NULL, REG_OPTION_VOLATILE, &disp);
            if (NT_SUCCESS(st)) {
                WCHAR PciId[] = L"PCI";
                CM_FULL_RESOURCE_DESCRIPTOR CmDesc;

                RtlInitUnicodeString(&Name, L"Identifier");
                ZwSetValueKey(BusKey, &Name, 0, REG_SZ, PciId, sizeof(PciId));

                RtlZeroMemory(&CmDesc, sizeof(CmDesc));
                CmDesc.InterfaceType = PCIBus;
                CmDesc.BusNumber = 0;
                RtlInitUnicodeString(&Name, L"Configuration Data");
                ZwSetValueKey(BusKey, &Name, 0, REG_FULL_RESOURCE_DESCRIPTOR,
                              &CmDesc, sizeof(CmDesc));

                DbgPrint("HAL: created MultifunctionAdapter\\%u PCI ConfigData\n",
                         slot);
                ZwClose(BusKey);
            }
            ZwClose(MfKey);
        }
    }
}


/* ===== PCI config read/write ===== */

VOID
HalpPCISynchronizeType1(
    IN PBUSHANDLER BusHandler,
    IN PCI_SLOT_NUMBER Slot,
    IN PKIRQL Irql,
    IN PVOID State
    )
{
    PPCI_TYPE1_CFG_BITS Cfg = (PPCI_TYPE1_CFG_BITS) State;
    PPCIBUSDATA BusData = (PPCIBUSDATA) BusHandler->BusData;

    KeAcquireSpinLock(&HalpPCIConfigLock, Irql);

    Cfg->u.AsULONG = 0;
    Cfg->u.bits.BusNumber = BusHandler->BusNumber;
    Cfg->u.bits.DeviceNumber = Slot.u.bits.DeviceNumber;
    Cfg->u.bits.FunctionNumber = Slot.u.bits.FunctionNumber;
    Cfg->u.bits.Enable = TRUE;
}

VOID
HalpPCIReleaseSynchronzationType1(
    IN PBUSHANDLER BusHandler,
    IN KIRQL Irql
    )
{
    PPCIBUSDATA BusData = (PPCIBUSDATA) BusHandler->BusData;
    WRITE_PORT_ULONG(BusData->Config.Type1.Address, 0);
    KeReleaseSpinLock(&HalpPCIConfigLock, Irql);
}


ULONG
HalpPCIReadUcharType1(
    IN PPCIBUSDATA BusData,
    IN PPCI_TYPE1_CFG_BITS PciCfg1,
    IN PUCHAR Buffer,
    IN ULONG Offset
    )
{
    ULONG i = Offset % sizeof(ULONG);
    PciCfg1->u.bits.RegisterNumber = Offset / sizeof(ULONG);
    WRITE_PORT_ULONG(BusData->Config.Type1.Address, PciCfg1->u.AsULONG);
    *Buffer = READ_PORT_UCHAR((PUCHAR)(BusData->Config.Type1.Data + i));
    return sizeof(UCHAR);
}

ULONG
HalpPCIReadUshortType1(
    IN PPCIBUSDATA BusData,
    IN PPCI_TYPE1_CFG_BITS PciCfg1,
    IN PUCHAR Buffer,
    IN ULONG Offset
    )
{
    ULONG i = Offset % sizeof(ULONG);
    PciCfg1->u.bits.RegisterNumber = Offset / sizeof(ULONG);
    WRITE_PORT_ULONG(BusData->Config.Type1.Address, PciCfg1->u.AsULONG);
    *((PUSHORT)Buffer) = READ_PORT_USHORT((PUSHORT)(BusData->Config.Type1.Data + i));
    return sizeof(USHORT);
}

ULONG
HalpPCIReadUlongType1(
    IN PPCIBUSDATA BusData,
    IN PPCI_TYPE1_CFG_BITS PciCfg1,
    IN PUCHAR Buffer,
    IN ULONG Offset
    )
{
    PciCfg1->u.bits.RegisterNumber = Offset / sizeof(ULONG);
    WRITE_PORT_ULONG(BusData->Config.Type1.Address, PciCfg1->u.AsULONG);
    *((PULONG)Buffer) = READ_PORT_ULONG((PULONG)BusData->Config.Type1.Data);
    return sizeof(ULONG);
}

ULONG
HalpPCIWriteUcharType1(
    IN PPCIBUSDATA BusData,
    IN PPCI_TYPE1_CFG_BITS PciCfg1,
    IN PUCHAR Buffer,
    IN ULONG Offset
    )
{
    ULONG i = Offset % sizeof(ULONG);
    PciCfg1->u.bits.RegisterNumber = Offset / sizeof(ULONG);
    WRITE_PORT_ULONG(BusData->Config.Type1.Address, PciCfg1->u.AsULONG);
    WRITE_PORT_UCHAR((PUCHAR)(BusData->Config.Type1.Data + i), *Buffer);
    return sizeof(UCHAR);
}

ULONG
HalpPCIWriteUshortType1(
    IN PPCIBUSDATA BusData,
    IN PPCI_TYPE1_CFG_BITS PciCfg1,
    IN PUCHAR Buffer,
    IN ULONG Offset
    )
{
    ULONG i = Offset % sizeof(ULONG);
    PciCfg1->u.bits.RegisterNumber = Offset / sizeof(ULONG);
    WRITE_PORT_ULONG(BusData->Config.Type1.Address, PciCfg1->u.AsULONG);
    WRITE_PORT_USHORT((PUSHORT)(BusData->Config.Type1.Data + i), *((PUSHORT)Buffer));
    return sizeof(USHORT);
}

ULONG
HalpPCIWriteUlongType1(
    IN PPCIBUSDATA BusData,
    IN PPCI_TYPE1_CFG_BITS PciCfg1,
    IN PUCHAR Buffer,
    IN ULONG Offset
    )
{
    PciCfg1->u.bits.RegisterNumber = Offset / sizeof(ULONG);
    WRITE_PORT_ULONG(BusData->Config.Type1.Address, PciCfg1->u.AsULONG);
    WRITE_PORT_ULONG((PULONG)BusData->Config.Type1.Data, *((PULONG)Buffer));
    return sizeof(ULONG);
}


/* ===== HalpReadPCIConfig / HalpWritePCIConfig ===== */

static VOID
HalpPCIConfig(
    IN PBUSHANDLER BusHandler,
    IN PCI_SLOT_NUMBER Slot,
    IN PUCHAR Buffer,
    IN ULONG Offset,
    IN ULONG Length,
    IN FncConfigIO ConfigIO[3]
    )
{
    KIRQL OldIrql;
    PCI_TYPE1_CFG_BITS PciCfg1;
    PPCIBUSDATA BusData;
    ULONG i;

    BusData = (PPCIBUSDATA) BusHandler->BusData;

    HalpPCISynchronizeType1(BusHandler, Slot, &OldIrql, &PciCfg1);

    while (Length) {
        i = PCIDeref[Offset % sizeof(ULONG)][Length % sizeof(ULONG)];
        i = ConfigIO[i](BusData, &PciCfg1, Buffer, Offset);
        Offset += i;
        Buffer += i;
        Length -= i;
    }

    HalpPCIReleaseSynchronzationType1(BusHandler, OldIrql);
}

VOID
HalpReadPCIConfig(
    IN PBUSHANDLER BusHandler,
    IN PCI_SLOT_NUMBER Slot,
    IN PVOID Buffer,
    IN ULONG Offset,
    IN ULONG Length
    )
{
    if (!BusHandler->BusData) {
        RtlFillMemory(Buffer, Length, 0xFF);
        return;
    }
    {
        static FncConfigIO ReadIO[3] = {
            HalpPCIReadUlongType1,
            HalpPCIReadUcharType1,
            HalpPCIReadUshortType1
        };
        HalpPCIConfig(BusHandler, Slot, Buffer, Offset, Length, ReadIO);
    }
}

VOID
HalpWritePCIConfig(
    IN PBUSHANDLER BusHandler,
    IN PCI_SLOT_NUMBER Slot,
    IN PVOID Buffer,
    IN ULONG Offset,
    IN ULONG Length
    )
{
    if (!BusHandler->BusData) {
        return;
    }
    {
        static FncConfigIO WriteIO[3] = {
            HalpPCIWriteUlongType1,
            HalpPCIWriteUcharType1,
            HalpPCIWriteUshortType1
        };
        HalpPCIConfig(BusHandler, Slot, Buffer, Offset, Length, WriteIO);
    }
}


/* ===== GetBusData / SetBusData for PCI ===== */

/* Standard PCI config space is 256 bytes (CF8/CFC reaches the full
   range — Offset register is 8 bits). The stock NT 3.5 HAL handles
   this via a separate device-specific read path below the 64-byte
   header; we collapse to a single clamp at MaxLen since our
   HalpReadPCIConfig already does sub-dword chunking correctly.
   PCIe extended config (256..4095) needs MMCONFIG which we don't
   support — but the standard 256 bytes are enough to walk the PCI
   capability list, which is where modern virtio caps live. */

ULONG
HalpGetPCIData(
    IN PBUSHANDLER BusHandler,
    IN PVOID RootHandler,
    IN ULONG SlotNumber,
    IN PVOID Buffer,
    IN ULONG Offset,
    IN ULONG Length
    )
{
    PCI_SLOT_NUMBER Slot;
    USHORT VendorId;
    ULONG  Avail;
    const ULONG MaxLen = sizeof(PCI_COMMON_CONFIG);

    if (Length == 0) return 0;

    Slot.u.AsULONG = SlotNumber;
    if (Slot.u.bits.DeviceNumber >= PCI_MAX_DEVICES) return 0;

    /* Existence probe — cheaper than reading the whole 64-byte header. */
    HalpReadPCIConfig(BusHandler, Slot, &VendorId, 0, sizeof(VendorId));
    if (VendorId == 0xFFFF) {
        RtlFillMemory(Buffer, Length, 0xFF);
        return 2;  /* return 2 = device doesn't exist */
    }

    if (Offset >= MaxLen) return 0;
    Avail = MaxLen - Offset;
    if (Length > Avail) Length = Avail;

    HalpReadPCIConfig(BusHandler, Slot, Buffer, Offset, Length);
    return Length;
}

ULONG
HalpSetPCIData(
    IN PBUSHANDLER BusHandler,
    IN PVOID RootHandler,
    IN ULONG SlotNumber,
    IN PVOID Buffer,
    IN ULONG Offset,
    IN ULONG Length
    )
{
    PCI_SLOT_NUMBER Slot;
    ULONG  Avail;
    const ULONG MaxLen = sizeof(PCI_COMMON_CONFIG);

    if (Length == 0) return 0;

    Slot.u.AsULONG = SlotNumber;
    if (Slot.u.bits.DeviceNumber >= PCI_MAX_DEVICES) return 0;

    if (Offset >= MaxLen) return 0;
    Avail = MaxLen - Offset;
    if (Length > Avail) Length = Avail;

    HalpWritePCIConfig(BusHandler, Slot, Buffer, Offset, Length);
    return Length;
}


/* ===== Stub AssignSlotResources for PCI ===== */

NTSTATUS
HalpAssignPCISlotResources(
    IN PVOID BusHandlerV,
    IN PVOID RootHandlerV,
    IN PUNICODE_STRING RegistryPath,
    IN PUNICODE_STRING DriverClassName OPTIONAL,
    IN PDRIVER_OBJECT DriverObject,
    IN PDEVICE_OBJECT DeviceObject OPTIONAL,
    IN ULONG SlotNumber,
    IN OUT PCM_RESOURCE_LIST *AllocatedResources
    )
{
    PBUSHANDLER Handler = (PBUSHANDLER)BusHandlerV;
    PCI_SLOT_NUMBER Slot;
    PCI_COMMON_CONFIG PciConfig;
    ULONG NumBars, i, ResCount;
    ULONG ListSize;
    PCM_RESOURCE_LIST CmList;
    PCM_PARTIAL_RESOURCE_DESCRIPTOR Desc;

    Slot.u.AsULONG = SlotNumber;
    HalpReadPCIConfig(Handler, Slot, &PciConfig, 0, PCI_COMMON_HDR_LENGTH);
    if (PciConfig.VendorID == PCI_INVALID_VENDORID) {
        return STATUS_NO_SUCH_DEVICE;
    }

    /* Count BARs (Type 0 has 6, skip 64-bit high halves) */
    NumBars = PCI_TYPE0_ADDRESSES;
    ResCount = 0;
    for (i = 0; i < NumBars; i++) {
        if (PciConfig.u.type0.BaseAddresses[i]) ResCount++;
    }
    /* Add one for the interrupt if present */
    if (PciConfig.u.type0.InterruptLine && PciConfig.u.type0.InterruptLine != 0xFF) {
        ResCount++;
    }

    ListSize = sizeof(CM_RESOURCE_LIST) +
               (ResCount ? (ResCount - 1) : 0) * sizeof(CM_PARTIAL_RESOURCE_DESCRIPTOR);
    CmList = (PCM_RESOURCE_LIST)ExAllocatePool(PagedPool, ListSize);
    if (!CmList) return STATUS_INSUFFICIENT_RESOURCES;
    RtlZeroMemory(CmList, ListSize);

    CmList->Count = 1;
    CmList->List[0].InterfaceType = PCIBus;
    CmList->List[0].BusNumber = Handler->BusNumber;
    CmList->List[0].PartialResourceList.Count = ResCount;

    Desc = CmList->List[0].PartialResourceList.PartialDescriptors;

    for (i = 0; i < NumBars; i++) {
        ULONG Bar = PciConfig.u.type0.BaseAddresses[i];
        ULONG BarSize, Mask, BarOffset;
        if (!Bar) continue;

        /* BAR sizing: write all-1s, read back mask, restore original */
        BarOffset = FIELD_OFFSET(PCI_COMMON_CONFIG, u.type0.BaseAddresses[i]);
        Mask = 0xFFFFFFFF;
        HalpWritePCIConfig(Handler, Slot, &Mask, BarOffset, sizeof(ULONG));
        HalpReadPCIConfig(Handler, Slot, &Mask, BarOffset, sizeof(ULONG));
        HalpWritePCIConfig(Handler, Slot, &Bar, BarOffset, sizeof(ULONG));

        if (Bar & PCI_ADDRESS_IO_SPACE) {
            Mask &= ~3;
            BarSize = (~Mask + 1) & 0xFFFF;
            Desc->Type = CmResourceTypePort;
            Desc->Flags = CM_RESOURCE_PORT_IO;
            Desc->u.Port.Start.LowPart = Bar & ~3;
            Desc->u.Port.Start.HighPart = 0;
            Desc->u.Port.Length = BarSize;
        } else {
            Mask &= ~0xF;
            BarSize = ~Mask + 1;
            Desc->Type = CmResourceTypeMemory;
            Desc->Flags = CM_RESOURCE_MEMORY_READ_WRITE;
            Desc->u.Memory.Start.LowPart = Bar & ~0xF;
            Desc->u.Memory.Start.HighPart = 0;
            Desc->u.Memory.Length = BarSize;
        }
        Desc++;
    }

    if (PciConfig.u.type0.InterruptLine && PciConfig.u.type0.InterruptLine != 0xFF) {
        Desc->Type = CmResourceTypeInterrupt;
        Desc->Flags = CM_RESOURCE_INTERRUPT_LEVEL_SENSITIVE;
        Desc->u.Interrupt.Level = PciConfig.u.type0.InterruptLine;
        Desc->u.Interrupt.Vector = PciConfig.u.type0.InterruptLine;
        Desc->u.Interrupt.Affinity = 1;
        Desc++;
    }

    *AllocatedResources = CmList;
    return STATUS_SUCCESS;
}


