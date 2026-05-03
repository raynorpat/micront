/*++

    vioblk.c -- virtio-blk SCSI miniport: DriverEntry, PCI walk,
    virtio device init/handshake, scsiport callback wiring.

    Adapted from viostor/virtio_stor.c (BSD-3-Clause).  Differences
    from upstream:
      - scsiport (NT 3.5) instead of StorPort -- direct SRB field
        access, no SrbEx, no per-MSI-vector lock dance.
      - Single queue, single LUN, INTx -- no MSI-X, no MQ.
      - Drops crash-dump, hibernation, DISCARD, WRITE_ZEROES,
        SCSI passthrough, multi-CPU per-queue request lists.
      - PCI/transport via MicroNT's virtio.lib (NTOS/VIRTIO/) instead
        of viostor's bundled virtio_pci.c.

    Layout mirrors nvme2k.c's miniport scaffolding so the build-system
    + boot-efi + hive integration is identical.

--*/

#include "vioblk.h"

/* ------------------------------------------------------------------ *
 * DriverEntry -- the I/O Manager loads us once at boot, we register
 * with scsiport which then calls our callbacks per discovered PCI
 * device.
 *
 * Argument types are PVOID (not PDRIVER_OBJECT/PUNICODE_STRING) by
 * NT 3.5 SCSI miniport convention -- the miniport never touches them
 * directly; ScsiPortInitialize unpacks them.
 * ------------------------------------------------------------------ */
ULONG
DriverEntry(IN PVOID DriverObject, IN PVOID Argument2)
{
    HW_INITIALIZATION_DATA  hwInitData;
    ULONG                   status;
    /* HwContext used on NT3/NT4 to resume PCI scanning across
       multiple HwFindAdapter invocations -- mirrors nvme2k's setup.
       NT 3.5 doesn't have the Win2K+ PnP "scsiport tells us the
       slot" shortcut. */
    ULONG                   HwContext[2];

    DbgPrint("VIOBLK: DriverEntry\n");

    RtlZeroMemory(&hwInitData, sizeof(hwInitData));
    hwInitData.HwInitializationDataSize = sizeof(hwInitData);

    hwInitData.HwInitialize       = VioBlkInitialize;
    hwInitData.HwStartIo          = VioBlkStartIo;
    hwInitData.HwInterrupt        = VioBlkInterrupt;
    hwInitData.HwFindAdapter      = VioBlkFindAdapter;
    hwInitData.HwResetBus         = VioBlkResetBus;
    hwInitData.HwAdapterState     = NULL;        /* not used on NT 3.5 */

    hwInitData.AdapterInterfaceType = PCIBus;
    hwInitData.DeviceExtensionSize  = sizeof(VIOBLK_DEV_EXT);
    hwInitData.SpecificLuExtensionSize = 0;
    hwInitData.SrbExtensionSize     = sizeof(VIOBLK_SRB_EXT);

    /* One BAR window (the modern transport's MMIO region). */
    hwInitData.NumberOfAccessRanges = 1;
    hwInitData.MapBuffers           = TRUE;
    hwInitData.NeedPhysicalAddresses = TRUE;
    hwInitData.TaggedQueuing        = TRUE;
    hwInitData.AutoRequestSense     = TRUE;
    hwInitData.MultipleRequestPerLu = TRUE;

    /* Don't pre-filter by VendorId/DeviceId via scsiport -- we walk
       PCI ourselves in HwFindAdapter so we can match both modern
       (0x1042) and transitional (0x1001) virtio-blk IDs. */
    hwInitData.VendorIdLength = 0;
    hwInitData.VendorId       = NULL;
    hwInitData.DeviceIdLength = 0;
    hwInitData.DeviceId       = NULL;

    HwContext[0] = 0;
    HwContext[1] = 0;

    status = ScsiPortInitialize(DriverObject, Argument2,
                                &hwInitData, HwContext);

    DbgPrint("VIOBLK: DriverEntry exit 0x%08x\n", status);
    return status;
}

/* ------------------------------------------------------------------ *
 * IsVioBlkDevice -- match VID/DID for virtio-blk in either modern
 * (0x1042) or transitional (0x1001) PCI form.  QEMU's default
 * `-device virtio-blk-pci` exposes the transitional ID but advertises
 * the modern PCI capabilities, which our virtio.lib can drive.
 * ------------------------------------------------------------------ */
static BOOLEAN
IsVioBlkDevice(USHORT vid, USHORT did)
{
    if (vid != VIRTIO_PCI_VENDOR_ID) return FALSE;
    return (did == VIRTIO_PCI_DEV_BLOCK || did == VIRTIO_PCI_TRANS_BLOCK);
}

/* ------------------------------------------------------------------ *
 * VioBlkSetupAdapter -- once we've identified a virtio-blk device
 * at (BusNumber, SlotNumber), do the full virtio init handshake
 * and queue setup.  Returns SP_RETURN_FOUND on success.
 *
 * Doesn't call VirtioDevDriverUp here -- that's deferred to
 * HwInitialize after scsiport has connected our ISR.  Until then,
 * the device must not assume the driver can field interrupts.
 * ------------------------------------------------------------------ */
static ULONG
VioBlkSetupAdapter(IN PVIOBLK_DEV_EXT DevExt,
                   IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                   IN UCHAR *PciBuffer)
{
    NTSTATUS  st;
    u64       deviceFeatures;
    u64       guestFeatures;
    u16       qsize;
    UCHAR     intLine;
    UCHAR     intPin;

    /* Read interrupt line/pin from our cached PCI config buffer.
       scsiport on NT 3.5 won't auto-derive these for us if we set
       SystemIoBusNumber/SlotNumber by hand (which we do); we must
       fill ConfigInfo->BusInterruptLevel/Vector ourselves. */
    intLine = PciBuffer[0x3C];   /* PCI_INTERRUPT_LINE_OFFSET */
    intPin  = PciBuffer[0x3D];   /* PCI_INTERRUPT_PIN_OFFSET */
    DbgPrint("VIOBLK: PCI int line=%d pin=%d\n", intLine, intPin);

    if (intPin == 0 || intLine == 0 || intLine == 0xFF) {
        DbgPrint("VIOBLK: no usable INTx line\n");
        return SP_RETURN_ERROR;
    }
    ConfigInfo->BusInterruptLevel  = intLine;
    ConfigInfo->BusInterruptVector = intLine;
    ConfigInfo->InterruptMode      = LevelSensitive;

    /* Standard scsiport host-controller capabilities.  Most are
       template-copy from nvme2k (same SCSI miniport shape). */
    ConfigInfo->NumberOfBuses          = 1;
    ConfigInfo->ScatterGather          = TRUE;
    ConfigInfo->Master                 = TRUE;
    ConfigInfo->CachesData             = FALSE;
    ConfigInfo->AdapterScansDown       = FALSE;
    ConfigInfo->Dma32BitAddresses      = TRUE;
    ConfigInfo->MaximumNumberOfTargets = 2;
    ConfigInfo->NumberOfPhysicalBreaks = VIOBLK_MAX_SG;
    ConfigInfo->AlignmentMask          = 0x3;       /* DWORD-align */
    ConfigInfo->NeedPhysicalAddresses  = TRUE;
    ConfigInfo->TaggedQueuing          = TRUE;
    ConfigInfo->MultipleRequestPerLu   = TRUE;
    ConfigInfo->AutoRequestSense       = TRUE;
    /* Conservative default; refined after FeaturesGet/ConfigGet
       below if the device advertises seg_max or larger transfers. */
    ConfigInfo->MaximumTransferLength  = VIOBLK_MAX_SG * 4096;

    /* Hand virtio.lib the PCI location.  It walks the cap list,
       maps the MMIO regions, and primes vpdev->Common/Notify/Isr/
       Device pointers.  Interrupt args are stored but virtio.lib
       doesn't IoConnectInterrupt -- scsiport does that for us via
       ConfigInfo->BusInterruptLevel/Vector. */
    st = VirtioPciInit(&DevExt->Pci,
                       DevExt->SystemIoBusNumber,
                       DevExt->SlotNumber,
                       intLine,    /* informational only */
                       (KIRQL)intLine,
                       (KAFFINITY)1,
                       VIRTIO_ID_BLOCK);
    if (!NT_SUCCESS(st)) {
        DbgPrint("VIOBLK: VirtioPciInit failed 0x%08x\n", st);
        return SP_RETURN_ERROR;
    }

    /* Standard virtio init handshake. */
    VirtioDevReset(&DevExt->Pci.Vdev);
    VirtioDevStatusUpdate(&DevExt->Pci.Vdev, VIRTIO_STATUS_ACK);
    VirtioDevStatusUpdate(&DevExt->Pci.Vdev,
                          VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER);

    /* Read device features, mask down to what we support, ack back. */
    deviceFeatures = VirtioFeatureGet(&DevExt->Pci.Vdev);
    DbgPrint("VIOBLK: device features 0x%08x%08x\n",
             (ULONG)(deviceFeatures >> 32),
             (ULONG)(deviceFeatures & 0xFFFFFFFF));

    guestFeatures = 0;
    /* Modern transport requires VERSION_1 -- ack if device offers. */
    if (VIRTIO_HAS_FEATURE(deviceFeatures, VIRTIO_F_VERSION_1)) {
        guestFeatures |= ((u64)1 << VIRTIO_F_VERSION_1);
    }
    /* We honour FLUSH if the device advertises it; otherwise our
       SYNC_CACHE handler returns success without doing anything. */
    if (VIRTIO_HAS_FEATURE(deviceFeatures, VIRTIO_BLK_F_FLUSH)) {
        guestFeatures |= ((u64)1 << VIRTIO_BLK_F_FLUSH);
        DevExt->FlushSupported = TRUE;
    }
    /* RO disks are reported via SCSI MODE SENSE later. */
    if (VIRTIO_HAS_FEATURE(deviceFeatures, VIRTIO_BLK_F_RO)) {
        DevExt->ReadOnly = TRUE;
    }
    DevExt->Pci.Vdev.Features = guestFeatures;
    DevExt->NegotiatedFeatures = guestFeatures;
    VirtioFeatureSet(&DevExt->Pci.Vdev);

    VirtioDevStatusUpdate(&DevExt->Pci.Vdev,
                          VIRTIO_STATUS_ACK | VIRTIO_STATUS_DRIVER |
                          VIRTIO_STATUS_FEATURES_OK);

    /* Read device config (capacity, etc.) -- offset 0 in the
       device-specific config region. */
    st = VirtioConfigGet(&DevExt->Pci.Vdev, 0,
                         &DevExt->Config, sizeof(vioblk_config), 8);
    if (!NT_SUCCESS(st)) {
        DbgPrint("VIOBLK: VirtioConfigGet failed 0x%08x\n", st);
        return SP_RETURN_ERROR;
    }
    /* NT 3.5 DbgPrint doesn't honour %I64u; print as two 32-bit
     * halves the way nvme2k does. */
    DbgPrint("VIOBLK: capacity hi=%08x lo=%08x sectors\n",
             (ULONG)(DevExt->Config.capacity >> 32),
             (ULONG)(DevExt->Config.capacity & 0xFFFFFFFF));

    /* Find + setup our single request queue (queue id 0). */
    st = VirtioFindVqs(&DevExt->Pci.Vdev, 1, &qsize);
    if (!NT_SUCCESS(st)) {
        DbgPrint("VIOBLK: VirtioFindVqs failed 0x%08x\n", st);
        return SP_RETURN_ERROR;
    }
    DbgPrint("VIOBLK: requestq has %u descriptors\n", qsize);

    /* No callback -- HwInterrupt drains the queue directly. */
    st = VirtioVqSetup(&DevExt->Pci.Vdev, 0, qsize, NULL,
                       &DevExt->Queue);
    if (!NT_SUCCESS(st)) {
        DbgPrint("VIOBLK: VirtioVqSetup failed 0x%08x\n", st);
        return SP_RETURN_ERROR;
    }
    DevExt->Queue->Priv = DevExt;

    DbgPrint("VIOBLK: adapter setup complete; deferring DRIVER_OK to HwInitialize\n");
    return SP_RETURN_FOUND;
}

/* ------------------------------------------------------------------ *
 * VioBlkFindAdapter -- scsiport calls this once per PCI slot on NT 3.5
 * (driven by our HwContext-bumped scan loop); the first slot
 * containing a virtio-blk device wins.  Mirrors nvme2k's pattern.
 * ------------------------------------------------------------------ */
ULONG
VioBlkFindAdapter(IN PVOID DeviceExtension,
                  IN PVOID HwContext,
                  IN PVOID BusInformation,
                  IN PCHAR ArgumentString,
                  IN OUT PPORT_CONFIGURATION_INFORMATION ConfigInfo,
                  OUT PBOOLEAN Again)
{
    PVIOBLK_DEV_EXT DevExt = (PVIOBLK_DEV_EXT)DeviceExtension;
    UCHAR  pciBuffer[256];
    ULONG  busNumber;
    ULONG  slotNumber;
    ULONG  bytesRead;
    USHORT vid;
    USHORT did;

    UNREFERENCED_PARAMETER(BusInformation);
    UNREFERENCED_PARAMETER(ArgumentString);

    if (HwContext) {
        busNumber  = ((PULONG)HwContext)[0];
        slotNumber = ((PULONG)HwContext)[1];
    } else {
        busNumber  = ConfigInfo->SystemIoBusNumber;
        slotNumber = ConfigInfo->SlotNumber;
    }

scanloop:
    bytesRead = ScsiPortGetBusData(DeviceExtension, PCIConfiguration,
                                   busNumber, slotNumber,
                                   pciBuffer, 256);
    if (bytesRead == 0) goto scannext;

    vid = *(USHORT *)&pciBuffer[0x00];
    did = *(USHORT *)&pciBuffer[0x02];

    if (vid == 0xFFFF || vid == 0x0000) goto scannext;

    if (IsVioBlkDevice(vid, did)) {
        DbgPrint("VIOBLK: matched %d:%d.%d VID=%04X DID=%04X\n",
                 busNumber,
                 slotNumber & 0x1F,
                 (slotNumber >> 5) & 0x07,
                 vid, did);

        DevExt->SystemIoBusNumber = busNumber;
        DevExt->SlotNumber        = slotNumber;

        /* Ask scsiport to call us again starting at the next slot,
           so a future driver instance can find a second virtio-blk
           controller if one exists. */
        if (HwContext) {
            ((PULONG)HwContext)[0] = busNumber;
            ((PULONG)HwContext)[1] = slotNumber + 1;
            if (((PULONG)HwContext)[1] >= 32 * 8) {
                ((PULONG)HwContext)[0]++;
                ((PULONG)HwContext)[1] = 0;
            }
            *Again = TRUE;
        } else {
            *Again = FALSE;
        }

        return VioBlkSetupAdapter(DevExt, ConfigInfo, pciBuffer);
    }

scannext:
    slotNumber++;
    if (slotNumber == 32 * 8) {
        busNumber++;
        slotNumber = 0;
        if (busNumber == 16) {
            *Again = FALSE;
            return SP_RETURN_NOT_FOUND;
        }
    }
    goto scanloop;
}

/* ------------------------------------------------------------------ *
 * VioBlkInitialize -- called by scsiport after our HwInterrupt has
 * been wired to the IRQ line.  Safe to flip DRIVER_OK now: the
 * device may immediately start firing interrupts.
 * ------------------------------------------------------------------ */
BOOLEAN
VioBlkInitialize(IN PVOID DeviceExtension)
{
    PVIOBLK_DEV_EXT DevExt = (PVIOBLK_DEV_EXT)DeviceExtension;

    DbgPrint("VIOBLK: HwInitialize -- DRIVER_OK\n");
    VirtioDevDriverUp(&DevExt->Pci.Vdev);
    return TRUE;
}

/* ------------------------------------------------------------------ *
 * VioBlkStartIo -- accept an SRB.  EXECUTE_SCSI is the path SRBs
 * carrying real CDBs come down; the rest are control frames we
 * mostly succeed-and-NextRequest immediately.
 *
 * scsiport calls us with its spinlock held; HwInterrupt will too,
 * so no extra locking is needed for our own state.
 * ------------------------------------------------------------------ */
BOOLEAN
VioBlkStartIo(IN PVOID DeviceExtension, IN PSCSI_REQUEST_BLOCK Srb)
{
    PVIOBLK_DEV_EXT DevExt = (PVIOBLK_DEV_EXT)DeviceExtension;

    /* Per-SRB tracing is fire-hose noisy under steady-state I/O
     * (kernel32.dll load alone fires ~50 READ_10s).  Re-enable
     * locally when debugging a specific path: */
#if 0
    DbgPrint("VIOBLK: HwStartIo Func=%02x Path=%d Tgt=%d Lun=%d Cdb[0]=%02x\n",
             Srb->Function, Srb->PathId, Srb->TargetId, Srb->Lun,
             (Srb->Function == SRB_FUNCTION_EXECUTE_SCSI) ? Srb->Cdb[0] : 0xFF);
#endif

    /* Single LUN: PathId 0, TargetId 0, Lun 0 only. */
    if (Srb->PathId != 0 || Srb->TargetId != 0 || Srb->Lun != 0) {
        Srb->SrbStatus = SRB_STATUS_NO_DEVICE;
        ScsiPortNotification(RequestComplete, DevExt, Srb);
        ScsiPortNotification(NextRequest, DevExt, NULL);
        return TRUE;
    }

    switch (Srb->Function) {
    case SRB_FUNCTION_EXECUTE_SCSI:
        return VioBlkExecuteScsi(DevExt, Srb);

    case SRB_FUNCTION_FLUSH:
    case SRB_FUNCTION_SHUTDOWN:
        if (DevExt->FlushSupported) {
            return VioBlkSubmitIo(DevExt, Srb, VIRTIO_BLK_T_FLUSH, 0);
        }
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        break;

    case SRB_FUNCTION_RESET_BUS:
    case SRB_FUNCTION_RESET_DEVICE:
    case SRB_FUNCTION_ABORT_COMMAND:
        /* No-op: virtio-blk has no per-request abort.  Returning
           success here keeps scsidisk from queueing retries forever. */
        Srb->SrbStatus = SRB_STATUS_SUCCESS;
        break;

    default:
        Srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
        break;
    }

    ScsiPortNotification(RequestComplete, DevExt, Srb);
    ScsiPortNotification(NextRequest, DevExt, NULL);
    return TRUE;
}

/* ------------------------------------------------------------------ *
 * VioBlkInterrupt -- scsiport ISR callback.  Ack the device's ISR
 * register, then drain our request queue, completing each finished
 * SRB based on the status byte the device wrote.
 * ------------------------------------------------------------------ */
BOOLEAN
VioBlkInterrupt(IN PVOID DeviceExtension)
{
    PVIOBLK_DEV_EXT DevExt = (PVIOBLK_DEV_EXT)DeviceExtension;
    PVOID    cookie;
    u32      len;
    NTSTATUS st;
    PSCSI_REQUEST_BLOCK srb;
    PVIOBLK_SRB_EXT     srbExt;
    int      handled;
    BOOLEAN  anyComplete = FALSE;

    handled = VirtioPciIsr(&DevExt->Pci);
    if (!handled) return FALSE;

    for (;;) {
        st = VirtqDequeue(DevExt->Queue, &cookie, &len);
        if (!NT_SUCCESS(st)) break;

        srbExt = (PVIOBLK_SRB_EXT)cookie;
        srb    = srbExt->Srb;

        if (srbExt->Status == VIRTIO_BLK_S_OK) {
            srb->SrbStatus = SRB_STATUS_SUCCESS;
            /* For READ/WRITE, len includes the status byte; subtract. */
            if (srb->DataTransferLength > 0 && len > 1) {
                srb->DataTransferLength = len - 1;
            }
        } else if (srbExt->Status == VIRTIO_BLK_S_UNSUPP) {
            srb->SrbStatus = SRB_STATUS_INVALID_REQUEST;
            srb->DataTransferLength = 0;
        } else {
            srb->SrbStatus = SRB_STATUS_ERROR;
            srb->DataTransferLength = 0;
        }

        ScsiPortNotification(RequestComplete, DevExt, srb);
        anyComplete = TRUE;
    }

    if (anyComplete) {
        ScsiPortNotification(NextRequest, DevExt, NULL);
    }

    return TRUE;
}

/* ------------------------------------------------------------------ *
 * VioBlkResetBus -- scsiport calls this on error recovery.  We have
 * no per-request abort, so just succeed.  A real implementation
 * would walk pending SRBs and complete them with SRB_STATUS_BUS_RESET.
 * ------------------------------------------------------------------ */
BOOLEAN
VioBlkResetBus(IN PVOID DeviceExtension, IN ULONG PathId)
{
    UNREFERENCED_PARAMETER(DeviceExtension);
    UNREFERENCED_PARAMETER(PathId);
    DbgPrint("VIOBLK: HwResetBus (no-op)\n");
    return TRUE;
}
