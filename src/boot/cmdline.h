/*
 * Kernel command-line resolver.
 *
 * Produces the ASCII string that becomes LOADER_PARAMETER_BLOCK.LoadOptions.
 * It is sourced from an ordered list — the first source that yields a
 * non-empty string wins:
 *
 *   1. EFI_LOADED_IMAGE_PROTOCOL.LoadOptions  (per-launch override)
 *        Populated by launch models that pass a command line through the
 *        firmware: QEMU `-kernel BOOTX64.EFI -append "..."`, a UEFI Shell
 *        invocation, or a real-firmware Boot#### entry's OptionalData.
 *        Empty under OVMF's removable-media auto-boot (\EFI\BOOT\BOOTX64.EFI),
 *        which is why source 2 still exists.
 *
 *   2. fw_cfg `opt/micront/loadopts`          (QEMU static-disk default)
 *        Supplied by boot.sh --kernel-opts on the static-disk-image profile.
 *
 * A future third source (an options file baked onto the ESP) is the intended
 * channel for cloud images (EC2/Azure/GCP), which have no firmware command-
 * line mechanism — it slots in here without touching callers.
 */
#ifndef _BOOT_EFI_CMDLINE_H_
#define _BOOT_EFI_CMDLINE_H_

#include "bootenv.h"

/* Resolve the kernel command line into `out` (always NUL-terminated).
 * `entry_cmdline` is the per-launch command line the boot entry already
 * obtained from its firmware (EFI LoadOptions, or boot_params/PVH cmdline);
 * pass NULL/"" if none. It wins over the fw_cfg blob fallback. Returns
 * strlen(out)+1 — matching fwcfg_read_string — or 0 if every source empty. */
unsigned cmdline(const char *entry_cmdline, char *out, unsigned cap);

#endif
