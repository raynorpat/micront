/*++

    vioblk.h -- shared definitions for the virtio-blk SCSI miniport.

    Wire-format structs (virtio_blk_config / blk_outhdr) are lifted
    verbatim from viostor/virtio_stor.h -- they're the on-the-wire
    layout that QEMU's virtio-blk device speaks, not implementation
    state.  The adapter/SRB extensions are MicroNT-specific: much
    smaller than viostor's because we drop multi-queue, MSI-X,
    crash-dump, DISCARD/WRITE_ZEROES, and SCSI passthrough.

    Single queue = vq[0] (the request queue).  Single LUN.  Read/
    write/flush only.

--*/

#ifndef _VIOBLK_H_
#define _VIOBLK_H_

#include <ntddk.h>
#include <scsi.h>
#include <srb.h>

#include "virtio.h"
#include "vio_pci.h"
#include "vio_ids.h"

/* ------------------------------------------------------------------ *
 * virtio-blk feature bits (subset we care about).  Bits are spec
 * positions; the device tells us which it supports via FeaturesGet
 * and we ack via FeaturesSet on a subset.
 * ------------------------------------------------------------------ */
#define VIRTIO_BLK_F_BARRIER       0   /* deprecated */
#define VIRTIO_BLK_F_SIZE_MAX      1   /* size_max in config valid */
#define VIRTIO_BLK_F_SEG_MAX       2   /* seg_max in config valid */
#define VIRTIO_BLK_F_GEOMETRY      4   /* legacy geometry valid */
#define VIRTIO_BLK_F_RO            5   /* disk is read-only */
#define VIRTIO_BLK_F_BLK_SIZE      6   /* blk_size in config valid */
#define VIRTIO_BLK_F_FLUSH         9   /* flush request supported */

/* Request command types (out_hdr.type). */
#define VIRTIO_BLK_T_IN            0   /* read */
#define VIRTIO_BLK_T_OUT           1   /* write */
#define VIRTIO_BLK_T_FLUSH         4
#define VIRTIO_BLK_T_GET_ID        8

/* Status byte (last byte of every request).  Device writes one of
 * these into our status slot; we map to SRB status. */
#define VIRTIO_BLK_S_OK            0
#define VIRTIO_BLK_S_IOERR         1
#define VIRTIO_BLK_S_UNSUPP        2

/* Spec-mandated logical sector size for virtio-blk wire commands.
 * Independent of any larger blk_size the device may report; the
 * out_hdr.sector field is always counted in 512-byte units. */
#define VIOBLK_SECTOR_SIZE         512
#define VIOBLK_SECTOR_SHIFT        9

/* Max scatter-gather we're willing to handle in one request.  Each
 * SRB fragment is one descriptor; plus 2 fixed (header + status) =
 * MAX_SG + 2 ring descriptors per request. */
#define VIOBLK_MAX_SG              32

/* Pool tag for ExAllocatePoolWithTag. */
#define VIOBLK_POOL_TAG            'BoiV'

/* ------------------------------------------------------------------ *
 * Wire-format structs.  Lifted from viostor/virtio_stor.h; pack(1)
 * because the device reads them via DMA from guest memory exactly as
 * laid out.
 * ------------------------------------------------------------------ */
#pragma pack(1)

/* Device config region (read via VirtioConfigGet from offset 0). */
typedef struct _vioblk_config {
    u64 capacity;            /* in 512-byte sectors */
    u32 size_max;            /* if SIZE_MAX */
    u32 seg_max;             /* if SEG_MAX */
    struct {
        u16 cylinders;
        u8  heads;
        u8  sectors;
    } geometry;              /* if GEOMETRY */
    u32 blk_size;            /* if BLK_SIZE */
    /* topology + others follow but we don't read them */
} vioblk_config;

/* Out header — always the first descriptor in every request. */
typedef struct _vioblk_outhdr {
    u32 type;                /* VIRTIO_BLK_T_* */
    u32 ioprio;              /* unused; always 0 */
    u64 sector;              /* 512-byte LBA */
} vioblk_outhdr;

#pragma pack()

/* ------------------------------------------------------------------ *
 * Per-SRB scratch.  scsiport gives us SrbExtensionSize bytes per
 * pending request; we use it to hold the request header / status
 * byte / SG list that we hand to the device.
 *
 * Lives across HwStartIo -> HwInterrupt -> SRB completion; both the
 * cookie passed to VirtqEnqueue (for completion routing) and the
 * heap-free request buffer.
 * ------------------------------------------------------------------ */
typedef struct _VIOBLK_SRB_EXT {
    vioblk_outhdr   OutHdr;          /* device-readable header */
    UCHAR           Status;          /* device-writable status byte */
    PSCSI_REQUEST_BLOCK Srb;         /* completion target */
    USHORT          OutSegs;         /* read-by-device descriptor count */
    USHORT          InSegs;          /* write-by-device descriptor count */
    VIRTIO_SG_SEG   Sg[VIOBLK_MAX_SG + 2];  /* +2 for header + status */
} VIOBLK_SRB_EXT, *PVIOBLK_SRB_EXT;

/* ------------------------------------------------------------------ *
 * Per-adapter state.  scsiport allocates DeviceExtensionSize bytes
 * for us at the front of each adapter's device extension.
 *
 * Single VIRTIO_PCI_DEV — one virtio-blk controller, one queue.
 * No multi-queue, no MSI-X, no per-CPU state.
 * ------------------------------------------------------------------ */
typedef struct _VIOBLK_DEV_EXT {
    VIRTIO_PCI_DEV  Pci;             /* virtio.lib's PCI transport state */
    PVIRTQUEUE      Queue;           /* request queue (id 0) */
    vioblk_config   Config;          /* device config snapshot */
    ULONGLONG       NegotiatedFeatures;
    ULONG           SystemIoBusNumber;
    ULONG           SlotNumber;
    BOOLEAN         FlushSupported;
    BOOLEAN         ReadOnly;
} VIOBLK_DEV_EXT, *PVIOBLK_DEV_EXT;

/* ------------------------------------------------------------------ *
 * SCSI miniport callback signatures.  scsiport.h declares some of
 * these via typedefs; mirror nvme2k's style of hand-declaring them
 * here for clarity.
 * ------------------------------------------------------------------ */
ULONG    DriverEntry        (IN PVOID DriverObject, IN PVOID Argument2);
ULONG    VioBlkFindAdapter  (IN PVOID DeviceExtension,
                             IN PVOID HwContext,
                             IN PVOID BusInformation,
                             IN PCHAR ArgumentString,
                             IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                             OUT PBOOLEAN Again);
BOOLEAN  VioBlkInitialize   (IN PVOID DeviceExtension);
BOOLEAN  VioBlkStartIo      (IN PVOID DeviceExtension,
                             IN PSCSI_REQUEST_BLOCK Srb);
BOOLEAN  VioBlkInterrupt    (IN PVOID DeviceExtension);
BOOLEAN  VioBlkResetBus     (IN PVOID DeviceExtension, IN ULONG PathId);

/* ------------------------------------------------------------------ *
 * SCSI translation entry points (scsi.c).  Called from
 * VioBlkStartIo for the SRB types we actually handle.
 *
 * For IO_PATH (read/write/flush), the request gets queued on the
 * virtqueue and completes asynchronously via VioBlkInterrupt.  For
 * INFO_PATH (INQUIRY/READ_CAPACITY/MODE_SENSE/etc.), we synthesize a
 * response inline from device config and complete the SRB
 * synchronously.
 * ------------------------------------------------------------------ */
BOOLEAN  VioBlkExecuteScsi  (IN PVIOBLK_DEV_EXT DevExt,
                             IN PSCSI_REQUEST_BLOCK Srb);
BOOLEAN  VioBlkSubmitIo     (IN PVIOBLK_DEV_EXT DevExt,
                             IN PSCSI_REQUEST_BLOCK Srb,
                             IN ULONG Type,
                             IN ULONGLONG Sector);

#endif /* _VIOBLK_H_ */
