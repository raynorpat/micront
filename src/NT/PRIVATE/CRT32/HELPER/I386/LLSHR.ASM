        title   llshr - long shift right
;***
;llshr.asm - long shift right
;
;       Copyright (c) 1985-1994, Microsoft Corporation. All rights reserved.
;
;Purpose:
;       define signed long shift right routine
;           __allshr
;
;*******************************************************************************


.xlist
include cruntime.inc
include mm.inc
.list

;***
;llshr - long shift right
;
;Purpose:
;       Does a signed Long Shift Right
;       Shifts a long right any number of bits.
;
;Entry:
;       EDX:EAX - long value to be shifted
;       CL    - number of bits to shift by
;
;Exit:
;       EDX:EAX - shifted value
;
;Uses:
;       CL is destroyed.
;
;Exceptions:
;
;*******************************************************************************

        CODESEG

_allshr PROC NEAR

;
; Ensure 1 <= shift count (cl)
;

        test    cl,cl
        je      L2              ; return if shift count is zero

;
; The shift loop.
;

L1:
        sar     edx,1
        rcr     eax,1
        dec     cl              ; decrement shift count (cl) and loop if not 0
        jne     L1

;
; Execute correct return
;
L2:

        ret     0

_allshr ENDP

        end
