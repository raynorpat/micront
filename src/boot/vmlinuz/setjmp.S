/*
 * i386 setjmp/longjmp for the freestanding PVH loader (see boot/setjmp.h).
 *
 * jmp_buf layout (6 longs): [ebx, esi, edi, ebp, esp, eip].  setjmp saves the
 * callee-saved registers, the caller's stack pointer (as it will be after the
 * `ret`), and the return address; it returns 0.  longjmp restores them and
 * resumes at the saved return address as if setjmp had returned `val` (or 1
 * if val == 0).  cdecl; only used by puff.c's error bailout.
 */
    .code32
    .section .text

    .globl  setjmp
    .type   setjmp, @function
setjmp:
    movl    4(%esp), %eax           /* env */
    movl    %ebx,  0(%eax)
    movl    %esi,  4(%eax)
    movl    %edi,  8(%eax)
    movl    %ebp, 12(%eax)
    leal    4(%esp), %ecx           /* caller's esp after the ret pops us */
    movl    %ecx, 16(%eax)
    movl    (%esp), %ecx            /* return address */
    movl    %ecx, 20(%eax)
    xorl    %eax, %eax              /* return 0 */
    ret
    .size   setjmp, .-setjmp

    .globl  longjmp
    .type   longjmp, @function
longjmp:
    movl    4(%esp), %edx           /* env */
    movl    8(%esp), %eax           /* val */
    testl   %eax, %eax
    jnz     1f
    movl    $1, %eax                /* longjmp(env, 0) returns 1 */
1:
    movl     0(%edx), %ebx
    movl     4(%edx), %esi
    movl     8(%edx), %edi
    movl    12(%edx), %ebp
    movl    16(%edx), %esp
    movl    20(%edx), %ecx          /* saved return address */
    jmp     *%ecx
    .size   longjmp, .-longjmp
