/************************************************************************/
/*                                                                      */
/* RCPP - Resource Compiler Pre-Processor for NT system                 */
/*                                                                      */
/* TOKENS.C - Token stuff, probably removable from RCPP                 */
/*                                                                      */
/* 27-Nov-90 w-BrianM  Update for NT from PM SDK RCPP                   */
/*                                                                      */
/************************************************************************/

/*
 * MicroNT fix: the original source included <stdio.h> and "rcpptype.h"
 * directly, bypassing prerc.h. prerc.h contains #pragma pack(2) which
 * sets keytab_t to 6 bytes (4-byte WCHAR* + 1-byte UCHAR + 1 pad).
 * Without it, keytab_t compiles as 8 bytes (default /Zp8 alignment),
 * but every other translation unit uses the 6-byte layout from prerc.h.
 * The mismatch causes Tokstrings[] to be emitted with 8-byte stride
 * while all callers index it with 6-byte stride, producing misaligned
 * reads and wild pointers — a crash in yylex on the first non-trivial
 * token.
 */
#include "prerc.h"
#pragma hdrstop
#include "rcppext.h"
#include "grammar.h"

/*
 * TOKENS - This file contains the initialized tables of text, token pairs for
 * all the C language symbols and keywords, and the mapped value for YACC.
 *
 * IMPORTANT : this MUST be in the same order as the %token list in grammar.y
 *
 */
keytab_t Tokstrings[] = {
#define DAT(tok1, name2, map3, il4, mmap5)      { name2, map3 },
#include "tokdat.h"
#undef DAT
        };
