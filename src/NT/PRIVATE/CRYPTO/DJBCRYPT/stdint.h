/*
 * stdint.h -- minimal C99 fixed-width-integer shim for djbcrypt.dll.
 *
 * The mid-90s MSVC C/C++ front-end that builds this component has no
 * <stdint.h>.  Monocypher (mono.cpp / monoed.cpp) needs the uintN_t /
 * intN_t names, so we provide just those, mapping the 64-bit types onto
 * MSVC's `__int64` (whose 64-bit mul/shift route through INT64.LIB).
 *
 * On a real toolchain (e.g. host gcc/clang KAT syntax checks) we defer to
 * the system header via #include_next so we never shadow the real types.
 */
#ifndef DJBCRYPT_STDINT_SHIM
#define DJBCRYPT_STDINT_SHIM

#if defined(_MSC_VER)

typedef signed char        int8_t;
typedef unsigned char      uint8_t;
typedef short              int16_t;
typedef unsigned short     uint16_t;
typedef int                int32_t;
typedef unsigned int       uint32_t;
typedef __int64            int64_t;
typedef unsigned __int64   uint64_t;

#else  /* modern host: use the real header (gcc/clang support #include_next) */
#include_next <stdint.h>
#endif

#endif /* DJBCRYPT_STDINT_SHIM */
