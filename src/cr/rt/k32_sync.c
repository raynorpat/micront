/*
 * k32_sync.c — Win32 critical-section wrappers over Rtl*CriticalSection.
 *
 * RTL_CRITICAL_SECTION is ~24 bytes on x86; the opaque storage in
 * CRITICAL_SECTION is sized to match. Pass-through only.
 */

#include "k32_internal.h"

extern void NTAPI RtlInitializeCriticalSection(void *);
extern void NTAPI RtlEnterCriticalSection     (void *);
extern void NTAPI RtlLeaveCriticalSection     (void *);
extern void NTAPI RtlDeleteCriticalSection    (void *);

void WINAPI InitializeCriticalSection(LPCRITICAL_SECTION cs) { RtlInitializeCriticalSection(cs); }
void WINAPI EnterCriticalSection     (LPCRITICAL_SECTION cs) { RtlEnterCriticalSection(cs); }
void WINAPI LeaveCriticalSection     (LPCRITICAL_SECTION cs) { RtlLeaveCriticalSection(cs); }
void WINAPI DeleteCriticalSection    (LPCRITICAL_SECTION cs) { RtlDeleteCriticalSection(cs); }
