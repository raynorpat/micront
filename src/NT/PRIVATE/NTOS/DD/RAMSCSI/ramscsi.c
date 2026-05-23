/*++

    ramscsi.c -- RAM-disk SCSI miniport for MicroNT.

    Presents the in-RAM MBR+FAT16 disk image (the PVH initrd) as a SCSI
    disk, so scsidisk surfaces it as the boot/system volume.  Ported from
    the Gary Nebbett NT4 RAM-SCSI sample (vendor "NEBBETT"), adapted to
    MicroNT:

      - The disk's physical base + byte length are NOT hardcoded and NOT
        read from a FAT BPB (our image is MBR + partition(1); sector 0 is
        the MBR, not a BPB).  Instead the boot loader writes them into our
        RAMDCFG data section while staging this .sys -- it finds the
        section by name and fills it (boot/vmlinuz/main.c + pe_find_section).
        We read them in HwFindAdapter.
      - Physical RAM is mapped on demand, one page at a time, via
        ScsiPortGetDeviceBase (works during Phase 0/1 boot), cached in the
        device extension.  Geometry = length / 512 sectors.
      - All SRBs complete synchronously in HwStartIo; there is no hardware
        and no interrupt.

    Scaffolding (DriverEntry / HwFindAdapter / HwStartIo) mirrors vioblk.c
    so build + boot integration is identical.

--*/

#include <ntddk.h>
#include <scsi.h>
#include <srb.h>

#define RAMD_MAGIC        0x52414D44u   /* 'RAMD' */
#define RAMSCSI_SECTOR    512

/* Page-pointer cache covers up to 32 MiB (8192 * 4 KiB), matching the
 * Nebbett reference.  The default/smoke ramdisk is ~14 MiB. */
#define RAMSCSI_MAX_PAGES 8192

/* Filled by the boot loader while staging this driver: it locates the
 * "RAMDCFG" section in our image and writes the initrd's physical base +
 * byte length.  Must be INITIALIZED so it lands in the named data section
 * rather than BSS. */
#pragma data_seg("RAMDCFG")
volatile struct { ULONG Magic; ULONG Base; ULONG Len; }
    RamDiskCfg = { RAMD_MAGIC, 0, 0 };
#pragma data_seg()

typedef struct _RAMSCSI_DEV_EXT {
    ULONG Base;                       /* phys base of disk (sector 0 = MBR) */
    ULONG Blocks;                     /* total 512-byte sectors            */
    PVOID Page[RAMSCSI_MAX_PAGES];    /* on-demand page-map cache          */
} RAMSCSI_DEV_EXT, *PRAMSCSI_DEV_EXT;

/* Map (and cache) the 4 KiB page containing physical address `phys`,
 * returning a kernel VA for `phys` itself. */
static PVOID
RamScsiMapPage(PRAMSCSI_DEV_EXT Ext, ULONG phys)
{
    ULONG idx = (phys - Ext->Base) >> 12;
    if (idx >= RAMSCSI_MAX_PAGES) return NULL;
    if (Ext->Page[idx] == NULL) {
        Ext->Page[idx] = ScsiPortGetDeviceBase(
            Ext, Internal, 0,
            ScsiPortConvertUlongToPhysicalAddress(phys & ~0xFFFu),
            0x1000, FALSE);
        if (Ext->Page[idx] == NULL) return NULL;
    }
    return (PUCHAR)Ext->Page[idx] + (phys & 0xFFFu);
}

/* Decode the LBA from a 6- or 10-byte READ/WRITE CDB (big-endian). */
static ULONG
RamScsiCdbLba(PSCSI_REQUEST_BLOCK Srb)
{
    UCHAR *cdb = Srb->Cdb;
    switch (cdb[0]) {
    case SCSIOP_READ6:
    case SCSIOP_WRITE6:
        return (((ULONG)(cdb[1] & 0x1F)) << 16) |
               (((ULONG)cdb[2]) << 8) | (ULONG)cdb[3];
    default:   /* READ / WRITE (10) */
        return (((ULONG)cdb[2]) << 24) | (((ULONG)cdb[3]) << 16) |
               (((ULONG)cdb[4]) << 8)  | (ULONG)cdb[5];
    }
}

static void
RamScsiReadWrite(PRAMSCSI_DEV_EXT Ext, PSCSI_REQUEST_BLOCK Srb, BOOLEAN Write)
{
    ULONG  lba   = RamScsiCdbLba(Srb);
    ULONG  total = Srb->DataTransferLength;
    PUCHAR usr   = (PUCHAR)Srb->DataBuffer;
    ULONG  done  = 0;
    ULONG  startPhys;

    /* Reject transfers that run past the end of the disk. */
    if (lba > Ext->Blocks || (total / RAMSCSI_SECTOR) > Ext->Blocks - lba) {
        Srb->SrbStatus = SRB_STATUS_ERROR;
        return;
    }
    startPhys = Ext->Base + lba * RAMSCSI_SECTOR;

    /* memcpy page-by-page (the cache maps each 4 KiB page on first touch). */
    while (done < total) {
        ULONG p     = startPhys + done;
        ULONG chunk = 0x1000 - (p & 0xFFFu);   /* up to the next page edge */
        PVOID m;
        if (chunk > total - done) chunk = total - done;
        m = RamScsiMapPage(Ext, p);
        if (m == NULL) { Srb->SrbStatus = SRB_STATUS_ERROR; return; }
        if (Write) RtlCopyMemory(m, usr + done, chunk);
        else       RtlCopyMemory(usr + done, m, chunk);
        done += chunk;
    }
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

static void
RamScsiInquiry(PSCSI_REQUEST_BLOCK Srb)
{
    INQUIRYDATA full;
    ULONG       copyLen;
    static const UCHAR vendor[]  = "MicroNT ";          /* 8  */
    static const UCHAR product[] = "RAM Disk        ";  /* 16 */
    static const UCHAR rev[]     = "1.0 ";              /* 4  */

    if (Srb->DataTransferLength < 5) {
        Srb->SrbStatus = SRB_STATUS_DATA_OVERRUN;
        return;
    }
    RtlZeroMemory(&full, sizeof full);
    full.DeviceType          = DIRECT_ACCESS_DEVICE;
    full.DeviceTypeQualifier = DEVICE_CONNECTED;
    full.Versions            = 0x02;     /* SCSI-2 */
    full.ResponseDataFormat  = 0x02;
    full.AdditionalLength     = sizeof(INQUIRYDATA) - 5;
    RtlCopyMemory(full.VendorId,             vendor,  8);
    RtlCopyMemory(full.ProductId,            product, 16);
    RtlCopyMemory(full.ProductRevisionLevel, rev,     4);

    copyLen = (Srb->DataTransferLength < sizeof full)
              ? Srb->DataTransferLength : sizeof full;
    RtlCopyMemory(Srb->DataBuffer, &full, copyLen);
    Srb->DataTransferLength = copyLen;
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

static void
RamScsiReadCapacity(PRAMSCSI_DEV_EXT Ext, PSCSI_REQUEST_BLOCK Srb)
{
    PUCHAR buf     = (PUCHAR)Srb->DataBuffer;
    ULONG  lastLba = (Ext->Blocks > 0) ? Ext->Blocks - 1 : 0;
    ULONG  bps     = RAMSCSI_SECTOR;

    if (Srb->DataTransferLength < 8) {
        Srb->SrbStatus = SRB_STATUS_DATA_OVERRUN;
        return;
    }
    buf[0] = (UCHAR)(lastLba >> 24); buf[1] = (UCHAR)(lastLba >> 16);
    buf[2] = (UCHAR)(lastLba >>  8); buf[3] = (UCHAR)(lastLba);
    buf[4] = (UCHAR)(bps >> 24); buf[5] = (UCHAR)(bps >> 16);
    buf[6] = (UCHAR)(bps >>  8); buf[7] = (UCHAR)(bps);
    Srb->DataTransferLength = 8;
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

static void
RamScsiModeSense(PSCSI_REQUEST_BLOCK Srb)
{
    PUCHAR buf = (PUCHAR)Srb->DataBuffer;
    if (Srb->DataTransferLength < 4) {
        Srb->SrbStatus = SRB_STATUS_DATA_OVERRUN;
        return;
    }
    buf[0] = 3;     /* mode data length following this byte */
    buf[1] = 0;     /* medium type */
    buf[2] = 0;     /* device-specific: not write-protected */
    buf[3] = 0;     /* block descriptor length: none */
    Srb->DataTransferLength = 4;
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

BOOLEAN
RamScsiStartIo(IN PVOID DeviceExtension, IN PSCSI_REQUEST_BLOCK Srb)
{
    PRAMSCSI_DEV_EXT Ext = (PRAMSCSI_DEV_EXT)DeviceExtension;

    /* Single LUN at 0/0/0. */
    if (Srb->PathId != 0 || Srb->TargetId != 0 || Srb->Lun != 0) {
        Srb->SrbStatus = SRB_STATUS_NO_DEVICE;
        ScsiPortNotification(RequestComplete, Ext, Srb);
        ScsiPortNotification(NextRequest, Ext, NULL);
        return TRUE;
    }

    if (Srb->Function == SRB_FUNCTION_EXECUTE_SCSI) {
        switch (Srb->Cdb[0]) {
        case SCSIOP_TEST_UNIT_READY:
        case SCSIOP_VERIFY:
        case SCSIOP_VERIFY6:
        case SCSIOP_START_STOP_UNIT:
        case SCSIOP_MEDIUM_REMOVAL:
        case SCSIOP_REZERO_UNIT:
        case SCSIOP_SYNCHRONIZE_CACHE:
            Srb->SrbStatus = SRB_STATUS_SUCCESS;
            Srb->DataTransferLength = 0;
            break;
        case SCSIOP_INQUIRY:        RamScsiInquiry(Srb);              break;
        case SCSIOP_READ_CAPACITY:  RamScsiReadCapacity(Ext, Srb);   break;
        case SCSIOP_MODE_SENSE:     RamScsiModeSense(Srb);           break;
        case SCSIOP_READ6:
        case SCSIOP_READ:           RamScsiReadWrite(Ext, Srb, FALSE); break;
        case SCSIOP_WRITE6:
        case SCSIOP_WRITE:          RamScsiReadWrite(Ext, Srb, TRUE);  break;
        default:
            Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
            break;
        }
    } else {
        switch (Srb->Function) {
        case SRB_FUNCTION_FLUSH:
        case SRB_FUNCTION_SHUTDOWN:
        case SRB_FUNCTION_RESET_BUS:
        case SRB_FUNCTION_RESET_DEVICE:
        case SRB_FUNCTION_ABORT_COMMAND:
            Srb->SrbStatus = SRB_STATUS_SUCCESS;
            break;
        default:
            Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
            break;
        }
    }

    ScsiPortNotification(RequestComplete, Ext, Srb);
    ScsiPortNotification(NextRequest, Ext, NULL);
    return TRUE;
}

ULONG
RamScsiFindAdapter(IN PVOID DeviceExtension,
                   IN PVOID HwContext,
                   IN PVOID BusInformation,
                   IN PCHAR ArgumentString,
                   IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                   OUT PBOOLEAN Again)
{
    PRAMSCSI_DEV_EXT Ext = (PRAMSCSI_DEV_EXT)DeviceExtension;
    ULONG i;

    UNREFERENCED_PARAMETER(HwContext);
    UNREFERENCED_PARAMETER(BusInformation);
    UNREFERENCED_PARAMETER(ArgumentString);

    *Again = FALSE;

    if (RamDiskCfg.Magic != RAMD_MAGIC ||
        RamDiskCfg.Base == 0 || RamDiskCfg.Len == 0) {
        DbgPrint("RAMSCSI: RAMDCFG not initialized (magic=%08x base=%08x len=%u)\n",
                 RamDiskCfg.Magic, RamDiskCfg.Base, RamDiskCfg.Len);
        return SP_RETURN_NOT_FOUND;
    }
    if ((RamDiskCfg.Len >> 12) > RAMSCSI_MAX_PAGES) {
        DbgPrint("RAMSCSI: disk too large for page cache (%u > %u bytes)\n",
                 RamDiskCfg.Len, RAMSCSI_MAX_PAGES << 12);
        return SP_RETURN_ERROR;
    }

    Ext->Base   = RamDiskCfg.Base;
    Ext->Blocks = RamDiskCfg.Len / RAMSCSI_SECTOR;
    for (i = 0; i < RAMSCSI_MAX_PAGES; i++) Ext->Page[i] = NULL;

    ConfigInfo->NumberOfBuses          = 1;
    ConfigInfo->MaximumNumberOfTargets = 1;
    ConfigInfo->MaximumTransferLength  = 64 * 1024;
    ConfigInfo->NumberOfPhysicalBreaks = 17;
    ConfigInfo->ScatterGather          = FALSE;
    ConfigInfo->Master                 = FALSE;
    ConfigInfo->CachesData             = FALSE;
    ConfigInfo->AdapterScansDown       = FALSE;
    ConfigInfo->AlignmentMask          = 0;

    DbgPrint("RAMSCSI: disk at phys 0x%08x, %u sectors (%u MB)\n",
             Ext->Base, Ext->Blocks, Ext->Blocks / 2048);
    return SP_RETURN_FOUND;
}

BOOLEAN
RamScsiInitialize(IN PVOID DeviceExtension)
{
    UNREFERENCED_PARAMETER(DeviceExtension);
    return TRUE;
}

BOOLEAN
RamScsiResetBus(IN PVOID DeviceExtension, IN ULONG PathId)
{
    UNREFERENCED_PARAMETER(DeviceExtension);
    UNREFERENCED_PARAMETER(PathId);
    return TRUE;
}

ULONG
DriverEntry(IN PVOID DriverObject, IN PVOID Argument2)
{
    HW_INITIALIZATION_DATA hwInitData;
    ULONG                  status;

    DbgPrint("RAMSCSI: DriverEntry\n");

    RtlZeroMemory(&hwInitData, sizeof hwInitData);
    hwInitData.HwInitializationDataSize = sizeof hwInitData;

    hwInitData.HwInitialize    = RamScsiInitialize;
    hwInitData.HwStartIo       = RamScsiStartIo;
    hwInitData.HwFindAdapter   = RamScsiFindAdapter;
    hwInitData.HwResetBus      = RamScsiResetBus;

    /* Isa = the adapter bus scsiport enumerates to call HwFindAdapter
     * (matching the Nebbett reference).  The RAM region itself is mapped
     * with bus type Internal in RamScsiMapPage — that's a different axis. */
    hwInitData.AdapterInterfaceType    = Isa;
    hwInitData.DeviceExtensionSize     = sizeof(RAMSCSI_DEV_EXT);
    hwInitData.SpecificLuExtensionSize = 0;
    hwInitData.SrbExtensionSize        = 0;
    hwInitData.NumberOfAccessRanges    = 0;
    hwInitData.MapBuffers              = TRUE;

    status = ScsiPortInitialize(DriverObject, Argument2, &hwInitData, NULL);
    DbgPrint("RAMSCSI: DriverEntry exit 0x%08x\n", status);
    return status;
}
