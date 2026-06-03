/*********************************************************************
* Filename:   sha256.h
* Author:     Brad Conte (brad AT bradconte.com)
* Copyright:
* Disclaimer: This code is presented "as is" without any guarantees.
* Details:    Defines the API for the corresponding SHA1 implementation.
*********************************************************************/

#ifndef SHA256_H
#define SHA256_H

/*************************** HEADER FILES ***************************/
#include <stddef.h>

/****************************** MACROS ******************************/
#define SHA256_BLOCK_SIZE 32            /* SHA256 outputs a 32 byte digest */

/**************************** DATA TYPES ****************************/
typedef unsigned char BYTE;             /* 8-bit byte */
typedef unsigned int  WORD;             /* 32-bit word */

/* 64-bit message-length counter.  The mid-90s MSVC front-end lacks C99
   `long long`, so spell it __int64 there (64-bit ops route through
   INT64.LIB); modern hosts (KAT syntax checks) keep the standard type. */
#if defined(_MSC_VER)
typedef unsigned __int64 SHA_U64;
#else
typedef unsigned long long SHA_U64;
#endif

typedef struct {
	BYTE data[64];
	WORD datalen;
	SHA_U64 bitlen;
	WORD state[8];
} SHA256_CTX;

/*********************** FUNCTION DECLARATIONS **********************/
void sha256_init(SHA256_CTX *ctx);
void sha256_update(SHA256_CTX *ctx, const BYTE data[], size_t len);
void sha256_final(SHA256_CTX *ctx, BYTE hash[]);

#endif   /* SHA256_H */
