/*
 * COM1 direct port I/O.
 *
 * Serial at 0x3F8, 115200 8N1. Matches the port setup used by boot/entry.S
 * and the NT kernel, so output survives ExitBootServices without any
 * firmware cooperation.
 */
#ifndef _BOOT_EFI_COM1_H_
#define _BOOT_EFI_COM1_H_

void com1_init(void);
void com1_putc(char c);
void com1_puts(const char *s);
void com1_put_hex(unsigned long v);
void com1_put_dec(unsigned long v);

#endif
