/*++

Module Name:

    cbc.c

Abstract:

    This module implements the DES CBC mode cipher functions.

Author:

    Pat Raynor (raynorpat) June 7 2026

Notes:

    This module invokes the DES cryptographic functions implemented in des.c.

    Cipher Block Chaining (CBC) processes the source buffer one eight-byte
    block at a time.  When encrypting, each plaintext block is XORed with the
    preceding ciphertext block (or with the initialisation vector for the
    first block) before being passed through the DES block cipher.  When
    decrypting, each ciphertext block is passed through the DES block cipher
    and the result is XORed with the preceding ciphertext block (or with the
    initialisation vector for the first block) to recover the plaintext.

    Any trailing bytes that do not constitute a full eight-byte block are
    ignored; the caller is responsible for padding the source buffer.

Revision History:

--*/

#include <windef.h>

#include "des.h"
#include "descrypt.h"

#define DES_BLOCKLEN    8

unsigned FAR _CRTAPI1
DES_CBC(    unsigned            Option,
            const char FAR *    Key,
            unsigned char FAR * IV,
            unsigned char FAR * Source,
            unsigned char FAR * Dest,
            unsigned            Size)
{
    int                 crypt_mode;
    unsigned            blocks;
    unsigned            b;
    int                 i;
    unsigned char       Chain[DES_BLOCKLEN];
    unsigned char       Cipher[DES_BLOCKLEN];

    //
    // Verify the destination buffer pointer
    //

    if (Dest == NULL)
        return 1;

    //
    // Verify the source buffer pointer
    //

    if (Source == NULL)
        return 1;

    //
    // Verify the initialisation vector pointer
    //

    if (IV == NULL)
        return 1;

    //
    // Initialise DES module key
    //

    InitNormalKey(Key);

    //
    // Verify the option
    //

    switch (Option)
    {
        case 0:     crypt_mode = 1; break;  // Option 0 (encrypt)
        case 1:     crypt_mode = 0; break;  // Option 1 (decrypt)
        default:    return 1;               // Invalid option
    }

    //
    // Seed the chaining block with the initialisation vector
    //

    for (i = 0; i < DES_BLOCKLEN; i++)
        Chain[i] = IV[i];

    //
    // Process the buffer one whole block at a time
    //

    blocks = Size / DES_BLOCKLEN;

    for (b = 0; b < blocks; b++)
    {
        unsigned char FAR * Src = Source + (b * DES_BLOCKLEN);
        unsigned char FAR * Dst = Dest   + (b * DES_BLOCKLEN);

        if (Option == 0)
        {
            //
            // Encrypt: XOR the plaintext with the previous ciphertext
            // (or the IV for the first block), then run the block cipher.
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Cipher[i] = (unsigned char)(Src[i] ^ Chain[i]);

            desf(Cipher, Dst, crypt_mode);

            //
            // The ciphertext just produced chains into the next block
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Chain[i] = Dst[i];
        }
        else
        {
            //
            // Decrypt: preserve the ciphertext before it is (possibly)
            // overwritten in place, run the block cipher, then XOR the
            // result with the previous ciphertext (or the IV).
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Cipher[i] = Src[i];

            desf(Src, Dst, crypt_mode);

            for (i = 0; i < DES_BLOCKLEN; i++)
                Dst[i] = (unsigned char)(Dst[i] ^ Chain[i]);

            //
            // The original ciphertext chains into the next block
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Chain[i] = Cipher[i];
        }
    }

    return 0;
}

unsigned FAR _CRTAPI1
DES_CBC_LM( unsigned            Option,
            const char FAR *    Key,
            unsigned char FAR * IV,
            unsigned char FAR * Source,
            unsigned char FAR * Dest,
            unsigned            Size)
{
    int                 crypt_mode;
    unsigned            blocks;
    unsigned            b;
    int                 i;
    unsigned char       Chain[DES_BLOCKLEN];
    unsigned char       Cipher[DES_BLOCKLEN];

    //
    // Verify the destination buffer pointer
    //

    if (Dest == NULL)
        return 1;

    //
    // Verify the source buffer pointer
    //

    if (Source == NULL)
        return 1;

    //
    // Verify the initialisation vector pointer
    //

    if (IV == NULL)
        return 1;

    //
    // Initialise DES module key
    //

    InitLanManKey(Key);

    //
    // Verify the option
    //

    switch (Option)
    {
        case 0:     crypt_mode = 1; break;  // Option 0 (encrypt)
        case 1:     crypt_mode = 0; break;  // Option 1 (decrypt)
        default:    return 1;               // Invalid option
    }

    //
    // Seed the chaining block with the initialisation vector
    //

    for (i = 0; i < DES_BLOCKLEN; i++)
        Chain[i] = IV[i];

    //
    // Process the buffer one whole block at a time
    //

    blocks = Size / DES_BLOCKLEN;

    for (b = 0; b < blocks; b++)
    {
        unsigned char FAR * Src = Source + (b * DES_BLOCKLEN);
        unsigned char FAR * Dst = Dest   + (b * DES_BLOCKLEN);

        if (Option == 0)
        {
            //
            // Encrypt: XOR the plaintext with the previous ciphertext
            // (or the IV for the first block), then run the block cipher.
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Cipher[i] = (unsigned char)(Src[i] ^ Chain[i]);

            desf(Cipher, Dst, crypt_mode);

            //
            // The ciphertext just produced chains into the next block
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Chain[i] = Dst[i];
        }
        else
        {
            //
            // Decrypt: preserve the ciphertext before it is (possibly)
            // overwritten in place, run the block cipher, then XOR the
            // result with the previous ciphertext (or the IV).
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Cipher[i] = Src[i];

            desf(Src, Dst, crypt_mode);

            for (i = 0; i < DES_BLOCKLEN; i++)
                Dst[i] = (unsigned char)(Dst[i] ^ Chain[i]);

            //
            // The original ciphertext chains into the next block
            //

            for (i = 0; i < DES_BLOCKLEN; i++)
                Chain[i] = Cipher[i];
        }
    }

    return 0;
}
