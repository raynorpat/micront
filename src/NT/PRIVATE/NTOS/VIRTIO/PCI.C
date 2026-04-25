/*++

    pci.c — Legacy virtio-pci transport. Implements the VIRTIO_CONFIG_OPS
    vtable on top of NT 3.5's HAL port-I/O (READ_PORT_/WRITE_PORT_).

    Each device driver (viorng.sys, vioser.sys, ...) is responsible for
    its own PCI enumeration via HalGetBusDataByOffset / HalAssignSlot-
    Resources, then calls VirtioPciInit() with the discovered BAR0 I/O
    base + IRQ resources to wire the legacy ops onto its VIRTIO_PCI_DEV.

    Adapted from Unikraft's drivers/virtio/pci/virtio_pci.c (BSD-3).
    Differences vs upstream:
      * No bus framework / driver list. Each NT driver brings up its
        own device.
      * No IRQ registration in this layer — NT drivers wire IRQs via
        IoConnectInterrupt themselves and call VirtioPciIsr() from
        their KSERVICE_ROUTINE.
      * No modern PCI transport (BAR-mapped MMIO + cfg capabilities).
        Legacy I/O only.

--*/

#include "virtio.h"
#include "virtio_pci.h"

/* ------------------------------------------------------------------ *
 * Forward decls — vtable members defined below.
 * ------------------------------------------------------------------ */
static VOID     VpciDeviceReset (PVIRTIO_DEV vdev);
static NTSTATUS VpciConfigSet   (PVIRTIO_DEV vdev, u16 offset, VOID *buf, u32 len);
static NTSTATUS VpciConfigGet   (PVIRTIO_DEV vdev, u16 offset, VOID *buf, u32 len, u8 type_len);
static u64      VpciFeaturesGet (PVIRTIO_DEV vdev);
static VOID     VpciFeaturesSet (PVIRTIO_DEV vdev);
static u8       VpciStatusGet   (PVIRTIO_DEV vdev);
static VOID     VpciStatusSet   (PVIRTIO_DEV vdev, u8 status);
static NTSTATUS VpciVqsFind     (PVIRTIO_DEV vdev, u16 num_vqs, u16 *vq_size);
static NTSTATUS VpciVqSetup     (PVIRTIO_DEV vdev, u16 queue_id, u16 num_desc,
                                 PVIRTQ_CALLBACK callback, PVIRTQUEUE *out_vq);
static VOID     VpciVqRelease   (PVIRTIO_DEV vdev, PVIRTQUEUE vq);
static int      VpciNotify      (PVIRTIO_DEV vdev, u16 queue_id);

/* ------------------------------------------------------------------ *
 * The single legacy ops vtable. All VIRTIO_PCI_DEV instances point Cops
 * here.
 * ------------------------------------------------------------------ */
static VIRTIO_CONFIG_OPS VpciLegacyOps = {
    VpciDeviceReset,
    VpciConfigSet,
    VpciConfigGet,
    VpciFeaturesGet,
    VpciFeaturesSet,
    VpciStatusGet,
    VpciStatusSet,
    VpciVqsFind,
    VpciVqSetup,
    VpciVqRelease,
};

/* ------------------------------------------------------------------ *
 * Tiny port-I/O helpers. NT 3.5 HAL exports READ_PORT_* and
 * WRITE_PORT_* as direct function calls on x86. We wrap them so the
 * register-offset arithmetic stays readable.
 * ------------------------------------------------------------------ */
__inline UCHAR
VpciInb(PVIRTIO_PCI_DEV vpdev, u16 reg)
{
    return READ_PORT_UCHAR(vpdev->IoBase + reg);
}
__inline USHORT
VpciInw(PVIRTIO_PCI_DEV vpdev, u16 reg)
{
    return READ_PORT_USHORT((PUSHORT)(vpdev->IoBase + reg));
}
__inline ULONG
VpciInl(PVIRTIO_PCI_DEV vpdev, u16 reg)
{
    return READ_PORT_ULONG((PULONG)(vpdev->IoBase + reg));
}
__inline VOID
VpciOutb(PVIRTIO_PCI_DEV vpdev, u16 reg, UCHAR val)
{
    WRITE_PORT_UCHAR(vpdev->IoBase + reg, val);
}
__inline VOID
VpciOutw(PVIRTIO_PCI_DEV vpdev, u16 reg, USHORT val)
{
    WRITE_PORT_USHORT((PUSHORT)(vpdev->IoBase + reg), val);
}
__inline VOID
VpciOutl(PVIRTIO_PCI_DEV vpdev, u16 reg, ULONG val)
{
    WRITE_PORT_ULONG((PULONG)(vpdev->IoBase + reg), val);
}

/* ------------------------------------------------------------------ *
 * PCI status / reset.
 * ------------------------------------------------------------------ */

static u8
VpciStatusGet(PVIRTIO_DEV vdev)
{
    return VpciInb(VIRTIO_TO_PCI(vdev), VIRTIO_PCI_STATUS);
}

static VOID
VpciStatusSet(PVIRTIO_DEV vdev, u8 status)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);
    u8 cur;

    ASSERT(status != VIRTIO_STATUS_RESET); /* use VpciDeviceReset() instead */

    cur = VpciInb(vpdev, VIRTIO_PCI_STATUS);
    VpciOutb(vpdev, VIRTIO_PCI_STATUS, (UCHAR)(cur | status));
}

static VOID
VpciDeviceReset(PVIRTIO_DEV vdev)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);
    u8 status;

    /* Spec 4.1.4.3.2: write 0 to STATUS, then poll until the device
       reports back 0 (the host implementation may take a few cycles).
       In practice on QEMU it's instantaneous; we cap the spin to a
       sane number to avoid livelock if the device is hung. */
    VpciOutb(vpdev, VIRTIO_PCI_STATUS, VIRTIO_STATUS_RESET);
    {
        ULONG i;
        for (i = 0; i < 1000000; i++) {
            status = VpciInb(vpdev, VIRTIO_PCI_STATUS);
            if (status == VIRTIO_STATUS_RESET)
                break;
        }
        if (status != VIRTIO_STATUS_RESET)
            DbgPrint("VIRTIO pci: reset stuck at status 0x%02x\n", status);
    }
}

/* ------------------------------------------------------------------ *
 * Feature bits — only the low 32 are accessible via legacy I/O
 * registers; the upper 32 are unreachable in legacy mode (those need
 * VIRTIO_PCI_HOST_FEATURES_SEL on modern). We zero the upper half.
 * ------------------------------------------------------------------ */

static u64
VpciFeaturesGet(PVIRTIO_DEV vdev)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);
    return (u64)VpciInl(vpdev, VIRTIO_PCI_HOST_FEATURES);
}

static VOID
VpciFeaturesSet(PVIRTIO_DEV vdev)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);

    /* Mask out queue-layer-unsupported bits (event-idx, indirect). */
    vdev->Features = VirtqFeatureNegotiate(vdev->Features);
    VpciOutl(vpdev, VIRTIO_PCI_GUEST_FEATURES, (u32)vdev->Features);
}

/* ------------------------------------------------------------------ *
 * Device-specific config space (everything ≥ VIRTIO_PCI_CONFIG_OFF).
 * Reads/writes are byte-addressable via legacy I/O. For multi-byte
 * fields we read twice and retry on mismatch (per virtio spec) to
 * defend against torn reads when the device updates the field
 * concurrently.
 * ------------------------------------------------------------------ */

static NTSTATUS
VpciConfigGet(PVIRTIO_DEV vdev, u16 offset, VOID *buf, u32 len, u8 type_len)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);
    u32 i;
    PUCHAR p = (PUCHAR)buf;
    u16 reg = (u16)(VIRTIO_PCI_CONFIG_OFF + offset);

    UNREFERENCED_PARAMETER(type_len);

    /* Single-shot for entities ≤ 4 bytes — atomic by I/O port semantics. */
    if (len == 1) {
        p[0] = VpciInb(vpdev, reg);
    } else if (len == 2) {
        *(USHORT*)p = VpciInw(vpdev, reg);
    } else if (len == 4) {
        *(ULONG*)p = VpciInl(vpdev, reg);
    } else {
        /* Generic byte-by-byte path with retry-on-tear. */
        UCHAR  tmp[64];
        ULONG  tries;

        if (len > sizeof(tmp))
            return STATUS_INVALID_PARAMETER;

        for (tries = 0; tries < 10; tries++) {
            for (i = 0; i < len; i++)
                tmp[i] = VpciInb(vpdev, (u16)(reg + i));
            for (i = 0; i < len; i++)
                p[i] = VpciInb(vpdev, (u16)(reg + i));
            for (i = 0; i < len; i++)
                if (tmp[i] != p[i])
                    break;
            if (i == len)
                return STATUS_SUCCESS;
        }
        return STATUS_DEVICE_DATA_ERROR;
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
VpciConfigSet(PVIRTIO_DEV vdev, u16 offset, VOID *buf, u32 len)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);
    PUCHAR p = (PUCHAR)buf;
    u32 i;
    u16 reg = (u16)(VIRTIO_PCI_CONFIG_OFF + offset);

    for (i = 0; i < len; i++)
        VpciOutb(vpdev, (u16)(reg + i), p[i]);
    return STATUS_SUCCESS;
}

/* ------------------------------------------------------------------ *
 * Virtqueue setup — discover queue sizes, bind the ring's PFN to the
 * device, register the kick + ISR-callback hooks.
 * ------------------------------------------------------------------ */

static int
VpciNotify(PVIRTIO_DEV vdev, u16 queue_id)
{
    VpciOutw(VIRTIO_TO_PCI(vdev), VIRTIO_PCI_QUEUE_NOTIFY, queue_id);
    return 0;
}

static NTSTATUS
VpciVqsFind(PVIRTIO_DEV vdev, u16 num_vqs, u16 *vq_size)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);
    u16 i;

    /* IRQ registration is the device driver's job (NT model). All we
       do here is interrogate each queue's max-descriptors. */
    for (i = 0; i < num_vqs; i++) {
        VpciOutw(vpdev, VIRTIO_PCI_QUEUE_SEL, i);
        vq_size[i] = VpciInw(vpdev, VIRTIO_PCI_QUEUE_SIZE);
        if (vq_size[i] == 0) {
            DbgPrint("VIRTIO pci: queue %u not available\n", i);
            return STATUS_DEVICE_NOT_READY;
        }
    }
    return STATUS_SUCCESS;
}

static NTSTATUS
VpciVqSetup(
    PVIRTIO_DEV     vdev,
    u16             queue_id,
    u16             num_desc,
    PVIRTQ_CALLBACK callback,
    PVIRTQUEUE     *out_vq
    )
{
    PVIRTIO_PCI_DEV  vpdev = VIRTIO_TO_PCI(vdev);
    PVIRTQUEUE       vq;
    NTSTATUS         st;
    PHYSICAL_ADDRESS paddr;

    st = VirtqCreate(queue_id, num_desc, VIRTIO_PCI_VRING_ALIGN,
                     callback, VpciNotify, vdev, &vq);
    if (!NT_SUCCESS(st))
        return st;

    /* Tell the device where this queue lives: select queue, write PFN. */
    paddr = VirtqGetRingPaddr(vq);
    VpciOutw(vpdev, VIRTIO_PCI_QUEUE_SEL, queue_id);
    VpciOutl(vpdev, VIRTIO_PCI_QUEUE_PFN,
             (u32)(paddr.QuadPart >> VIRTIO_PCI_QUEUE_ADDR_SHIFT));

    /* Link into vdev's queue list. */
    InsertTailList(&vdev->VqList, &vq->QueueLink);

    *out_vq = vq;
    return STATUS_SUCCESS;
}

static VOID
VpciVqRelease(PVIRTIO_DEV vdev, PVIRTQUEUE vq)
{
    PVIRTIO_PCI_DEV vpdev = VIRTIO_TO_PCI(vdev);

    /* Unbind from the device. */
    VpciOutw(vpdev, VIRTIO_PCI_QUEUE_SEL, vq->QueueId);
    VpciOutl(vpdev, VIRTIO_PCI_QUEUE_PFN, 0);

    RemoveEntryList(&vq->QueueLink);
    VirtqDestroy(vq);
}

/* ------------------------------------------------------------------ *
 * Public init / ISR.
 * ------------------------------------------------------------------ */

NTSTATUS
VirtioPciInit(
    PVIRTIO_PCI_DEV vpdev,
    PUCHAR          io_base,
    ULONG           bus_number,
    ULONG           slot_number,
    ULONG           interrupt_vector,
    KIRQL           interrupt_level,
    u16             device_id
    )
{
    ASSERT(vpdev != NULL);
    ASSERT(io_base != NULL);

    RtlZeroMemory(vpdev, sizeof(*vpdev));

    vpdev->IoBase           = io_base;
    vpdev->IsrPort          = io_base + VIRTIO_PCI_ISR;
    vpdev->BusNumber        = bus_number;
    vpdev->SlotNumber       = slot_number;
    vpdev->InterruptVector  = interrupt_vector;
    vpdev->InterruptLevel   = interrupt_level;

    vpdev->Vdev.Cops      = &VpciLegacyOps;
    vpdev->Vdev.DeviceId  = device_id;
    vpdev->Vdev.State     = VirtioStateReset;
    InitializeListHead(&vpdev->Vdev.VqList);

    return STATUS_SUCCESS;
}

int
VirtioPciIsr(PVIRTIO_PCI_DEV vpdev)
{
    UCHAR        isr;
    PLIST_ENTRY  link;
    PVIRTQUEUE   vq;
    int          handled = 0;

    ASSERT(vpdev != NULL);

    /* Reading ISR_STATUS clears it — this is how virtio-legacy
       acknowledges the interrupt. */
    isr = READ_PORT_UCHAR(vpdev->IsrPort);

    if (isr & VIRTIO_PCI_ISR_CONFIG) {
        DbgPrint("VIRTIO pci: ISR config-change on dev %p (unhandled)\n", vpdev);
        handled = 1;
    }

    if (isr & VIRTIO_PCI_ISR_HAS_INTR) {
        for (link = vpdev->Vdev.VqList.Flink;
             link != &vpdev->Vdev.VqList;
             link = link->Flink) {
            vq = CONTAINING_RECORD(link, VIRTQUEUE, QueueLink);
            handled |= VirtqRingInterrupt(vq);
        }
    }

    return handled;
}
