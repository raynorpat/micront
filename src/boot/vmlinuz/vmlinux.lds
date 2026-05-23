/* Linker script for the MicroNT PVH loader (32-bit ELF).
 *
 * QEMU's PVH boot reads the Xen note from a PT_NOTE program header, then
 * loads the PT_LOAD segments at their physical addresses and jumps to the
 * note's PHYS32_ENTRY. .note.Xen is placed in BOTH the text load segment
 * and the note segment so it is present in memory and discoverable. */
OUTPUT_FORMAT(elf32-i386)
OUTPUT_ARCH(i386)
ENTRY(_pvh_start)

PHDRS {
    note PT_NOTE FLAGS(4);          /* r--  */
    text PT_LOAD FLAGS(5);          /* r-x  */
    data PT_LOAD FLAGS(6);          /* rw-  */
}

SECTIONS {
    /* 16 MiB load base: clear of the NT world, which fills phys [0, 16 MiB)
     * — ntoskrnl @ 1 MiB, HAL/drivers at their fixed KSEG0 bases, and the
     * <16 MiB KSEG0-survivor structures. Linking at 1 MiB would collide
     * with ntoskrnl's fixed load address. */
    . = 0x1000000;
    _image_start = .;

    .note.Xen : { *(.note.Xen) }            :text :note

    .text   : { *(.text*) }                 :text
    .rodata : { *(.rodata*) *(.rodata.*) }  :text

    .data   : { *(.data*) }                 :data
    .bss    : { *(.bss*) *(COMMON) }        :data

    /* End of the loaded image (incl. bss + boot stack). The PVH bootenv
     * bump allocator starts free RAM above this. */
    . = ALIGN(0x1000);
    _image_end = .;

    /DISCARD/ : {
        *(.eh_frame) *(.comment)
        *(.note.GNU-stack) *(.note.gnu.property)
    }
}
