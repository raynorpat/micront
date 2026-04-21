/*
 * ntshim.h — minimal CRT-shaped API backed by NT 3.5 ntdll only.
 *
 * Designed for LuaJIT (with FFI): covers the malloc/printf/stdio/time
 * surface LuaJIT touches, plus the string.h / mem.h gaps ntdll doesn't
 * fill (strcmp family, memmove).
 *
 * Does NOT pull in mingw's <stdio.h> / <stdlib.h> / <string.h>. Consumers
 * either (a) compile with -nostdinc and shim-header shims that redirect
 * <stdio.h> here, or (b) just #include "ntshim.h" directly. For option (a)
 * we'll add compat headers under src/cr/include/ when wiring LuaJIT in.
 *
 * Threading: none yet. Everything is process-global, unsafe under MT.
 * Errno: stored in a single process-wide int (good enough until LuaJIT
 * spawns its own threads, which it doesn't by default).
 */

#ifndef NTSHIM_H
#define NTSHIM_H

#include <stddef.h>
#include <stdarg.h>

/* ---------------------- stdio ---------------------------------------- */

typedef struct FILE FILE;

extern FILE *stdin;
extern FILE *stdout;
extern FILE *stderr;

#define EOF       (-1)
#define SEEK_SET  0
#define SEEK_CUR  1
#define SEEK_END  2
#define BUFSIZ    4096

int     printf (const char *fmt, ...);
int     fprintf(FILE *, const char *fmt, ...);
int     sprintf(char *, const char *fmt, ...);
int     snprintf(char *, size_t, const char *fmt, ...);
int     vsnprintf(char *, size_t, const char *fmt, va_list);
int     vfprintf(FILE *, const char *fmt, va_list);

FILE   *fopen (const char *path, const char *mode);
int     fclose(FILE *);
size_t  fread (void *, size_t size, size_t n, FILE *);
size_t  fwrite(const void *, size_t size, size_t n, FILE *);
int     fseek (FILE *, long, int whence);
long    ftell (FILE *);
int     feof  (FILE *);
int     ferror(FILE *);
int     fflush(FILE *);
int     fputs (const char *, FILE *);
int     fputc (int, FILE *);
int     fgetc (FILE *);
char   *fgets (char *, int, FILE *);
int     puts  (const char *);
int     putchar(int);

/* ---------------------- stdlib --------------------------------------- */

void   *malloc (size_t);
void   *calloc (size_t, size_t);
void   *realloc(void *, size_t);
void    free   (void *);

void    exit  (int status);        /* calls NtTerminateProcess — no atexit */
void    abort (void);              /* int3 then NtTerminateProcess(0xC0000005) */
char   *getenv(const char *);      /* stub: returns NULL until PEB env parse lands */

int     atoi  (const char *);
long    atol  (const char *);
long    strtol(const char *, char **endp, int base);
double  strtod(const char *, char **endp);

/* ---------------------- string / mem --------------------------------- */

/* ntdll exports memcpy/memset/memcmp/strcpy/strlen — we declare them
 * here so consumers don't have to pull in <string.h>. memmove + the
 * strcmp family aren't in ntdll, so we implement them ourselves. */
void   *memcpy (void *, const void *, size_t);
void   *memset (void *, int, size_t);
int     memcmp (const void *, const void *, size_t);
void   *memmove(void *, const void *, size_t);

size_t  strlen (const char *);
char   *strcpy (char *, const char *);
char   *strncpy(char *, const char *, size_t);
int     strcmp (const char *, const char *);
int     strncmp(const char *, const char *, size_t);
char   *strcat (char *, const char *);
char   *strchr (const char *, int);
char   *strrchr(const char *, int);
char   *strstr (const char *, const char *);

/* ---------------------- time ----------------------------------------- */

typedef long time_t;
typedef long clock_t;
#define CLOCKS_PER_SEC 1000000L

time_t  time  (time_t *);            /* seconds since 1970-01-01 UTC */
clock_t clock (void);                /* NtQueryPerformanceCounter-derived */

/* ---------------------- errno ---------------------------------------- */

/* We don't collide with mingw's <errno.h> macro — consumers that want
 * our errno read _ntshim_errno directly. LuaJIT doesn't touch errno in
 * paths we care about (only strtod sets it, and we ignore that). */
extern int _ntshim_errno;

/* ---------------------- setup (call once at process start) ----------- */

/* Called from NtProcessStartup before any libc-ish function runs.
 * Captures RtlProcessHeap, opens the debug-print stream for stdout/stderr,
 * and seeds the clock() epoch. */
void ntshim_init(void);

#endif /* NTSHIM_H */
