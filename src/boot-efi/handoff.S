/*
 * Final jump to KiSystemStartup.
 *
 * Takes three args: kernel entry, loader block (both KSEG0 virtuals),
 * and a KSEG0-virtual stack top to switch to. The stack switch is
 * essential under UEFI: our inherited UEFI stack lives in low phys
 * (~100 MB, identity-mapped via our PD), but MiInitMachineDependent
 * zeroes PDEs 0..511 early in MM init, yanking that identity mapping.
 * Continuing on the low-phys stack after that = #PF, no handler, triple
 * fault. Switching to a KSEG0-aliased stack keeps it valid through
 * the unmap.
 *
 * Signature:
 *   void handoff(unsigned long entry_kseg0,
 *                unsigned long loader_block_kseg0,
 *                unsigned long new_stack_top_kseg0);
 */
    .section .text
    .globl handoff
    .type   handoff, @function
handoff:
    /* Disable interrupts — HalpInitializePICs will re-enable once the
     * kernel's IDT and PIC vectors are set up. */
    cli

    /* Fetch args from caller's stack BEFORE we switch stacks. */
    movl    4(%esp), %eax     /* entry */
    movl    8(%esp), %ebx     /* loader_block */
    movl    12(%esp), %ecx    /* new_stack_top (KSEG0) */

    /* Switch to the KSEG0 stack. From here on we must not reference the
     * caller's stack frame — args are already in registers. */
    movl    %ecx, %esp

    /* Initialize FPU and clear pending exceptions (matches boot/entry.S). */
    clts
    fninit
    fnclex

    /* Diagnostic: poke 'K' to COM1 (0x3F8) so we know we reached the jump. */
    movw    $0x3F8, %dx
    movb    $'K', %al
    outb    %al, %dx

    /* Push loader_block as KiSystemStartup's argument, then call via eax.
     * KiSystemStartup never returns. */
    pushl   %ebx
    calll   *%eax

    /* Unreachable — hang deterministically if we somehow return. */
    cli
1:  hlt
    jmp     1b
    .size   handoff, .-handoff
