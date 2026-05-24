/*
 * setjmp.h — minimal i386 setjmp/longjmp for the freestanding loader.
 *
 * The vendored puff.c (zlib's inflate reference) bails out of errors with
 * longjmp(env, 1) from nested calls back to the top-level puff().  The
 * -nostdinc loader has no libc <setjmp.h>, so this provides just enough:
 * the callee-saved registers + stack pointer + return address.  puff is the
 * only consumer (it uses the standard <setjmp.h> spelling, resolved here via
 * the build's -I.. include path).  Implementation: boot/vmlinuz/setjmp.S.
 */
#ifndef _BOOT_SETJMP_H_
#define _BOOT_SETJMP_H_

/* ebx, esi, edi, ebp, esp, eip — array type so `env`/`s->env` decay to a
 * pointer at the call site, matching libc's jmp_buf semantics. */
typedef unsigned long jmp_buf[6];

int  setjmp(jmp_buf env);
void longjmp(jmp_buf env, int val);

#endif
