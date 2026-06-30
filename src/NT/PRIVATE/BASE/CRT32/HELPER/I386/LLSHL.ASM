        title   llshl - long shift left
;***
;llshl.asm - long shift left
;
;       Copyright (c) 1985-1994, Microsoft Corporation. All rights reserved.
;
;Purpose:
;       define long shift left routine (signed and unsigned are same)
;           __allshl
;
;*******************************************************************************


.xlist
include cruntime.inc
include mm.inc
.list

;***
;llshl - long shift left
;
;Purpose:
;       Does a Long Shift Left (signed and unsigned are identical)
;       Shifts a long left any number of bits.
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

_allshl PROC NEAR

;
; Ensure 1 <= shift count (cl)
;

        test    cl,cl
        je      L2              ; return if shift count is zero

;
; The shift loop.
;

L1:
        shl     eax,1           ; lo word; propagate 0 (zero); carry <- hi bit
        rcl     edx,1           ; hi word; lo bit <- carry; hi bit is lost
        dec     cl              ; decrement shift count (cl) and loop if not 0
        jne     L1

;
; Execute correct return
;
L2:

        ret     0

_allshl ENDP

        end
