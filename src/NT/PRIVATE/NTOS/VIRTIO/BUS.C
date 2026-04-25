/*++

    bus.c — Generic virtio device-status / config-ops dispatch.

    Adapted from Unikraft's drivers/virtio/bus/virtio_bus.c (BSD-3).
    Unikraft's bus layer also implements driver registration + device
    matching against a global driver list; we don't need that — each
    NT virtio device driver (viorng.sys, vioser.sys) does its own PCI
    enumeration and creates its own VIRTIO_PCI_DEV directly.

    What's left here is the dispatcher: thin wrappers around the Cops
    vtable that NULL-check the function pointer and propagate NTSTATUS.

--*/

#include "virtio.h"

NTSTATUS
VirtioDevReset(PVIRTIO_DEV vdev)
{
    ASSERT(vdev != NULL);
    if (!vdev->Cops || !vdev->Cops->DeviceReset)
        return STATUS_NOT_SUPPORTED;
    vdev->Cops->DeviceReset(vdev);
    vdev->State = VirtioStateReset;
    return STATUS_SUCCESS;
}

u8
VirtioDevStatusGet(PVIRTIO_DEV vdev)
{
    ASSERT(vdev != NULL);
    if (!vdev->Cops || !vdev->Cops->StatusGet)
        return 0;
    return vdev->Cops->StatusGet(vdev);
}

NTSTATUS
VirtioDevStatusUpdate(PVIRTIO_DEV vdev, u8 status)
{
    ASSERT(vdev != NULL);
    if (!vdev->Cops || !vdev->Cops->StatusSet)
        return STATUS_NOT_SUPPORTED;
    vdev->Cops->StatusSet(vdev, status);
    return STATUS_SUCCESS;
}

u64
VirtioFeatureGet(PVIRTIO_DEV vdev)
{
    ASSERT(vdev != NULL);
    if (!vdev->Cops || !vdev->Cops->FeaturesGet)
        return 0;
    return vdev->Cops->FeaturesGet(vdev);
}

VOID
VirtioFeatureSet(PVIRTIO_DEV vdev)
{
    ASSERT(vdev != NULL);
    if (vdev->Cops && vdev->Cops->FeaturesSet)
        vdev->Cops->FeaturesSet(vdev);
}

NTSTATUS
VirtioConfigGet(PVIRTIO_DEV vdev, u16 offset, VOID *buf, u32 len, u8 type_len)
{
    ASSERT(vdev != NULL);
    if (!vdev->Cops || !vdev->Cops->ConfigGet)
        return STATUS_NOT_SUPPORTED;
    return vdev->Cops->ConfigGet(vdev, offset, buf, len, type_len);
}

NTSTATUS
VirtioConfigSet(PVIRTIO_DEV vdev, u16 offset, VOID *buf, u32 len)
{
    ASSERT(vdev != NULL);
    if (!vdev->Cops || !vdev->Cops->ConfigSet)
        return STATUS_NOT_SUPPORTED;
    return vdev->Cops->ConfigSet(vdev, offset, buf, len);
}

NTSTATUS
VirtioFindVqs(PVIRTIO_DEV vdev, u16 total_vqs, u16 *vq_size)
{
    ASSERT(vdev != NULL);
    if (!vdev->Cops || !vdev->Cops->VqsFind)
        return STATUS_NOT_SUPPORTED;
    return vdev->Cops->VqsFind(vdev, total_vqs, vq_size);
}

NTSTATUS
VirtioVqSetup(
    PVIRTIO_DEV     vdev,
    u16             vq_id,
    u16             nr_desc,
    PVIRTQ_CALLBACK callback,
    PVIRTQUEUE     *out_vq
    )
{
    ASSERT(vdev != NULL);
    ASSERT(out_vq != NULL);
    *out_vq = NULL;
    if (!vdev->Cops || !vdev->Cops->VqSetup)
        return STATUS_NOT_SUPPORTED;
    return vdev->Cops->VqSetup(vdev, vq_id, nr_desc, callback, out_vq);
}

VOID
VirtioVqRelease(PVIRTIO_DEV vdev, PVIRTQUEUE vq)
{
    ASSERT(vdev != NULL);
    ASSERT(vq != NULL);
    if (vdev->Cops && vdev->Cops->VqRelease)
        vdev->Cops->VqRelease(vdev, vq);
}

/* Bring the device through the standard init handshake to the live
   state. After this returns, queues are armed and the device may
   start producing used-ring entries. */
VOID
VirtioDevDriverUp(PVIRTIO_DEV vdev)
{
    u8 status;

    status = (u8)(VIRTIO_STATUS_ACK
                | VIRTIO_STATUS_DRIVER
                | VIRTIO_STATUS_FEATURES_OK
                | VIRTIO_STATUS_DRIVER_OK);
    VirtioDevStatusUpdate(vdev, status);
    vdev->State = VirtioStateRunning;
}
