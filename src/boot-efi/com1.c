#include "com1.h"

#define COM1 0x3F8

static inline void outb(unsigned short port, unsigned char val) {
    __asm__ volatile("outb %0, %1" : : "a"(val), "Nd"(port));
}
static inline unsigned char inb(unsigned short port) {
    unsigned char v;
    __asm__ volatile("inb %1, %0" : "=a"(v) : "Nd"(port));
    return v;
}

void com1_init(void) {
    outb(COM1 + 1, 0x00);   /* IER off */
    outb(COM1 + 3, 0x80);   /* DLAB on */
    outb(COM1 + 0, 0x01);   /* 115200 baud low  */
    outb(COM1 + 1, 0x00);   /*          high */
    outb(COM1 + 3, 0x03);   /* 8N1, DLAB off */
    outb(COM1 + 2, 0xC7);   /* FIFO enable+clear */
    outb(COM1 + 4, 0x0B);   /* DTR+RTS+OUT2 */
}

void com1_putc(char c) {
    while ((inb(COM1 + 5) & 0x20) == 0) { }
    outb(COM1, (unsigned char)c);
}

void com1_puts(const char *s) {
    for (; *s; s++) {
        if (*s == '\n') com1_putc('\r');
        com1_putc(*s);
    }
}

void com1_put_hex(unsigned long v) {
    static const char hx[] = "0123456789abcdef";
    int i;
    com1_putc('0');
    com1_putc('x');
    for (i = 28; i >= 0; i -= 4) com1_putc(hx[(v >> i) & 0xF]);
}

void com1_put_dec(unsigned long v) {
    char buf[12];
    int i = 0;
    if (v == 0) { com1_putc('0'); return; }
    while (v) { buf[i++] = '0' + (v % 10); v /= 10; }
    while (i--) com1_putc(buf[i]);
}
