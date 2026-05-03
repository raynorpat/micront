/*++

    scsi.c -- SCSI <-> virtio-blk command translation.

    Naming follows nvme2k's per-driver convention (each driver dir has
    its own `scsi.c` for SCSI command handling).  Filename also fits
    FAT16 8.3 -- "vioblk_io.c" was 11 chars + .c.

    SCSI semantics (as scsidisk drives them) lifted-and-stripped from
    viostor/virtio_stor_hw_helper.c.  Two paths:

      1. INFO_PATH (INQUIRY / READ_CAPACITY / MODE_SENSE / TUR /
         REPORT_LUNS / etc.) -- synthesize a response from device
         config + complete the SRB inline.

      2. IO_PATH (READ / WRITE / SYNCHRONIZE_CACHE) -- decode the CDB,
         build a virtio-blk request (out_hdr + data SG + status byte),
         enqueue, kick.  Completion is async via VioBlkInterrupt.

    Only minimal SCSI surface for what scsidisk actually needs to
    surface a writable block device; PASSTHRU / DISCARD / WRITE_ZEROES
    return INVALID_REQUEST.

--*/

#include "vioblk.h"

/* CDB read/write LBA + transfer-length decoders.  Each CDB byte
 * layout is per the SCSI-3 spec (SBC-3).  Values are in BIG-endian
 * on the wire; we byteswap to host order. */
#define BSWAP16(x)   ((USHORT)( (((USHORT)(x) & 0xFF00u) >> 8) | \
                                (((USHORT)(x) & 0x00FFu) << 8) ))
#define BSWAP32(x)   ((ULONG) ( (((ULONG)(x)  & 0xFF000000u) >> 24) | \
                                (((ULONG)(x)  & 0x00FF0000u) >>  8) | \
                                (((ULONG)(x)  & 0x0000FF00u) <<  8) | \
                                (((ULONG)(x)  & 0x000000FFu) << 24) ))

/* NT 3.5's SCSI stack is SCSI-2 era; scsidisk only issues 6-byte and
 * 10-byte CDBs, both with at most 32-bit LBAs.  Returning ULONG (and
 * widening at the call site) avoids a CL 8.50 internal compiler error
 * on the OR-into-ULONGLONG return form. */
static ULONG
CdbReadLba(PSCSI_REQUEST_BLOCK Srb)
{
    UCHAR *cdb = Srb->Cdb;
    UCHAR  op  = cdb[0];
    ULONG  lba;

    switch (op) {
    case SCSIOP_READ6:
    case SCSIOP_WRITE6:
        /* 21-bit LBA across cdb[1..3]. */
        lba  = ((ULONG)(cdb[1] & 0x1F)) << 16;
        lba |= ((ULONG)cdb[2]) << 8;
        lba |= ((ULONG)cdb[3]);
        return lba;

    case SCSIOP_READ:
    case SCSIOP_WRITE:
    case SCSIOP_VERIFY:
    case SCSIOP_SYNCHRONIZE_CACHE:
        /* 32-bit LBA across cdb[2..5]. */
        lba  = ((ULONG)cdb[2]) << 24;
        lba |= ((ULONG)cdb[3]) << 16;
        lba |= ((ULONG)cdb[4]) << 8;
        lba |= ((ULONG)cdb[5]);
        return lba;

    default:
        return 0;
    }
}

/* ------------------------------------------------------------------ *
 * VioBlkSubmitIo -- build a virtio-blk descriptor chain for an SRB
 * (read/write/flush) and enqueue it.  Three descriptors per request
 * minimum:
 *
 *     [0]   out_hdr      (read-by-device)
 *     [1..N] data buffer (read- or write-by-device, per Type)
 *     [N+1] status byte  (write-by-device)
 *
 * For FLUSH there's no data buffer; chain is just header + status.
 *
 * On success returns TRUE; SRB completes asynchronously via
 * VioBlkInterrupt.  On failure (descriptor exhaust / SG too large)
 * completes the SRB inline with an error status.
 * ------------------------------------------------------------------ */
BOOLEAN
VioBlkSubmitIo(IN PVIOBLK_DEV_EXT DevExt,
               IN PSCSI_REQUEST_BLOCK Srb,
               IN ULONG Type,
               IN ULONGLONG Sector)
{
    PVIOBLK_SRB_EXT srbExt = (PVIOBLK_SRB_EXT)Srb->SrbExtension;
    NTSTATUS  st;
    ULONG     fragLen;
    ULONG     bytesLeft;
    PUCHAR    va;
    USHORT    sg_idx;
    USHORT    in_segs;
    USHORT    out_segs;
    SCSI_PHYSICAL_ADDRESS pa;
    VIRTIO_SG_LIST sg;

    /* Build out_hdr for the device. */
    srbExt->OutHdr.type   = Type;
    srbExt->OutHdr.ioprio = 0;
    srbExt->OutHdr.sector = Sector;
    srbExt->Srb           = Srb;
    srbExt->Status        = 0xFF;   /* device overwrites */

    sg_idx = 0;

    /* [0] header -- always read-by-device. */
    pa = ScsiPortGetPhysicalAddress(DevExt, NULL,
                                    &srbExt->OutHdr, &fragLen);
    srbExt->Sg[sg_idx].Paddr = pa;
    srbExt->Sg[sg_idx].Len   = sizeof(vioblk_outhdr);
    sg_idx++;

    /* [1..N] data buffer -- only for READ/WRITE; FLUSH has none.
       SRB->DataBuffer may span multiple physical pages even on
       reasonably small transfers, so we walk it via repeated
       ScsiPortGetPhysicalAddress calls. */
    if (Type != VIRTIO_BLK_T_FLUSH && Srb->DataTransferLength > 0) {
        va        = (PUCHAR)Srb->DataBuffer;
        bytesLeft = Srb->DataTransferLength;
        while (bytesLeft > 0) {
            if (sg_idx >= VIOBLK_MAX_SG + 1) {
                DbgPrint("VIOBLK: SG overflow (>%d segs needed)\n",
                         VIOBLK_MAX_SG);
                Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
                ScsiPortNotification(RequestComplete, DevExt, Srb);
                ScsiPortNotification(NextRequest, DevExt, NULL);
                return TRUE;
            }
            pa = ScsiPortGetPhysicalAddress(DevExt, Srb, va, &fragLen);
            if (fragLen == 0 || fragLen > bytesLeft) fragLen = bytesLeft;
            srbExt->Sg[sg_idx].Paddr = pa;
            srbExt->Sg[sg_idx].Len   = fragLen;
            sg_idx++;
            va        += fragLen;
            bytesLeft -= fragLen;
        }
    }

    /* [N+1] status byte -- always write-by-device. */
    pa = ScsiPortGetPhysicalAddress(DevExt, NULL,
                                    &srbExt->Status, &fragLen);
    srbExt->Sg[sg_idx].Paddr = pa;
    srbExt->Sg[sg_idx].Len   = sizeof(UCHAR);
    sg_idx++;

    /* For READ:  out_segs = 1 (header), in_segs = data + status
       For WRITE: out_segs = 1 + data, in_segs = 1 (status)
       For FLUSH: out_segs = 1 (header), in_segs = 1 (status) */
    if (Type == VIRTIO_BLK_T_OUT) {
        out_segs = (USHORT)(sg_idx - 1);    /* everything but status */
        in_segs  = 1;
    } else {
        out_segs = 1;                        /* just header */
        in_segs  = (USHORT)(sg_idx - 1);
    }
    srbExt->OutSegs = out_segs;
    srbExt->InSegs  = in_segs;

    sg.NumSegs = sg_idx;
    sg.Segs    = srbExt->Sg;

    st = VirtqEnqueue(DevExt->Queue, srbExt, &sg, out_segs, in_segs);
    if (!NT_SUCCESS(st)) {
        DbgPrint("VIOBLK: VirtqEnqueue failed 0x%08x\n", st);
        /* Tell scsiport we're full; it'll retry the SRB later. */
        ScsiPortNotification(NextRequest, DevExt, NULL);
        return FALSE;
    }

    VirtqHostNotify(DevExt->Queue);
    return TRUE;
}

/* ------------------------------------------------------------------ *
 * Synthesize an INQUIRY response.  scsidisk uses this to learn the
 * device is a direct-access (disk) device and what vendor/product/
 * revision string to log.  Standard 36-byte response.
 * ------------------------------------------------------------------ */
static void
VioBlkInquiry(PVIOBLK_DEV_EXT DevExt, PSCSI_REQUEST_BLOCK Srb)
{
    INQUIRYDATA  full;
    ULONG        copyLen;
    static const UCHAR vendor_id[]  = "MicroNT ";          /* 8 chars */
    static const UCHAR product_id[] = "vioblk          ";  /* 16 chars */
    static const UCHAR revision[]   = "1.0 ";              /* 4 chars */

    UNREFERENCED_PARAMETER(DevExt);

    /* SCSI INQUIRY response: scsidisk often passes a 36-byte buffer
     * (the standard short inquiry size), much less than the full
     * 96-byte INQUIRYDATA struct.  Build the full response in a stack
     * buffer, then copy whatever fits into the caller's buffer.
     * Reject only if buffer can't even hold the 5-byte header. */
    if (Srb->DataTransferLength < 5) {
        Srb->SrbStatus = SRB_STATUS_DATA_OVERRUN;
        return;
    }

    RtlZeroMemory(&full, sizeof(full));
    full.DeviceType            = DIRECT_ACCESS_DEVICE;     /* 0x00 */
    full.DeviceTypeQualifier   = DEVICE_CONNECTED;
    full.RemovableMedia        = FALSE;
    full.Versions              = 0x02;                     /* SCSI-2 */
    full.ResponseDataFormat    = 0x02;
    full.AdditionalLength      = sizeof(INQUIRYDATA) - 5;
    full.CommandQueue          = TRUE;

    RtlCopyMemory(full.VendorId,             vendor_id,  8);
    RtlCopyMemory(full.ProductId,            product_id, 16);
    RtlCopyMemory(full.ProductRevisionLevel, revision,   4);

    copyLen = (Srb->DataTransferLength < sizeof(full))
              ? Srb->DataTransferLength : sizeof(full);
    RtlCopyMemory(Srb->DataBuffer, &full, copyLen);
    Srb->DataTransferLength = copyLen;
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ *
 * Synthesize a READ_CAPACITY (10) response.  scsidisk needs this to
 * size the disk + drive partition-table parsing.
 *
 * Returns 8 bytes BIG-endian: last_lba (4 bytes) + bytes_per_sector
 * (4 bytes).  last_lba is capacity-1 (since we count from 0).
 * If capacity exceeds 32-bit, return 0xFFFFFFFF; scsidisk will then
 * issue READ_CAPACITY_16 (which we'd handle separately if needed).
 * ------------------------------------------------------------------ */
static void
VioBlkReadCapacity(PVIOBLK_DEV_EXT DevExt, PSCSI_REQUEST_BLOCK Srb)
{
    PUCHAR     buf = (PUCHAR)Srb->DataBuffer;
    ULONGLONG  lastLba;
    ULONG      bps;

    if (Srb->DataTransferLength < 8) {
        Srb->SrbStatus = SRB_STATUS_DATA_OVERRUN;
        return;
    }

    lastLba = (DevExt->Config.capacity > 0)
              ? (DevExt->Config.capacity - 1) : 0;
    /* CL 8.50 doesn't accept the `ull` literal suffix; build the
     * comparison value as ULONGLONG explicitly. */
    if (lastLba > (ULONGLONG)0xFFFFFFFF) {
        lastLba = (ULONGLONG)0xFFFFFFFF;
    }

    bps = VIOBLK_SECTOR_SIZE;

    buf[0] = (UCHAR)((lastLba >> 24) & 0xFF);
    buf[1] = (UCHAR)((lastLba >> 16) & 0xFF);
    buf[2] = (UCHAR)((lastLba >>  8) & 0xFF);
    buf[3] = (UCHAR)((lastLba      ) & 0xFF);
    buf[4] = (UCHAR)((bps >> 24) & 0xFF);
    buf[5] = (UCHAR)((bps >> 16) & 0xFF);
    buf[6] = (UCHAR)((bps >>  8) & 0xFF);
    buf[7] = (UCHAR)((bps      ) & 0xFF);

    Srb->DataTransferLength = 8;
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ *
 * Synthesize a minimal MODE_SENSE response.  scsidisk asks for the
 * caching page (0x08) early; returning a minimal/empty header tells
 * it "no caching mode pages" which is fine for our purposes.
 *
 * The WP (write-protect) bit in the device-specific parameter byte
 * reflects VIRTIO_BLK_F_RO so scsidisk knows whether the disk is
 * read-only.
 * ------------------------------------------------------------------ */
static void
VioBlkModeSense(PVIOBLK_DEV_EXT DevExt, PSCSI_REQUEST_BLOCK Srb)
{
    PUCHAR buf = (PUCHAR)Srb->DataBuffer;
    UCHAR  wp  = DevExt->ReadOnly ? 0x80 : 0x00;

    if (Srb->DataTransferLength < 4) {
        Srb->SrbStatus = SRB_STATUS_DATA_OVERRUN;
        return;
    }

    buf[0] = 3;     /* mode data length (excluding this byte) */
    buf[1] = 0;     /* medium type: default */
    buf[2] = wp;    /* device-specific parameter (WP bit) */
    buf[3] = 0;     /* block descriptor length: none */

    Srb->DataTransferLength = 4;
    Srb->SrbStatus = SRB_STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ *
 * VioBlkExecuteScsi -- dispatch on CDB opcode.  Inline-completes the
 * INFO_PATH SRBs; routes IO_PATH SRBs to VioBlkSubmitIo for async
 * completion via VioBlkInterrupt.
 * ------------------------------------------------------------------ */
BOOLEAN
VioBlkExecuteScsi(IN PVIOBLK_DEV_EXT DevExt,
                  IN PSCSI_REQUEST_BLOCK Srb)
{
    UCHAR op = Srb->Cdb[0];

    switch (op) {
    case SCSIOP_TEST_UNIT_READY:
    case SCSIOP_VERIFY:
    case SCSIOP_START_STOP_UNIT:
    case SCSIOP_MEDIUM_REMOVAL:
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        Srb->DataTransferLength = 0;
        break;

    case SCSIOP_INQUIRY:
        VioBlkInquiry(DevExt, Srb);
        break;

    case SCSIOP_READ_CAPACITY:
        VioBlkReadCapacity(DevExt, Srb);
        break;

    case SCSIOP_MODE_SENSE:
        VioBlkModeSense(DevExt, Srb);
        break;

    case SCSIOP_READ6:
    case SCSIOP_READ:
        return VioBlkSubmitIo(DevExt, Srb, VIRTIO_BLK_T_IN,
                              CdbReadLba(Srb));

    case SCSIOP_WRITE6:
    case SCSIOP_WRITE:
        return VioBlkSubmitIo(DevExt, Srb, VIRTIO_BLK_T_OUT,
                              CdbReadLba(Srb));

    case SCSIOP_SYNCHRONIZE_CACHE:
        if (DevExt->FlushSupported) {
            return VioBlkSubmitIo(DevExt, Srb, VIRTIO_BLK_T_FLUSH, 0);
        }
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        break;

    default:
        DbgPrint("VIOBLK: unhandled CDB op 0x%02X\n", op);
        Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
        break;
    }

    /* Inline-complete the INFO_PATH SRBs. */
    ScsiPortNotification(RequestComplete, DevExt, Srb);
    ScsiPortNotification(NextRequest, DevExt, NULL);
    return TRUE;
}
