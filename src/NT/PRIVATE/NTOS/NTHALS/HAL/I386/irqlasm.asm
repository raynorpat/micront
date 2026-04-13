        title   "KfLowerIrql"
;++
;
; Module Name:
;
;    irqlasm.asm
;
; Abstract:
;
;    MicroNT HAL: assembly KfLowerIrql that dispatches any pending
;    software interrupts (APC / DISPATCH) via SWInterruptHandlerTable.
;    This replaces the broken C version in irql.c: direct C-call
;    dispatch breaks SwapContext's stack invariants. The handlers in
;    swint.asm build a proper trap frame, so SwapContext can IRET
;    correctly when threads are swapped out/in across the dispatch.
;
;    Derived from NT 3.5's IXIRQL.ASM (HALX86).
;
;--

.386p
        .xlist
include hal386.inc
include callconv.inc
include i386\kimacro.inc
        .list

        extrn   FindHigherIrqlMask:dword
        extrn   SWInterruptHandlerTable:dword
        extrn   SWInterruptLookUpTable:byte

_DATA   SEGMENT DWORD PUBLIC 'DATA'
KliMsg      db      '[kli:',0
KliDispMsg  db      'DISPATCH]',0
_DATA   ends

_TEXT$02   SEGMENT DWORD PUBLIC 'CODE'
        ASSUME  DS:FLAT, ES:FLAT, SS:FLAT, FS:NOTHING, GS:NOTHING

;++
;
; KIRQL
; KfRaiseIrql (
;    IN KIRQL NewIrql  (ecx)
;    )
;
;--

cPublicFastCall KfRaiseIrql,1
cPublicFpo 0, 0
        movzx   eax, byte ptr PCR[PcIrql]       ; old irql
        mov     PCR[PcIrql], cl
        fstRET  KfRaiseIrql
fstENDP KfRaiseIrql

;++
;
; VOID
; KfLowerIrql (
;    IN KIRQL NewIrql  (ecx)
;    )
;
;    Lower IRQL. If any software interrupt at a level HIGHER than
;    NewIrql is pending in IRR, dispatch it via SWInterruptHandlerTable
;    BEFORE lowering, so the handler runs at its own IRQL.
;
;--

cPublicFastCall KfLowerIrql,1
cPublicFpo 0, 0
        movzx   ecx, cl                         ; dword extend new IRQL
        pushfd                                  ; save interrupt mode
        cli                                     ; disable interrupts
        mov     byte ptr PCR[PcIrql], cl        ; store new IRQL (byte!)
        mov     edx, PCR[PcIRR]
        and     edx, FindHigherIrqlMask[ecx*4]  ; bits strictly above NewIrql
        jnz     short kli_dispatch

        popfd                                   ; no SW int pending
        fstRET  KfLowerIrql

kli_dispatch:
        bsr     ecx, edx                        ; highest pending SW level
        mov     edx, 1
        shl     edx, cl
        xor     PCR[PcIRR], edx                 ; clear the IRR bit we'll service
        call    SWInterruptHandlerTable[ecx*4]  ; dispatch (builds trap frame)
        popfd
        fstRET  KfLowerIrql

fstENDP KfLowerIrql


;++
;
; KIRQL
; KeGetCurrentIrql(VOID)
;
;--

cPublicProc _KeGetCurrentIrql,0
        movzx   eax, byte ptr PCR[PcIrql]
        stdRET  _KeGetCurrentIrql
stdENDP _KeGetCurrentIrql

;++
;
; VOID
; KeRaiseIrql (
;    IN KIRQL NewIrql,
;    OUT PKIRQL OldIrql
;    )
;
;--

cPublicProc _KeRaiseIrql,2
        mov     ecx, [esp+4]                    ; NewIrql
        mov     eax, [esp+8]                    ; OldIrql*
        mov     dl, PCR[PcIrql]
        mov     [eax], dl
        mov     PCR[PcIrql], cl
        stdRET  _KeRaiseIrql
stdENDP _KeRaiseIrql

;++
;
; VOID
; KeLowerIrql (
;    IN KIRQL NewIrql
;    )
;
;--

cPublicProc _KeLowerIrql,1
        mov     ecx, [esp+4]
        fstCall KfLowerIrql
        stdRET  _KeLowerIrql
stdENDP _KeLowerIrql

_TEXT$02   ends

        end
