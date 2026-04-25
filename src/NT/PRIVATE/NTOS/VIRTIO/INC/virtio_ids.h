/*++

    virtio_ids.h — Device-class IDs from the virtio specification.
    Adapted from Unikraft (BSD-3-Clause) which adapted from Linux's
    include/uapi/linux/virtio_ids.h.

--*/

#ifndef _VIRTIO_IDS_H_
#define _VIRTIO_IDS_H_

#define VIRTIO_ID_INVALID        0
#define VIRTIO_ID_NET            1
#define VIRTIO_ID_BLOCK          2
#define VIRTIO_ID_CONSOLE        3
#define VIRTIO_ID_RNG            4
#define VIRTIO_ID_BALLOON        5
#define VIRTIO_ID_RPMSG          7
#define VIRTIO_ID_SCSI           8
#define VIRTIO_ID_9P             9
#define VIRTIO_ID_GPU            16
#define VIRTIO_ID_INPUT          18
#define VIRTIO_ID_VSOCK          19
#define VIRTIO_ID_FS             26

/* Transitional / legacy PCI device IDs — what QEMU exposes when
   `disable-modern=on,disable-legacy=off`. PCI vendor is 0x1AF4
   (Red Hat / Qumranet); device IDs in 0x1000..0x103F are legacy. */
#define VIRTIO_PCI_VENDOR_ID         0x1AF4
#define VIRTIO_PCI_LEGACY_DEV_NET    0x1000
#define VIRTIO_PCI_LEGACY_DEV_BLOCK  0x1001
#define VIRTIO_PCI_LEGACY_DEV_BAL    0x1002
#define VIRTIO_PCI_LEGACY_DEV_CON    0x1003
#define VIRTIO_PCI_LEGACY_DEV_SCSI   0x1004
#define VIRTIO_PCI_LEGACY_DEV_RNG    0x1005
#define VIRTIO_PCI_LEGACY_DEV_9P     0x1009

#endif /* _VIRTIO_IDS_H_ */
