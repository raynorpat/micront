/*
 * PVH 32-bit entry for the MicroNT vmlinuz loader.
 *
 * qemu-system-x86_64 -kernel (PVH direct boot) reads the
 * XEN_ELFNOTE_PHYS32_ENTRY note below and jumps to _pvh_start in 32-bit
 * protected mode: paging off, flat 4 GiB segments, %ebx = physical
 * address of struct hvm_start_info. We set up a stack and call into C.
 *
 * No GDT/IDT setup here — the PVH ABI hands us usable flat segments, and
 * the skeleton only does port I/O + memory reads before halting. Mode
 * transition + NT page tables come later, shared with boot/efi/.
 */
    .code32

/* ---- PVH ELF note: XEN_ELFNOTE_PHYS32_ENTRY (type 18) ---------------- */
    .section .note.Xen, "a", @note
    .align  4
    .long   2f - 1f          /* n_namesz */
    .long   4f - 3f          /* n_descsz */
    .long   18               /* n_type = XEN_ELFNOTE_PHYS32_ENTRY */
1:  .asciz  "Xen"            /* n_name  */
2:  .align  4
3:  .long   _pvh_start       /* n_desc  = 32-bit entry point */
4:  .align  4

/* ---- entry ----------------------------------------------------------- */
    .section .text
    .globl  _pvh_start
    .type   _pvh_start, @function
_pvh_start:
    cli
    cld
    movl    $stack_top, %esp
    xorl    %ebp, %ebp
    pushl   %ebx             /* hvm_start_info phys -> vmlinuz_main(arg) */
    call    vmlinuz_main
1:  hlt
    jmp     1b
    .size   _pvh_start, . - _pvh_start

/* ---- boot stack ------------------------------------------------------ */
    .section .bss
    .align  16
    .skip   0x4000           /* 16 KiB */
stack_top:
