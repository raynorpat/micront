/*
 * 64→32 mode-drop placeholder.
 *
 * Under OVMF64 this .S will eventually contain the full transition:
 *   lgdt 32-bit → far-jmp compat → clear CR0.PG → clear EFER.LME →
 *   clear CR4.PAE → load 32-bit CR3 → set CR0.PG → far-jmp kernel.
 *
 * For Commit A we're only validating that the x86_64 build compiles
 * and reaches ExitBootServices under OVMF64. handoff() here just halts
 * so main.c's call site is satisfied. Commit B replaces this with the
 * real transition stub.
 *
 * Signature (unchanged from 32-bit world):
 *   void handoff(unsigned long entry_kseg0,
 *                unsigned long loader_block_kseg0,
 *                unsigned long stack_top_kseg0);
 * Under MS x64 the args arrive in RCX, RDX, R8. Under SysV x64 they'd
 * be RDI, RSI, RDX. We don't touch them — just halt — so either works.
 */

    .section .text
    .globl handoff
    .type   handoff, @function
handoff:
    cli
    /* Diagnostic: 'H' to COM1 so we know the call reached us. */
    movw    $0x3F8, %dx
    movb    $'H', %al
    outb    %al, %dx
1:  hlt
    jmp     1b
    .size   handoff, .-handoff
