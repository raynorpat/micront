/*++

    virtio_pci.h — Legacy PCI virtio transport (BAR0 I/O register layout)
    + per-device PCI wrapper struct.

    Register offsets are from the virtio 0.9.5 / 1.0 legacy spec — same
    on every transitional virtio-pci device. NT 3.5 HAL reaches these
    via READ_PORT_x / WRITE_PORT_x (HalGetBusDataByOffset to discover the
    BAR, then port I/O).

    Adapted from Unikraft + solo5 + the virtio spec (all BSD/ISC).

--*/

#ifndef _VIRTIO_PCI_H_
#define _VIRTIO_PCI_H_

#include "virtio.h"

/* ------------------------------------------------------------------ *
 * Legacy PCI register offsets (all relative to the device's I/O BAR).
 * ------------------------------------------------------------------ */
#define VIRTIO_PCI_HOST_FEATURES    0    /* 32-bit r/o, device's feature bits */
#define VIRTIO_PCI_GUEST_FEATURES   4    /* 32-bit r/w, our negotiated bits */
#define VIRTIO_PCI_QUEUE_PFN        8    /* 32-bit r/w, ring base PFN (paddr >> 12) */
#define VIRTIO_PCI_QUEUE_SIZE       12   /* 16-bit r/o, max descriptors for selected queue */
#define VIRTIO_PCI_QUEUE_SEL        14   /* 16-bit r/w, which queue to configure */
#define VIRTIO_PCI_QUEUE_NOTIFY     16   /* 16-bit r/w, kick the device */
#define VIRTIO_PCI_STATUS           18   /* 8-bit  r/w, init handshake bits (VIRTIO_STATUS_*) */
#define VIRTIO_PCI_ISR              19   /* 8-bit  r/o, interrupt-status (read clears) */
#define VIRTIO_PCI_CONFIG_OFF       20   /* device-specific config space starts here */

/* ISR bit interpretation. */
#define VIRTIO_PCI_ISR_HAS_INTR     0x01 /* one of our queues fired */
#define VIRTIO_PCI_ISR_CONFIG       0x02 /* device config-space changed */

/* Vring physical-address shift (paddr >> 12 fits in 32 bits — legacy
   virtio is restricted to <4GiB ring memory). */
#define VIRTIO_PCI_QUEUE_ADDR_SHIFT 12

/* Vring alignment requirement on PCI. */
#define VIRTIO_PCI_VRING_ALIGN      4096

/* ------------------------------------------------------------------ *
 * Per-device PCI wrapper. Embeds the generic VIRTIO_DEV. Each device
 * driver (viorng.sys, vioser.sys, ...) allocates one of these and
 * passes &Vdev to the shared virtio.lib API.
 *
 * IoBase: I/O port range from the device's BAR0. Our transport code
 *         calls READ_PORT_x / WRITE_PORT_x with (IoBase + offset).
 * IsrPort: cached pointer to (IoBase + VIRTIO_PCI_ISR), the most
 *          frequently read register.
 * ------------------------------------------------------------------ */
typedef struct _VIRTIO_PCI_DEV {
    VIRTIO_DEV  Vdev;
    PUCHAR      IoBase;
    PUCHAR      IsrPort;
    ULONG       BusNumber;
    ULONG       SlotNumber;
    ULONG       InterruptVector;
    KIRQL       InterruptLevel;
} VIRTIO_PCI_DEV, *PVIRTIO_PCI_DEV;

/* Bind a PVIRTIO_DEV back to its outer VIRTIO_PCI_DEV. */
#define VIRTIO_TO_PCI(vdev) \
    VIRTIO_CONTAINER_OF(vdev, VIRTIO_PCI_DEV, Vdev)

/* ------------------------------------------------------------------ *
 * Initialise a VIRTIO_PCI_DEV from BAR0 + bus/slot info already
 * collected by the device driver via HalGetBusDataByOffset /
 * HalAssignSlotResources. After this returns, vpdev->Vdev.Cops is
 * wired to the legacy ops vtable and the device is ready for status
 * handshake (ACK / DRIVER / FEATURES_OK / DRIVER_OK).
 * ------------------------------------------------------------------ */
NTSTATUS
VirtioPciInit(
    PVIRTIO_PCI_DEV vpdev,
    PUCHAR          io_base,
    ULONG           bus_number,
    ULONG           slot_number,
    ULONG           interrupt_vector,
    KIRQL           interrupt_level,
    u16             device_id          /* virtio device-class ID */
    );

/* Common transport ISR — call from the device driver's KSERVICE_ROUTINE.
   Reads ISR_STATUS (acknowledges the interrupt) and dispatches the per-
   queue callbacks. Returns nonzero if the interrupt was for this device. */
int VirtioPciIsr(PVIRTIO_PCI_DEV vpdev);

#endif /* _VIRTIO_PCI_H_ */
