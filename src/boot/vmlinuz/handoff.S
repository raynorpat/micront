/*
 * PVH (vmlinuz) -> NT kernel handoff stub.
 *
 * Reached from main.c after mmu_build_and_activate() has materialised the
 * NT page directory, GDT, IDT and TSS in memory (but has NOT loaded CR3 or
 * enabled paging). We enter in 32-bit protected mode with paging OFF and
 * flat segments — the PVH ABI state head.S left us in — so this is the
 * 32-bit tail of the UEFI handoff (boot/efi/handoff.S, compat_entry:)
 * WITHOUT the long-mode-exit prologue: no CR0.PG=0 (paging is already
 * off), no EFER.LME clear (we were never in long mode), no far-return
 * mode switch. We instead add an explicit LGDT + far jump to install our
 * GDT and load NT's CS — the bits the EFI path got for free from its
 * 64->32 far-return.
 *
 * Install sequence:
 *   1. LGDT (phys base; identity-reachable while paging is off)
 *   2. far jmp -> CS = KGDT_R0_CODE (0x08); DS/ES/SS = KGDT_R0_DATA (0x10)
 *   3. CR4 = 0x640 (OSFXSR|OSXMMEXCPT|MCE; non-PAE — matches NT 3.5 / EFI)
 *   4. CR3 = NT page directory phys
 *   5. CR0.PG = 1 — enable paging on the NT PD (PE is already set)
 *   6. re-LGDT / LIDT with the KSEG0 alias of the same tables, so they
 *      survive the kernel's later switch to a process PD (identity PDEs
 *      [0..511] drop; only KSEG0 PDEs [512..515] are copied)
 *   7. FS = KGDT_R0_PCR (0x30); LTR KGDT_TSS (0x28)
 *   8. ESP = KSEG0 idle stack; clts/fninit/fnclex
 *   9. 'K' marker to COM1, then push loader_block + call KiSystemStartup
 *
 * Surviving the CR3 swap: main.c calls mmu_register_image() over the
 * loader image, so this stub's .text and the trans_block .data (linked at
 * 0x1000000, vmlinux.lds) are identity-mapped in the NT PD. We're linked
 * -no-pie at a fixed base, so absolute symbol references resolve at link
 * time — no %ebx-relative discipline like the PIE-constrained EFI stub.
 *
 * Signature (cdecl, from main.c):
 *   void vmlinuz_handoff(unsigned long entry, unsigned long lpb,
 *                        unsigned long stack_top, unsigned long pd_phys,
 *                        unsigned long gdt_phys, unsigned long idt_phys);
 */
    .code32

#define KGDT_R0_CODE 0x08
#define KGDT_R0_DATA 0x10
#define KGDT_TSS     0x28
#define KGDT_R0_PCR  0x30
#define KSEG0_BASE   0x80000000
#define COM1         0x3F8

    .section .text
    .globl  vmlinuz_handoff
    .type   vmlinuz_handoff, @function
vmlinuz_handoff:
    cli

    /* cdecl args on the stack: 4(%esp)=entry .. 24(%esp)=idt_phys. Read
     * them into trans_block now, before we touch CR3 or switch ESP. */
    movl    4(%esp),  %eax          /* entry     */
    movl    %eax, tr_entry
    movl    8(%esp),  %eax          /* lpb       */
    movl    %eax, tr_lpb
    movl    12(%esp), %eax          /* stack_top */
    movl    %eax, tr_stack
    movl    16(%esp), %eax          /* pd_phys   */
    movl    %eax, tr_pd

    /* GDTR base: phys form for the pre-paging LGDT, KSEG0 form for the
     * post-paging re-load. */
    movl    20(%esp), %eax          /* gdt_phys  */
    movl    %eax, gdtr_phys_base
    movl    %eax, gdtr_kseg_base
    orl     $KSEG0_BASE, gdtr_kseg_base

    /* IDTR base: KSEG0 form (loaded only after paging is on). */
    movl    24(%esp), %eax          /* idt_phys  */
    orl     $KSEG0_BASE, %eax
    movl    %eax, idtr_kseg_base

    /* 1. Load our GDT (phys base; paging off -> identity-reachable). */
    lgdt    gdtr_phys

    /* 2. Reload CS via far jump, then the NT data segments. */
    ljmp    $KGDT_R0_CODE, $1f
1:
    movw    $KGDT_R0_DATA, %ax
    movw    %ax, %ds
    movw    %ax, %es
    movw    %ax, %ss
    xorw    %ax, %ax
    movw    %ax, %fs
    movw    %ax, %gs

    /* 3. CR4 = OVMF32 / NT 3.5 baseline (OSFXSR|OSXMMEXCPT|MCE; non-PAE). */
    movl    $0x640, %eax
    movl    %eax, %cr4

    /* 4. CR3 = NT page directory. */
    movl    tr_pd, %eax
    movl    %eax, %cr3

    /* 5. CR0.PG = 1 — enable paging on the NT PD (PE already set). */
    movl    %cr0, %eax
    orl     $0x80000000, %eax
    movl    %eax, %cr0

    /* 6. Re-load GDTR/IDTR with the KSEG0 alias so the tables stay
     *    reachable once the kernel switches CR3 to a process PD. */
    lgdt    gdtr_kseg
    lidt    idtr_kseg

    /* 7. FS = PCR, then load the TSS. */
    movw    $KGDT_R0_PCR, %ax
    movw    %ax, %fs
    movw    $KGDT_TSS, %ax
    ltr     %ax

    /* 8. Switch to the KSEG0 idle stack; fresh FPU state. */
    movl    tr_stack, %esp
    clts
    fninit
    fnclex

    /* 9. 'K' marker (handoff fired) then call KiSystemStartup(loader_block).
     *    stdcall: callee pops the arg; it never returns. */
    movw    $COM1, %dx
    movb    $'K', %al
    outb    %al, %dx

    pushl   tr_lpb
    movl    tr_entry, %eax
    calll   *%eax

    cli
2:  hlt
    jmp     2b
    .size   vmlinuz_handoff, .-vmlinuz_handoff

/* Transition state — in .data, part of the loader image (identity-mapped
 * via mmu_register_image), reachable before and after the CR3 swap. The
 * GDTR/IDTR entries are 6-byte pseudo-descriptors (2-byte limit + 4-byte
 * base) laid out contiguously; each l{g,i}dt reads 6 bytes from its label. */
    .section .data
    .align  4
tr_entry:        .long 0
tr_lpb:          .long 0
tr_stack:        .long 0
tr_pd:           .long 0

gdtr_phys:       .word 32*8 - 1
gdtr_phys_base:  .long 0
gdtr_kseg:       .word 32*8 - 1
gdtr_kseg_base:  .long 0
idtr_kseg:       .word 256*8 - 1
idtr_kseg_base:  .long 0
