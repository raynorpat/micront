/*
 * ntshim.c — CRT-shaped surface on top of NT 3.5 ntdll.
 *
 * All dependencies are ntdll exports. Verified against the 3.5 SDK import
 * table (see src/NT/PUBLIC/SDK/LIB/I386/ntdll.exp):
 *   heap:   RtlAllocateHeap, RtlReAllocateHeap, RtlFreeHeap
 *   print:  _vsnprintf
 *   mem:    memcpy, memset, memcmp, strcpy, strlen
 *   file:   NtCreateFile, NtReadFile, NtWriteFile, NtClose, NtSetInfoFile,
 *           RtlInitUnicodeString, RtlDosPathNameToNtPathName_U
 *   time:   NtQuerySystemTime, NtQueryPerformanceCounter
 *   proc:   NtTerminateProcess
 *   debug:  DbgPrint
 *
 * The stdio abstraction is deliberately thin: stdout/stderr route
 * through DbgPrint (→ COM2 → boot.sh terminal). Real file I/O via
 * fopen/fread/fwrite lands on NtCreateFile + NtReadFile/NtWriteFile.
 */

#include "ntshim.h"

/* ---------- Minimal NT type / prototype forward-declarations --------- */
/* We don't pull in the DDK headers — everything LuaJIT will ever see is
 * what's in ntshim.h. Internal NT types live here, scoped to this TU. */

typedef unsigned char        UCHAR;
typedef unsigned short       USHORT;
typedef unsigned long        ULONG;
typedef long                 LONG;
typedef long                 NTSTATUS;
typedef unsigned char        BOOLEAN;
typedef void                *PVOID;
typedef void                *HANDLE;
typedef unsigned short      *PWSTR;
typedef const unsigned short*PCWSTR;
typedef const char          *PCSTR;
typedef unsigned int         SIZE_T;
typedef ULONG               *PULONG;

#define NTAPI   __attribute__((stdcall))
#define STATUS_SUCCESS              ((NTSTATUS)0x00000000L)
#define NT_SUCCESS(s)               ((s) >= 0)
#define HEAP_ZERO_MEMORY            0x00000008
#define NT_CURRENT_PROCESS          ((HANDLE)(long)-1)

typedef struct _UNICODE_STRING {
    USHORT Length, MaximumLength;
    PWSTR  Buffer;
} UNICODE_STRING, *PUNICODE_STRING;

typedef struct _LARGE_INTEGER {
    ULONG LowPart;
    LONG  HighPart;
} LARGE_INTEGER, *PLARGE_INTEGER;

typedef struct _IO_STATUS_BLOCK {
    NTSTATUS Status;
    ULONG    Information;
} IO_STATUS_BLOCK, *PIO_STATUS_BLOCK;

typedef struct _OBJECT_ATTRIBUTES {
    ULONG           Length;
    HANDLE          RootDirectory;
    PUNICODE_STRING ObjectName;
    ULONG           Attributes;
    PVOID           SecurityDescriptor;
    PVOID           SecurityQualityOfService;
} OBJECT_ATTRIBUTES, *POBJECT_ATTRIBUTES;

#define OBJ_CASE_INSENSITIVE 0x00000040

/* PEB layout — NT 3.5 is compiled with pack(2), so BOOLEAN gets only
 * 1 byte of padding before HANDLE Mutant (not 3 as natural alignment
 * would give). Verified empirically by dumping the live PEB: Mutant
 * (0xFFFFFFFF) appears at offset 2, ImageBase at 6, ProcessHeap at 22.
 * pack(2) also matters for every later PEB access so we commit to the
 * full layout here rather than papering over with a single byte offset. */
#pragma pack(push, 2)
typedef struct _PEB {
    BOOLEAN InheritedAddressSpace;   /* +0x00 */
    HANDLE  Mutant;                  /* +0x02 */
    PVOID   ImageBaseAddress;        /* +0x06 */
    PVOID   Ldr;                     /* +0x0A */
    PVOID   ProcessParameters;       /* +0x0E */
    PVOID   SubSystemData;           /* +0x12 */
    PVOID   ProcessHeap;             /* +0x16 */
} PEB, *PPEB;
#pragma pack(pop)

/* ntdll prototypes */
extern PVOID    NTAPI RtlAllocateHeap  (HANDLE, ULONG, SIZE_T);
extern PVOID    NTAPI RtlReAllocateHeap(HANDLE, ULONG, PVOID, SIZE_T);
extern BOOLEAN  NTAPI RtlFreeHeap      (HANDLE, ULONG, PVOID);
extern void     NTAPI RtlInitUnicodeString(PUNICODE_STRING, PCWSTR);
extern BOOLEAN  NTAPI RtlDosPathNameToNtPathName_U(PCWSTR, PUNICODE_STRING,
                                                    PWSTR*, PVOID);

extern NTSTATUS NTAPI NtCreateFile(HANDLE*, ULONG DesiredAccess,
                                    POBJECT_ATTRIBUTES, PIO_STATUS_BLOCK,
                                    PLARGE_INTEGER AllocationSize,
                                    ULONG FileAttributes, ULONG ShareAccess,
                                    ULONG CreateDisposition,
                                    ULONG CreateOptions,
                                    PVOID EaBuffer, ULONG EaLength);
extern NTSTATUS NTAPI NtReadFile   (HANDLE, HANDLE Event, PVOID ApcRoutine,
                                    PVOID ApcContext, PIO_STATUS_BLOCK,
                                    PVOID Buffer, ULONG Length,
                                    PLARGE_INTEGER ByteOffset, PULONG Key);
extern NTSTATUS NTAPI NtWriteFile  (HANDLE, HANDLE Event, PVOID ApcRoutine,
                                    PVOID ApcContext, PIO_STATUS_BLOCK,
                                    PVOID Buffer, ULONG Length,
                                    PLARGE_INTEGER ByteOffset, PULONG Key);
extern NTSTATUS NTAPI NtClose      (HANDLE);
extern NTSTATUS NTAPI NtTerminateProcess(HANDLE, NTSTATUS);
extern NTSTATUS NTAPI NtQuerySystemTime(PLARGE_INTEGER);
extern NTSTATUS NTAPI NtQueryPerformanceCounter(PLARGE_INTEGER Counter,
                                                 PLARGE_INTEGER Frequency);

/* _vsnprintf from ntdll is cdecl and varargs. */
extern int _vsnprintf(char *, size_t, const char *, va_list);
extern ULONG DbgPrint(PCSTR, ...);

/* String/mem primitives from ntdll. */
void   *memcpy (void *, const void *, size_t);
void   *memset (void *, int, size_t);
int     memcmp (const void *, const void *, size_t);
size_t  strlen (const char *);
char   *strcpy (char *, const char *);

/* Access the PEB via the FS segment (TEB+0x30 = PEB*). */
static PPEB __ntshim_peb(void)
{
    PPEB peb;
    __asm__ volatile ("movl %%fs:0x30, %0" : "=r"(peb));
    return peb;
}

/* ============ Globals ================================================ */

int _ntshim_errno = 0;

static HANDLE         g_heap;
static LARGE_INTEGER  g_clock_start;    /* NtQueryPerformanceCounter epoch */
static LARGE_INTEGER  g_clock_freq;

/* ============ FILE ================================================== */

#define FFLAG_READ     0x0001
#define FFLAG_WRITE    0x0002
#define FFLAG_APPEND   0x0004
#define FFLAG_EOF      0x0010
#define FFLAG_ERR      0x0020
#define FFLAG_CONSOLE  0x0040   /* writes go through DbgPrint */
#define FFLAG_STATIC   0x0080   /* don't free on fclose (stdout/stderr) */

struct FILE {
    HANDLE handle;
    ULONG  flags;
    LARGE_INTEGER pos;
};

static struct FILE _stdin  = { 0, FFLAG_READ  | FFLAG_STATIC,                 {0,0} };
static struct FILE _stdout = { 0, FFLAG_WRITE | FFLAG_CONSOLE | FFLAG_STATIC, {0,0} };
static struct FILE _stderr = { 0, FFLAG_WRITE | FFLAG_CONSOLE | FFLAG_STATIC, {0,0} };

FILE *stdin  = &_stdin;
FILE *stdout = &_stdout;
FILE *stderr = &_stderr;

/* ============ Heap (malloc / free / realloc / calloc) =============== */

void *malloc(size_t n)
{
    return RtlAllocateHeap(g_heap, 0, (SIZE_T)n);
}

void *calloc(size_t n, size_t m)
{
    return RtlAllocateHeap(g_heap, HEAP_ZERO_MEMORY, (SIZE_T)(n * m));
}

void *realloc(void *p, size_t n)
{
    if (p == 0) return malloc(n);
    if (n == 0) { free(p); return 0; }
    return RtlReAllocateHeap(g_heap, 0, p, (SIZE_T)n);
}

void free(void *p)
{
    if (p) RtlFreeHeap(g_heap, 0, p);
}

/* ============ printf family ========================================= */

/* vsnprintf: ntdll's _vsnprintf doesn't null-terminate on overflow and
 * returns -1 in that case. We normalize to C99 semantics: always NUL,
 * return the number of chars that *would* have been written. */
int vsnprintf(char *buf, size_t sz, const char *fmt, va_list ap)
{
    int n;
    if (sz == 0) return 0;
    n = _vsnprintf(buf, sz, fmt, ap);
    if (n < 0 || (size_t)n >= sz) {
        buf[sz - 1] = 0;
        return (int)(sz - 1);         /* approximate — good enough for LuaJIT */
    }
    return n;
}

int snprintf(char *buf, size_t sz, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = vsnprintf(buf, sz, fmt, ap);
    va_end(ap);
    return n;
}

int sprintf(char *buf, const char *fmt, ...)
{
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = _vsnprintf(buf, 0x7FFFFFFF, fmt, ap);
    va_end(ap);
    return n;
}

int vfprintf(FILE *fp, const char *fmt, va_list ap)
{
    char buf[1024];
    int n = _vsnprintf(buf, sizeof(buf), fmt, ap);
    if (n < 0) { buf[sizeof(buf)-1] = 0; n = (int)strlen(buf); }
    return (int)fwrite(buf, 1, (size_t)n, fp);
}

int fprintf(FILE *fp, const char *fmt, ...)
{
    va_list ap; int n;
    va_start(ap, fmt);
    n = vfprintf(fp, fmt, ap);
    va_end(ap);
    return n;
}

int printf(const char *fmt, ...)
{
    va_list ap; int n;
    va_start(ap, fmt);
    n = vfprintf(stdout, fmt, ap);
    va_end(ap);
    return n;
}

/* ============ Basic stdio (fwrite / fputs / etc.) =================== */

size_t fwrite(const void *ptr, size_t size, size_t n, FILE *fp)
{
    IO_STATUS_BLOCK iosb;
    NTSTATUS st;
    ULONG total = (ULONG)(size * n);

    if (fp->flags & FFLAG_CONSOLE) {
        /* DbgPrint's internal buffer is 512 bytes; chunk. Use %.*s so
         * format-string injection from printed data can't hurt us. */
        const char *p = (const char *)ptr;
        ULONG left = total;
        while (left) {
            ULONG chunk = left > 480 ? 480 : left;
            DbgPrint("%.*s", (int)chunk, p);
            p    += chunk;
            left -= chunk;
        }
        return n;
    }

    if (!(fp->flags & FFLAG_WRITE) || !fp->handle) { fp->flags |= FFLAG_ERR; return 0; }
    st = NtWriteFile(fp->handle, 0, 0, 0, &iosb, (PVOID)ptr, total, &fp->pos, 0);
    if (!NT_SUCCESS(st)) { fp->flags |= FFLAG_ERR; return 0; }
    fp->pos.LowPart += (ULONG)iosb.Information;   /* no 64-bit wraps for us yet */
    return iosb.Information / (size ? size : 1);
}

size_t fread(void *ptr, size_t size, size_t n, FILE *fp)
{
    IO_STATUS_BLOCK iosb;
    NTSTATUS st;
    ULONG total = (ULONG)(size * n);

    if (!(fp->flags & FFLAG_READ) || !fp->handle) { fp->flags |= FFLAG_ERR; return 0; }
    st = NtReadFile(fp->handle, 0, 0, 0, &iosb, ptr, total, &fp->pos, 0);
    if (!NT_SUCCESS(st)) {
        /* STATUS_END_OF_FILE is 0xC0000011 — normal EOF, not an error. */
        if ((unsigned)st == 0xC0000011) fp->flags |= FFLAG_EOF;
        else                            fp->flags |= FFLAG_ERR;
        return 0;
    }
    fp->pos.LowPart += (ULONG)iosb.Information;
    return iosb.Information / (size ? size : 1);
}

int fputs(const char *s, FILE *fp)   { size_t n = strlen(s); return (int)fwrite(s, 1, n, fp); }
int fputc(int c, FILE *fp)           { unsigned char b = (unsigned char)c; fwrite(&b, 1, 1, fp); return c; }
int puts (const char *s)             { fputs(s, stdout); fputc('\n', stdout); return 0; }
int putchar(int c)                   { return fputc(c, stdout); }
int feof (FILE *fp)                  { return (fp->flags & FFLAG_EOF) ? 1 : 0; }
int ferror(FILE *fp)                 { return (fp->flags & FFLAG_ERR) ? 1 : 0; }
int fflush(FILE *fp)                 { (void)fp; return 0; }    /* unbuffered */

/* fgetc / fgets — byte-at-a-time; good enough until Lua's io.read appears. */
int fgetc(FILE *fp)
{
    unsigned char b;
    return fread(&b, 1, 1, fp) == 1 ? (int)b : EOF;
}

char *fgets(char *buf, int n, FILE *fp)
{
    int i, c;
    if (n <= 0) return 0;
    for (i = 0; i < n - 1; ) {
        c = fgetc(fp);
        if (c == EOF) { if (i == 0) return 0; else break; }
        buf[i++] = (char)c;
        if (c == '\n') break;
    }
    buf[i] = 0;
    return buf;
}

/* fopen / fclose — minimal. Only "r", "rb", "w", "wb", "a", "ab" supported;
 * anything else returns NULL. DOS paths ("C:\...") pass through
 * RtlDosPathNameToNtPathName_U for the kernel-side form. */
#define FILE_GENERIC_READ    0x00120089
#define FILE_GENERIC_WRITE   0x00120116
#define FILE_SHARE_READ      0x00000001
#define FILE_SHARE_WRITE     0x00000002
#define FILE_OPEN            0x00000001
#define FILE_CREATE          0x00000002
#define FILE_OVERWRITE_IF    0x00000005
#define FILE_OPEN_IF         0x00000003
#define FILE_SYNCHRONOUS_IO_NONALERT 0x00000020
#define FILE_NON_DIRECTORY_FILE      0x00000040

FILE *fopen(const char *path, const char *mode)
{
    UNICODE_STRING ntpath;
    OBJECT_ATTRIBUTES oa;
    IO_STATUS_BLOCK iosb;
    HANDLE h;
    ULONG access, disp, share, create_opts;
    ULONG fflags;
    NTSTATUS st;
    unsigned short wpath[512];
    size_t i, plen;
    FILE *fp;

    /* Parse mode — first char picks read/write/append; 'b' ignored. */
    access = 0; disp = 0; fflags = 0;
    switch (*mode) {
    case 'r': access = FILE_GENERIC_READ;  disp = FILE_OPEN;         fflags = FFLAG_READ;  break;
    case 'w': access = FILE_GENERIC_WRITE; disp = FILE_OVERWRITE_IF; fflags = FFLAG_WRITE; break;
    case 'a': access = FILE_GENERIC_WRITE; disp = FILE_OPEN_IF;      fflags = FFLAG_WRITE | FFLAG_APPEND; break;
    default:  return 0;
    }
    share      = FILE_SHARE_READ | FILE_SHARE_WRITE;
    create_opts = FILE_SYNCHRONOUS_IO_NONALERT | FILE_NON_DIRECTORY_FILE;

    /* ASCII → UTF-16 (caller must keep paths ASCII-only for now). */
    plen = strlen(path);
    if (plen >= sizeof(wpath) / 2) return 0;
    for (i = 0; i < plen; i++) wpath[i] = (unsigned short)(unsigned char)path[i];
    wpath[plen] = 0;

    if (!RtlDosPathNameToNtPathName_U((PCWSTR)wpath, &ntpath, 0, 0))
        return 0;

    oa.Length             = sizeof(oa);
    oa.RootDirectory      = 0;
    oa.ObjectName         = &ntpath;
    oa.Attributes         = OBJ_CASE_INSENSITIVE;
    oa.SecurityDescriptor = 0;
    oa.SecurityQualityOfService = 0;

    st = NtCreateFile(&h, access, &oa, &iosb, 0, 0x80 /* FILE_ATTRIBUTE_NORMAL */,
                      share, disp, create_opts, 0, 0);
    /* RtlDosPathNameToNtPathName_U's buffer is RtlAllocateHeap-owned —
     * leaking here for now; will revisit once we know who owns what. */
    if (!NT_SUCCESS(st)) return 0;

    fp = (FILE *)malloc(sizeof(*fp));
    if (!fp) { NtClose(h); return 0; }
    fp->handle   = h;
    fp->flags    = fflags;
    fp->pos.LowPart = fp->pos.HighPart = 0;
    return fp;
}

int fclose(FILE *fp)
{
    if (!fp) return EOF;
    if (fp->flags & FFLAG_STATIC) return 0;
    if (fp->handle) NtClose(fp->handle);
    free(fp);
    return 0;
}

int fseek(FILE *fp, long off, int whence)
{
    /* Only SEEK_SET + SEEK_CUR for now. SEEK_END needs NtQueryInformationFile. */
    switch (whence) {
    case SEEK_SET: fp->pos.LowPart = (ULONG)off; fp->pos.HighPart = off < 0 ? -1 : 0; return 0;
    case SEEK_CUR: fp->pos.LowPart += (ULONG)off; return 0;
    default:       fp->flags |= FFLAG_ERR; return -1;
    }
}

long ftell(FILE *fp) { return (long)fp->pos.LowPart; }

/* ============ String / mem gap-fillers ============================== */

void *memmove(void *dst, const void *src, size_t n)
{
    char *d = (char *)dst;
    const char *s = (const char *)src;
    if (d == s || n == 0) return dst;
    if (d < s) { while (n--) *d++ = *s++; }
    else       { d += n; s += n; while (n--) *--d = *--s; }
    return dst;
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b) { a++; b++; }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char *a, const char *b, size_t n)
{
    while (n && *a && *a == *b) { a++; b++; n--; }
    if (!n) return 0;
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

char *strncpy(char *dst, const char *src, size_t n)
{
    size_t i = 0;
    while (i < n && src[i]) { dst[i] = src[i]; i++; }
    while (i < n)            { dst[i++] = 0; }
    return dst;
}

char *strcat(char *dst, const char *src)
{
    char *d = dst + strlen(dst);
    while ((*d++ = *src++) != 0) {}
    return dst;
}

char *strchr(const char *s, int c)
{
    char target = (char)c;
    for (; *s; s++) if (*s == target) return (char *)s;
    return target == 0 ? (char *)s : 0;
}

char *strrchr(const char *s, int c)
{
    const char *last = 0;
    char target = (char)c;
    for (; *s; s++) if (*s == target) last = s;
    if (target == 0) return (char *)s;
    return (char *)last;
}

char *strstr(const char *hay, const char *needle)
{
    size_t nl = strlen(needle);
    if (nl == 0) return (char *)hay;
    for (; *hay; hay++) {
        if (*hay == *needle && strncmp(hay, needle, nl) == 0) return (char *)hay;
    }
    return 0;
}

/* ============ stdlib: atoi / strtol / strtod ======================== */

int atoi(const char *s)              { return (int)strtol(s, 0, 10); }
long atol(const char *s)             { return strtol(s, 0, 10); }

long strtol(const char *s, char **endp, int base)
{
    long result = 0;
    int  neg = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n') s++;
    if (*s == '+') s++;
    else if (*s == '-') { neg = 1; s++; }
    if (base == 0) {
        if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
        else if (s[0] == '0')                            { base = 8;  s++; }
        else                                              { base = 10; }
    } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
    }
    for (;;) {
        int d;
        char c = *s;
        if (c >= '0' && c <= '9')      d = c - '0';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
        else break;
        if (d >= base) break;
        result = result * base + d;
        s++;
    }
    if (endp) *endp = (char *)s;
    return neg ? -result : result;
}

/* strtod: naive — good enough for Lua's tonumber on well-formed input;
 * doesn't round-trip all IEEE754 bit patterns. Revisit if tests fail. */
double strtod(const char *s, char **endp)
{
    double result = 0, frac = 0, scale = 1;
    int neg = 0, exp_sign = 0, exp_val = 0, has_digits = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n') s++;
    if (*s == '+') s++;
    else if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') { result = result * 10 + (*s++ - '0'); has_digits = 1; }
    if (*s == '.') {
        s++;
        while (*s >= '0' && *s <= '9') {
            frac  = frac * 10 + (*s++ - '0');
            scale *= 10;
            has_digits = 1;
        }
        result += frac / scale;
    }
    if (has_digits && (*s == 'e' || *s == 'E')) {
        s++;
        if (*s == '+') s++;
        else if (*s == '-') { exp_sign = 1; s++; }
        while (*s >= '0' && *s <= '9') exp_val = exp_val * 10 + (*s++ - '0');
        {
            double m = 1;
            int i;
            for (i = 0; i < exp_val; i++) m *= 10;
            result = exp_sign ? result / m : result * m;
        }
    }
    if (endp) *endp = (char *)s;
    return neg ? -result : result;
}

/* ============ env / exit / abort ==================================== */

char *getenv(const char *name) { (void)name; return 0; }  /* TODO: walk PEB->ProcessParameters->Environment */

void exit(int status)    { NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)status); for(;;){} }
void abort(void)         { __asm__ volatile("int3"); NtTerminateProcess(NT_CURRENT_PROCESS, (NTSTATUS)0xC0000005); for(;;){} }

/* ============ Time ================================================== */

/* NT system time is 100ns intervals since 1601-01-01. Unix epoch is
 * 1970-01-01, 11644473600 seconds later. */
#define EPOCH_BIAS_SEC  11644473600LL

time_t time(time_t *tp)
{
    LARGE_INTEGER t;
    long long  ns100;
    long long  secs;
    NtQuerySystemTime(&t);
    ns100 = ((long long)t.HighPart << 32) | t.LowPart;
    secs  = ns100 / 10000000LL - EPOCH_BIAS_SEC;
    if (tp) *tp = (time_t)secs;
    return (time_t)secs;
}

clock_t clock(void)
{
    LARGE_INTEGER now;
    long long delta;
    long long freq;
    /* MicroNT's custom HAL stubs out NtQueryPerformanceCounter (it's an
     * HAL primitive on NT 3.5), so freq comes back 0. Fall back to
     * NtQuerySystemTime in 100ns ticks → millisecond-ish precision. */
    freq = ((long long)g_clock_freq.HighPart << 32) | g_clock_freq.LowPart;
    if (freq == 0) {
        LARGE_INTEGER t;
        NtQuerySystemTime(&t);
        delta = (((long long)t.HighPart << 32) | t.LowPart)
              - (((long long)g_clock_start.HighPart << 32) | g_clock_start.LowPart);
        /* System time is 100ns ticks; CLOCKS_PER_SEC is 1e6 → divide by 10. */
        return (clock_t)(delta / 10);
    }
    NtQueryPerformanceCounter(&now, 0);
    delta = (((long long)now.HighPart << 32) | now.LowPart)
          - (((long long)g_clock_start.HighPart << 32) | g_clock_start.LowPart);
    return (clock_t)((delta * CLOCKS_PER_SEC) / freq);
}

/* ============ mingw stdio glue ====================================== */

/* mingw's <stdio.h> defines stdin/stdout/stderr as macros that call
 * __acrt_iob_func(N). LuaJIT (and any consumer of mingw stdio.h) reads
 * them through that macro. Return our static FILE*s — note the index
 * convention differs from POSIX (index is just 0/1/2, no tags). */
FILE *__acrt_iob_func(unsigned index)
{
    switch (index) {
    case 0: return &_stdin;
    case 1: return &_stdout;
    case 2: return &_stderr;
    default: return 0;
    }
}

/* ============ Math intrinsics (JIT fpcalls table needs these) ======== */

/* libmingwex has log/exp/sqrt/atan2 but the less-common functions
 * (log10/asin/acos/sinh/cosh/tanh) only live in msvcrt.dll imports,
 * which we can't use under micront. Implement in terms of primitives
 * we do have. Accuracy is fine for LuaJIT's purposes — it's the same
 * numerical pattern musl/glibc use for the small-math functions. */

extern double log (double);
extern double exp (double);
extern double sqrt(double);
extern double atan2(double, double);

static const double LN_10 = 2.302585092994045684017991454684364207601101488628772976;
static const double PI_2  = 1.570796326794896619231321691639751442098584699687552910;

double log10(double x) { return log(x) / LN_10; }

double asin(double x)
{
    /* Domain [-1,1]; clamp to avoid NaN from sqrt on tiny overshoots. */
    if (x >=  1.0) return  PI_2;
    if (x <= -1.0) return -PI_2;
    return atan2(x, sqrt((1.0 - x) * (1.0 + x)));
}

double acos(double x)
{
    if (x >=  1.0) return 0.0;
    if (x <= -1.0) return 2.0 * PI_2;
    return atan2(sqrt((1.0 - x) * (1.0 + x)), x);
}

double sinh(double x)
{
    double e = exp(x);
    return (e - 1.0 / e) * 0.5;
}

double cosh(double x)
{
    double e = exp(x);
    return (e + 1.0 / e) * 0.5;
}

double tanh(double x)
{
    /* (e^2x - 1) / (e^2x + 1) — monotone, no cancellation for x > 0.
     * Saturate for large |x| to avoid exp overflow. */
    double e2;
    if (x >  20.0) return  1.0;
    if (x < -20.0) return -1.0;
    e2 = exp(2.0 * x);
    return (e2 - 1.0) / (e2 + 1.0);
}

/* ============ mingw/libgcc startup stubs ============================ */

/* libgcc's __main.o (called by mingw's default startup) registers a
 * dtor via atexit. We don't support atexit — no cleanup runs on native
 * NT ExitProcess. Return 0 (success) and forget. */
int atexit(void (*fn)(void)) { (void)fn; return 0; }

/* mingw's auto-import runtime helper. Pulled in unconditionally by any
 * binary that uses dllimport data; harmless no-op when we're not doing
 * that. Exists as a plain symbol so ld finds it. */
void _pei386_runtime_relocator(void) {}

/* ============ Shadow libntdllcrt's ntdll-sourced CRT bits =========== */

/* libntdllcrt.a lists _errno + strtoul as dllimports from ntdll.dll.
 * NT 3.5's ntdll doesn't export either — modern Windows added them —
 * so the loader bails with STATUS_ENTRYPOINT_NOT_FOUND before our
 * entry point runs. Define both here in the archive that's linked
 * before libntdllcrt to pre-empt the import-lib entries. */

int *_errno(void) { return &_ntshim_errno; }

unsigned long strtoul(const char *s, char **endp, int base)
{
    unsigned long result = 0;
    while (*s == ' ' || *s == '\t' || *s == '\n') s++;
    if (*s == '+') s++;                    /* reject leading '-' silently */
    if (base == 0) {
        if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) { base = 16; s += 2; }
        else if (s[0] == '0')                            { base = 8;  s++; }
        else                                              { base = 10; }
    } else if (base == 16 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) {
        s += 2;
    }
    for (;;) {
        int d;
        char c = *s;
        if      (c >= '0' && c <= '9') d = c - '0';
        else if (c >= 'a' && c <= 'z') d = c - 'a' + 10;
        else if (c >= 'A' && c <= 'Z') d = c - 'A' + 10;
        else break;
        if (d >= base) break;
        result = result * base + (unsigned long)d;
        s++;
    }
    if (endp) *endp = (char *)s;
    return result;
}

/* ============ Stubs for luajit.c CLI + lj_clib.c ==================== */

/* Signal handling: LuaJIT's CLI registers SIGINT to break out of long
 * Lua evaluations. We don't deliver signals on native NT — stub to a
 * no-op that pretends registration succeeded. */
typedef void (*__sighandler_t)(int);
__sighandler_t signal(int sig, __sighandler_t h) { (void)sig; (void)h; return 0; }

/* putc is a macro in real stdio.h that expands to fputc; mingw's has
 * it as a function too. LuaJIT's CLI uses it — forward to our fputc. */
int putc(int c, FILE *fp) { return fputc(c, fp); }

/* TTY detection for the REPL prompt. _isatty returns whether fd maps
 * to a terminal; _fileno maps FILE* → fd. Under native NT we have no
 * tty concept, and our stdio is serial-backed, so report "not a tty"
 * — LuaJIT then uses its batched read path instead of per-char. */
int _fileno(FILE *fp)     { (void)fp; return -1; }
int _isatty(int fd)       { (void)fd; return 0; }

/* lj_clib.c checks __p__fmode (msvcrt internal for text/binary default
 * file mode) when opening shared objects. Returns a pointer to an int;
 * 0 = _O_TEXT, which is the value LuaJIT wants. Static int lives here. */
static int _ntshim_fmode = 0;
int *__p__fmode(void)     { return &_ntshim_fmode; }

/* strerror — dead-simple textual errno. LuaJIT only passes the string
 * through to lua_pushstring, so the exact content doesn't matter; just
 * give something non-NULL. */
static char _strerror_buf[32];
char *strerror(int err)
{
    static const char digits[] = "0123456789";
    char *p = _strerror_buf;
    int i, n;
    const char *prefix = "errno ";
    for (i = 0; prefix[i]; i++) *p++ = prefix[i];
    if (err < 0) { *p++ = '-'; err = -err; }
    n = 0; { int t = err; do { n++; t /= 10; } while (t); }
    for (i = n - 1; i >= 0; i--) { p[i] = digits[err % 10]; err /= 10; }
    p += n;
    *p = 0;
    return _strerror_buf;
}

/* mingw's C++ SEH cleanup helper. lj_err.c's __try/__except pull in
 * the reference via libgcc's personality routine even when no C++ is
 * involved. Stub to no-op — our exception path is purely longjmp-based
 * so nothing ever needs the destructor. */
void __DestructExceptionObject(void *obj) { (void)obj; }

/* ============ libmingwex stubs ====================================== */

/* __mingw_raise_matherr is the SVR4-style math error hook invoked by
 * every math function in libmingwex (sin, cos, exp, log, sqrt, …) on
 * domain/range errors. The real definition lives in libmingw32.a, which
 * we don't link (it drags in the whole msvcrt startup bundle). Swallow
 * the report — math funcs still return their default NaN/Inf/clamped
 * value, which is what LuaJIT expects anyway. */
void __mingw_raise_matherr(int typ, const char *name,
                           double a1, double a2, double rslt)
{
    (void)typ; (void)name; (void)a1; (void)a2; (void)rslt;
}

/* ============ Init ================================================== */

void ntshim_init(void)
{
    PPEB peb = __ntshim_peb();
    g_heap = peb->ProcessHeap;
    NtQueryPerformanceCounter(&g_clock_start, &g_clock_freq);
    /* Perf-counter missing on micronnt's custom HAL — capture system time
     * as a fallback epoch so clock() returns monotonic deltas either way. */
    if (g_clock_freq.HighPart == 0 && g_clock_freq.LowPart == 0)
        NtQuerySystemTime(&g_clock_start);
}
