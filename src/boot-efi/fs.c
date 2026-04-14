#include "fs.h"
#include "com1.h"

/*
 * ESP file reading.
 *
 *   fs_init:
 *     1. HandleProtocol(ImageHandle, LoadedImage) -> loaded_image
 *     2. HandleProtocol(loaded_image->DeviceHandle, SimpleFileSystem) -> sfs
 *     3. sfs->OpenVolume() -> g_root
 *
 *   fs_read(path):
 *     1. g_root->Open(path, READ)
 *     2. file->GetInfo(FileInfo) -> size
 *     3. BS->AllocatePages(EfiLoaderData, ceil(size/4K)) -> phys
 *     4. file->Read(&size, phys)
 *     5. file->Close()
 *
 * Pages are EfiLoaderData so they survive ExitBootServices. They're
 * preserved via the memory map entry we'll emit in memmap.c.
 */

static EFI_FILE_PROTOCOL *g_root = NULL;

/* gnu-efi ia32 uses native stdcall for protocol fn ptrs — uefi_call_wrapper
 * is a no-op on ia32 but we use it for portability with x86_64 builds. */

static const EFI_GUID g_loaded_image_guid = LOADED_IMAGE_PROTOCOL;
static const EFI_GUID g_sfs_guid          = SIMPLE_FILE_SYSTEM_PROTOCOL;
static const EFI_GUID g_file_info_guid    = EFI_FILE_INFO_ID;

EFI_STATUS fs_init(EFI_HANDLE ImageHandle) {
    EFI_LOADED_IMAGE_PROTOCOL        *loaded_image;
    EFI_SIMPLE_FILE_SYSTEM_PROTOCOL  *sfs;
    EFI_STATUS status;

    status = uefi_call_wrapper(BS->HandleProtocol, 3,
                               ImageHandle,
                               (EFI_GUID *)&g_loaded_image_guid,
                               (void **)&loaded_image);
    if (EFI_ERROR(status)) {
        com1_puts("[fs] HandleProtocol(LoadedImage) failed: ");
        com1_put_hex((unsigned long)status);
        com1_puts("\n");
        return status;
    }

    status = uefi_call_wrapper(BS->HandleProtocol, 3,
                               loaded_image->DeviceHandle,
                               (EFI_GUID *)&g_sfs_guid,
                               (void **)&sfs);
    if (EFI_ERROR(status)) {
        com1_puts("[fs] HandleProtocol(SimpleFileSystem) failed: ");
        com1_put_hex((unsigned long)status);
        com1_puts("\n");
        return status;
    }

    status = uefi_call_wrapper(sfs->OpenVolume, 2, sfs, &g_root);
    if (EFI_ERROR(status)) {
        com1_puts("[fs] OpenVolume failed: ");
        com1_put_hex((unsigned long)status);
        com1_puts("\n");
        return status;
    }

    com1_puts("[fs] init OK\n");
    return EFI_SUCCESS;
}

static void put_utf16(const CHAR16 *s) {
    /* ASCII-safe dump for serial: if a char is >0x7F, render '?'. */
    for (; *s; s++) com1_putc(*s < 0x80 ? (char)*s : '?');
}

EFI_STATUS fs_read(const CHAR16 *path, PageKind kind,
                   void **out_buf, UINTN *out_size) {
    EFI_FILE_PROTOCOL    *file;
    EFI_FILE_INFO        *info = NULL;
    EFI_PHYSICAL_ADDRESS  phys;
    UINTN                 info_size = 0;
    UINTN                 size, pages;
    EFI_STATUS            status;

    if (!g_root) {
        com1_puts("[fs] read before init\n");
        return EFI_NOT_READY;
    }

    com1_puts("[fs] read ");
    put_utf16(path);

    status = uefi_call_wrapper(g_root->Open, 5, g_root, &file,
                               (CHAR16 *)path, EFI_FILE_MODE_READ, 0);
    if (EFI_ERROR(status)) {
        com1_puts(" - open failed: ");
        com1_put_hex((unsigned long)status);
        com1_puts("\n");
        return status;
    }

    /* Two-step GetInfo: first with NULL buffer to learn the required size. */
    status = uefi_call_wrapper(file->GetInfo, 4, file,
                               (EFI_GUID *)&g_file_info_guid,
                               &info_size, NULL);
    if (status != EFI_BUFFER_TOO_SMALL) {
        com1_puts(" - GetInfo sizing failed\n");
        goto close_err;
    }
    status = uefi_call_wrapper(BS->AllocatePool, 3,
                               EfiLoaderData, info_size, (void **)&info);
    if (EFI_ERROR(status)) goto close_err;
    status = uefi_call_wrapper(file->GetInfo, 4, file,
                               (EFI_GUID *)&g_file_info_guid,
                               &info_size, info);
    if (EFI_ERROR(status)) {
        com1_puts(" - GetInfo failed\n");
        goto free_info_err;
    }
    size = (UINTN)info->FileSize;

    pages = (size + EFI_PAGE_SIZE - 1) >> EFI_PAGE_SHIFT;
    status = mmu_alloc(pages, kind, &phys);
    if (EFI_ERROR(status)) {
        com1_puts(" - mmu_alloc failed\n");
        goto free_info_err;
    }

    status = uefi_call_wrapper(file->Read, 3, file, &size, (void *)(UINTN)phys);
    if (EFI_ERROR(status)) {
        com1_puts(" - Read failed\n");
        uefi_call_wrapper(BS->FreePages, 2, phys, pages);
        goto free_info_err;
    }

    uefi_call_wrapper(BS->FreePool, 1, info);
    uefi_call_wrapper(file->Close, 1, file);

    com1_puts(" -> ");
    com1_put_hex((unsigned long)phys);
    com1_puts(" (");
    com1_put_dec((unsigned long)size);
    com1_puts(" bytes)\n");

    *out_buf  = (void *)(UINTN)phys;
    *out_size = size;
    return EFI_SUCCESS;

free_info_err:
    if (info) uefi_call_wrapper(BS->FreePool, 1, info);
close_err:
    uefi_call_wrapper(file->Close, 1, file);
    return status;
}
