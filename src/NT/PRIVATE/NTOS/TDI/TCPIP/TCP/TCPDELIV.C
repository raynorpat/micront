/********************************************************************/
/**                     Microsoft LAN Manager                      **/
/**               Copyright(c) Microsoft Corp., 1990-1993          **/
/********************************************************************/
/* :ts=4 */

//** TCPDELIV.C - TCP deliver data code.
//
//  This file contains the code for delivering data to the user, including
//  putting data into recv. buffers and calling indication handlers.
//

#include    "oscfg.h"
#include    "ndis.h"
#include    "cxport.h"
#include    "ip.h"
#include    "tdi.h"
#ifdef VXD
#include    "tdivxd.h"
#include    "tdistat.h"
#endif
#ifdef NT
#include    "tdint.h"
#include    "tdistat.h"
#endif
#include    "queue.h"
#include    "addr.h"
#include    "tcp.h"
#include    "tcb.h"
#include    "tcprcv.h"
#include	"tcpsend.h"
#include    "tcpconn.h"
#include    "tcpdeliv.h"
#include    "tlcommon.h"

EXTERNAL_LOCK(AddrObjTableLock)

extern void
PutOnRAQ(TCB *RcvTCB, TCPRcvInfo *RcvInfo, IPRcvBuf *RcvBuf, uint Size);

TCPRcvReq       *TCPRcvReqFree = NULL;   // Rcv req. free list.
DEFINE_LOCK_STRUCTURE(TCPRcvReqFreeLock) // Protects rcv req free list.
uint            NumTCPRcvReq = 0;        // Current number of RcvReqs in system.
uint            MaxRcvReq = 0xffffffff;  // Maximum allowed number of SendReqs.

#ifdef NT

NTSTATUS
TCPPrepareIrpForCancel(
    PTCP_CONTEXT    TcpContext,
	PIRP            Irp,
	PDRIVER_CANCEL  CancelRoutine
	);

ULONG
TCPGetMdlChainByteCount(
    PMDL   Mdl
	);

void
TCPDataRequestComplete(
    void          *Context,
    unsigned int   Status,
    unsigned int   ByteCount
    );

VOID
TCPCancelRequest(
    PDEVICE_OBJECT          Device,
	PIRP                    Irp
	);

#endif // NT


//* FreeRcvReq - Free a rcv request structure.
//
//  Called to free a rcv request structure.
//
//  Input:  FreedReq    - Rcv request structure to be freed.
//
//  Returns: Nothing.
//
void
FreeRcvReq(TCPRcvReq *FreedReq)
{
#ifdef NT

    PSINGLE_LIST_ENTRY BufferLink;

    CTEStructAssert(FreedReq, trr);

    BufferLink = STRUCT_OF(SINGLE_LIST_ENTRY, &(FreedReq->trr_next), Next);

	ExInterlockedPushEntryList(
	    STRUCT_OF(SINGLE_LIST_ENTRY, &TCPRcvReqFree, Next),
		BufferLink,
		&TCPRcvReqFreeLock
		);

#else // NT

    TCPRcvReq       **Temp;

    CTEStructAssert(FreedReq, trr);

    FreedReq->trr_next = TCPRcvReqFree;
    TCPRcvReqFree = FreedReq;

#endif // NT
}

//* GetRcvReq - Get a recv. request structure.
//
//  Called to get a rcv. request structure.
//
//  Input:  Nothing.
//
//  Returns: Pointer to RcvReq structure, or NULL if none.
//
TCPRcvReq *
GetRcvReq(void)
{
    TCPRcvReq       *Temp;

#ifdef NT

    PSINGLE_LIST_ENTRY   BufferLink;

    BufferLink = STRUCT_OF(SINGLE_LIST_ENTRY, &TCPRcvReqFree, Next);

    BufferLink = ExInterlockedPopEntryList(
                     BufferLink,
                     &TCPRcvReqFreeLock
                     );

    if (BufferLink != NULL) {
        Temp = STRUCT_OF(TCPRcvReq, BufferLink, trr_next);
        CTEStructAssert(Temp, trr);
    }
    else {
        if (NumTCPRcvReq < MaxRcvReq)
            Temp = CTEAllocMem(sizeof(TCPRcvReq));
        else
            Temp = NULL;

        if (Temp != NULL) {
            ExInterlockedAddUlong(&NumTCPRcvReq, 1, &TCPRcvReqFreeLock);
#ifdef DEBUG
            Temp->trr_sig = trr_signature;
#endif
        }
    }

#else // NT

    Temp = TCPRcvReqFree;
    if (Temp != NULL)
        TCPRcvReqFree = Temp->trr_next;
    else {
        if (NumTCPRcvReq < MaxRcvReq)
            Temp = CTEAllocMem(sizeof(TCPRcvReq));
        else
            Temp = NULL;

        if (Temp != NULL) {
            NumTCPRcvReq++;
#ifdef DEBUG
            Temp->trr_sig = trr_signature;
#endif
        }
    }

#endif // NT

    return Temp;
}



//* FindLastBuffer - Find the last buffer in a chain.
//
//  A utility routine to find the last buffer in an rb chain.
//
//  Input:  Buf         - Pointer to RB chain.
//
//  Returns: Pointer to last buf in chain.
//
IPRcvBuf *
FindLastBuffer(IPRcvBuf *Buf)
{
    CTEAssert(Buf != NULL);

    while (Buf->ipr_next != NULL)
        Buf = Buf->ipr_next;

    return Buf;
}


//* FreePartialRB - Free part of an RB chain.
//
//  Called to adjust an free part of an RB chain. We walk down the chain,
//  trying to free buffers.
//
//  Input:  RB          - RB chain to be adjusted.
//          Size        - Size in bytes to be freed.
//
//  Returns: Pointer to adjusted RB chain.
//
IPRcvBuf *
FreePartialRB(IPRcvBuf *RB, uint Size)
{
    while (Size != 0) {
        IPRcvBuf        *TempBuf;

        CTEAssert(RB != NULL);

        if (Size >= RB->ipr_size) {
            Size -= RB->ipr_size;
            TempBuf = RB;
            RB = RB->ipr_next;
            if (TempBuf->ipr_owner == IPR_OWNER_TCP)
                CTEFreeMem(TempBuf);
        } else {
            RB->ipr_size -= Size;
            RB->ipr_buffer += Size;
            break;
        }
    }

    CTEAssert(RB != NULL);
    return RB;

}

//* CopyRBChain - Copy a chain of IP rcv buffers.
//
//  Called to copy a chain of IP rcv buffers. We don't copy a buffer if it's
//  already owner by TCP. We assume that all non-TCP owned buffers start
//  before any TCP owner buffers, so we quit when we copy to a TCP owner buffer.
//
//  Input:  OrigBuf             - Buffer chain to copy from.
//          LastBuf             - Where to return pointer to last buffer in
//                                  chain.
//          Size                - Maximum size in bytes to copy.
//
//  Returns: Pointer to new buffer chain.
//
IPRcvBuf *
CopyRBChain(IPRcvBuf *OrigBuf, IPRcvBuf **LastBuf, uint Size)
{
    IPRcvBuf        *FirstBuf, *EndBuf;
    uint            BytesToCopy;

    CTEAssert(OrigBuf != NULL);
    CTEAssert(Size > 0);

    if (OrigBuf->ipr_owner != IPR_OWNER_TCP) {

        BytesToCopy = MIN(Size, OrigBuf->ipr_size);
        FirstBuf = CTEAllocMem(sizeof(IPRcvBuf) + BytesToCopy);
        if (FirstBuf != NULL) {
            EndBuf = FirstBuf;
            FirstBuf->ipr_next = NULL;
            FirstBuf->ipr_owner = IPR_OWNER_TCP;
            FirstBuf->ipr_size = BytesToCopy;
            FirstBuf->ipr_buffer = (uchar *)(FirstBuf + 1);
            CTEMemCopy(FirstBuf->ipr_buffer, OrigBuf->ipr_buffer,
                BytesToCopy);
            Size -= BytesToCopy;
            OrigBuf = OrigBuf->ipr_next;
            while (OrigBuf != NULL && OrigBuf->ipr_owner != IPR_OWNER_TCP
                && Size != 0) {
                IPRcvBuf        *NewBuf;

                BytesToCopy = MIN(Size, OrigBuf->ipr_size);
                NewBuf = CTEAllocMem(sizeof(IPRcvBuf) + BytesToCopy);
                if (NewBuf != NULL) {
                    NewBuf->ipr_next = NULL;
                    NewBuf->ipr_owner = IPR_OWNER_TCP;
                    NewBuf->ipr_size = BytesToCopy;
                    NewBuf->ipr_buffer = (uchar *)(NewBuf + 1);
                    CTEMemCopy(NewBuf->ipr_buffer, OrigBuf->ipr_buffer,
                        BytesToCopy);
                    EndBuf->ipr_next = NewBuf;
                    EndBuf = NewBuf;
                    Size -= BytesToCopy;
                    OrigBuf = OrigBuf->ipr_next;
                } else {
                    FreeRBChain(FirstBuf);
                    return NULL;
                }
            }
            EndBuf->ipr_next = OrigBuf;
        } else
            return NULL;
    } else {
        FirstBuf = OrigBuf;
        EndBuf = OrigBuf;
        if (Size < OrigBuf->ipr_size)
            OrigBuf->ipr_size = Size;
        Size -= OrigBuf->ipr_size;
    }

    // Now walk down the chain, until we  run out of
    // Size. At this point, Size is the bytes left to 'copy' (it may be 0),
    // and the sizes in buffers FirstBuf...EndBuf are correct.
    while (Size != 0) {

        EndBuf = EndBuf->ipr_next;
        CTEAssert(EndBuf != NULL);

        if (Size < EndBuf->ipr_size)
            EndBuf->ipr_size = Size;

        Size -= EndBuf->ipr_size;
    }

    // If there's anything left in the chain, free it now.
    if (EndBuf->ipr_next != NULL) {
        FreeRBChain(EndBuf->ipr_next);
        EndBuf->ipr_next = NULL;
    }

    *LastBuf = EndBuf;
    return FirstBuf;

}

//* PendData - Pend incoming data to a client.
//
//  Called when we need to buffer data for a client because there's no receive
//  down and we can't indicate.
//
//  The TCB lock is held throughout this procedure. If this is to be changed,
//  make sure consistency of tcb_pendingcnt is preserved. This routine is
//	always called at DPC level.
//
//  Input:  RcvTCB              - TCB on which to receive the data.
//          RcvFlags            - TCP flags for the incoming packet.
//          InBuffer            - Input buffer of packet.
//          Size                - Size in bytes of data in InBuffer.
//
//  Returns: Number of bytes of data taken.
//
uint
PendData(TCB *RcvTCB, uint RcvFlags, IPRcvBuf *InBuffer, uint Size)
{

    IPRcvBuf        *NewBuf, *LastBuf;

    CTEStructAssert(RcvTCB, tcb);
    CTEAssert(Size > 0);
    CTEAssert(InBuffer != NULL);

    CTEAssert(RcvTCB->tcb_refcnt != 0);
    CTEAssert(RcvTCB->tcb_fastchk & TCP_FLAG_IN_RCV);
    CTEAssert(RcvTCB->tcb_currcv == NULL);
    CTEAssert(RcvTCB->tcb_rcvhndlr == PendData);

    CheckRBList(RcvTCB->tcb_pendhead, RcvTCB->tcb_pendingcnt);

    NewBuf = CopyRBChain(InBuffer, &LastBuf, Size);
    if (NewBuf != NULL) {
        // We have a duplicate chain. Put it on the end of the
        // pending q.
        if (RcvTCB->tcb_pendhead == NULL) {
            RcvTCB->tcb_pendhead = NewBuf;
            RcvTCB->tcb_pendtail = LastBuf;
        } else {
            RcvTCB->tcb_pendtail->ipr_next = NewBuf;
            RcvTCB->tcb_pendtail = LastBuf;
        }
        RcvTCB->tcb_pendingcnt += Size;
    } else {
        FreeRBChain(InBuffer);
        Size = 0;
    }

    CheckRBList(RcvTCB->tcb_pendhead, RcvTCB->tcb_pendingcnt);

    return Size;

}



//* BufferData - Put incoming data into client's buffer.
//
//  Called when we believe we have a buffer into which we can put data. We put
//  it in there, and if we've filled the buffer or the incoming data has the
//  push flag set we'll mark the TCB to return the buffer. Otherwise we'll
//  get out and return the data later.
//
//  In NT, this routine is called with the TCB lock held, and holds it for
//  the duration of the call. This is important to ensure consistency of
//  the tcb_pendingcnt field. If we need to change this to free the lock
//  partway through, make sure to take this into account. In particular,
//  TdiReceive zeros pendingcnt before calling this routine, and this routine
//  may update it. If the lock is freed in here there would be a window where
//  we really do have pending data, but it's not on the list or reflected in
//  pendingcnt. This could screw up our windowing computations, and we'd have
//	to be careful not to end up with more data pending than our window allows.
//
//  Input:  RcvTCB              - TCB on which to receive the data.
//          RcvFlags            - TCP rcv flags for the incoming packet.
//          InBuffer            - Input buffer of packet.
//          Size                - Size in bytes of data in InBuffer.
//
//  Returns: Number of bytes of data taken.
//
uint
BufferData(TCB *RcvTCB, uint RcvFlags, IPRcvBuf *InBuffer, uint Size)

{
    uchar           *DestPtr;               // Destination pointer.
    uchar           *SrcPtr;                // Src pointer.
    uint            SrcSize, DestSize;      // Sizes of current source and
                                            // destination buffers.
    uint            Copied;                 // Total bytes to copy.
    uint            BytesToCopy;            // Bytes of data to copy this time.
    TCPRcvReq       *DestReq;               // Current receive request.
    IPRcvBuf        *SrcBuf;                // Current source buffer.
    PNDIS_BUFFER    DestBuf;                // Current receive buffer.
    uint            RcvCmpltd;
    uint            Flags;

    CTEStructAssert(RcvTCB, tcb);
    CTEAssert(Size > 0);
    CTEAssert(InBuffer != NULL);

    CTEAssert(RcvTCB->tcb_refcnt != 0);
    CTEAssert(RcvTCB->tcb_rcvhndlr == BufferData);

    Copied = 0;
    RcvCmpltd = 0;

    DestReq = RcvTCB->tcb_currcv;

    CTEAssert(DestReq != NULL);
    CTEStructAssert(DestReq, trr);

    DestBuf = DestReq->trr_buffer;

    DestSize = MIN(NdisBufferLength(DestBuf) - DestReq->trr_offset,
	               DestReq->trr_size - DestReq->trr_amt);
    DestPtr = (uchar *)NdisBufferVirtualAddress(DestBuf) + DestReq->trr_offset;

    SrcBuf = InBuffer;
    SrcSize = SrcBuf->ipr_size;
    SrcPtr = SrcBuf->ipr_buffer;

    Flags = (RcvFlags & TCP_FLAG_PUSH) ? TRR_PUSHED : 0;
    RcvCmpltd = Flags;
    DestReq->trr_flags |= Flags;

    do {

        BytesToCopy = MIN(Size - Copied, MIN(SrcSize, DestSize));

        CTEMemCopy(DestPtr, SrcPtr, BytesToCopy);
        Copied += BytesToCopy;
        DestReq->trr_amt += BytesToCopy;

        // Update our source pointers.
        if ((SrcSize -= BytesToCopy) == 0) {
            IPRcvBuf        *TempBuf;

            // We've copied everything in this buffer.
            TempBuf = SrcBuf;
            SrcBuf = SrcBuf->ipr_next;
            if (Size != Copied) {
                CTEAssert(SrcBuf != NULL);
                SrcSize = SrcBuf->ipr_size;
                SrcPtr = SrcBuf->ipr_buffer;
            }
            if (TempBuf->ipr_owner == IPR_OWNER_TCP)
                CTEFreeMem(TempBuf);
        } else
            SrcPtr += BytesToCopy;

        // Now check the destination pointer, and update it if we need to.
        if ((DestSize -= BytesToCopy) == 0) {
            uint        DestAvail;

            // Exhausted this buffer. See if there's another one.
            DestAvail = DestReq->trr_size - DestReq->trr_amt;
            DestBuf = NDIS_BUFFER_LINKAGE(DestBuf);

            if (DestBuf != NULL && (DestAvail != 0)) {
                // Have another buffer in the chain. Update things.
                DestSize = MIN(NdisBufferLength(DestBuf), DestAvail);
                DestPtr = (uchar *)NdisBufferVirtualAddress(DestBuf);
            } else {
                // No more buffers in the chain. See if we have another buffer
                // on the list.
                DestReq->trr_flags |= TRR_PUSHED;
				
				// If we've been told there's to be no back traffic, get an ACK
				// going right away.
				if (DestReq->trr_flags & TDI_RECEIVE_NO_RESPONSE_EXP)
                	DelayAction(RcvTCB, NEED_ACK);
					
                RcvCmpltd = TRUE;
                DestReq = DestReq->trr_next;
                if (DestReq != NULL) {
                    DestBuf = DestReq->trr_buffer;
                    DestSize = MIN(NdisBufferLength(DestBuf), DestReq->trr_size);
                    DestPtr = (uchar *)NdisBufferVirtualAddress(DestBuf);

                    // If we have more to put into here, set the flags.
                    if (Copied != Size)
                        DestReq->trr_flags |= Flags;

                } else {
                    // All out of buffer space. Reset the data handler pointer.
                    break;
                }
            }
        } else
            // Current buffer not empty yet.
            DestPtr += BytesToCopy;


        // If we've copied all that we need to, we're done.
    } while (Copied != Size);

    // We've finished copying, and have a few more things to do. We need to
    // update the current rcv. pointer and possibly the offset in the
    // recv. request. If we need to complete any receives we have to schedule
    // that. If there's any data we couldn't copy we'll need to dispose of
    // it.
    RcvTCB->tcb_currcv = DestReq;
    if (DestReq != NULL) {
        DestReq->trr_buffer = DestBuf;
        DestReq->trr_offset = DestPtr - (uchar *) NdisBufferVirtualAddress(DestBuf);
        RcvTCB->tcb_rcvhndlr = BufferData;
    } else
        RcvTCB->tcb_rcvhndlr = PendData;

    RcvTCB->tcb_indicated -= MIN(Copied, RcvTCB->tcb_indicated);

    if (Size != Copied) {
        IPRcvBuf        *NewBuf, *LastBuf;

        CTEAssert(DestReq == NULL);

        // We have data to dispose of. Update the first buffer of the chain
        // with the current src pointer and size, and copy it.
        CTEAssert(SrcSize <= SrcBuf->ipr_size);
        CTEAssert(
		    ((uint) (SrcPtr - SrcBuf->ipr_buffer)) ==
		    (SrcBuf->ipr_size - SrcSize)
			);

        SrcBuf->ipr_buffer = SrcPtr;
        SrcBuf->ipr_size = SrcSize;

        NewBuf = CopyRBChain(SrcBuf, &LastBuf, Size - Copied);
        if (NewBuf != NULL) {
            // We managed to copy the buffer. Push it on the pending queue.
            if (RcvTCB->tcb_pendhead == NULL) {
                RcvTCB->tcb_pendhead = NewBuf;
                RcvTCB->tcb_pendtail = LastBuf;
            } else {
                LastBuf->ipr_next = RcvTCB->tcb_pendhead;
                RcvTCB->tcb_pendhead = NewBuf;
            }
            RcvTCB->tcb_pendingcnt += Size - Copied;
            Copied = Size;

            CheckRBList(RcvTCB->tcb_pendhead, RcvTCB->tcb_pendingcnt);

        } else
            FreeRBChain(SrcBuf);
    } else {
        // We copied Size bytes, but the chain could be longer than that. Free
        // it if we need to.
        if (SrcBuf != NULL)
            FreeRBChain(SrcBuf);
    }


    if (RcvCmpltd != 0) {
        DelayAction(RcvTCB, NEED_RCV_CMPLT);
	} else {
		START_TCB_TIMER(RcvTCB->tcb_pushtimer, PUSH_TO);
	}

    return Copied;

}


//* IndicateData - Indicate incoming data to a client.
//
//  Called when we need to indicate data to an upper layer client. We'll pass
//  up a pointer to whatever we have available, and the client may take some
//  or all of it.
//
//  Input:  RcvTCB              - TCB on which to receive the data.
//          RcvFlags            - TCP rcv flags for the incoming packet.
//          InBuffer            - Input buffer of packet.
//          Size                - Size in bytes of data in InBuffer.
//
//  Returns: Number of bytes of data taken.
//
uint
IndicateData(TCB *RcvTCB, uint RcvFlags, IPRcvBuf *InBuffer, uint Size)
{

    TDI_STATUS      Status;
    PRcvEvent       Event;
    PVOID           EventContext, ConnContext;
    uint            BytesTaken = 0;
#ifdef NT
    EventRcvBuffer *ERB = NULL;
#else
    EventRcvBuffer  ERB;
#endif
    TCPRcvReq       *RcvReq;
    IPRcvBuf        *NewBuf;
	ulong			IndFlags;
	

    CTEStructAssert(RcvTCB, tcb);
    CTEAssert(Size > 0);
    CTEAssert(InBuffer != NULL);

    CTEAssert(RcvTCB->tcb_refcnt != 0);
    CTEAssert(RcvTCB->tcb_fastchk & TCP_FLAG_IN_RCV);
    CTEAssert(RcvTCB->tcb_rcvind != NULL);
    CTEAssert(RcvTCB->tcb_rcvhead == NULL);
    CTEAssert(RcvTCB->tcb_rcvhndlr == IndicateData);

    RcvReq = GetRcvReq();
    if (RcvReq != NULL) {
        // The indicate handler is saved in the TCB. Just call up into it.
        Event = RcvTCB->tcb_rcvind;
        EventContext = RcvTCB->tcb_ricontext;
        ConnContext = RcvTCB->tcb_conncontext;
        RcvTCB->tcb_indicated = Size;
        RcvTCB->tcb_flags |= IN_RCV_IND;

#ifndef	VXD
        CTEFreeLockFromDPC(&RcvTCB->tcb_lock, NULL);
#endif

		IF_TCPDBG(TCP_DEBUG_RECEIVE) {
            TCPTRACE((
			    "Indicating %lu bytes, %lu available\n",
				InBuffer->ipr_size, Size
				));
		}

#if TCP_FLAG_PUSH >= TDI_RECEIVE_ENTIRE_MESSAGE
		IndFlags = TDI_RECEIVE_COPY_LOOKAHEAD | TDI_RECEIVE_NORMAL |
			TDI_RECEIVE_AT_DISPATCH_LEVEL |
			((RcvFlags & TCP_FLAG_PUSH) >>
				((TCP_FLAG_PUSH / TDI_RECEIVE_ENTIRE_MESSAGE) - 1));
#else
		IndFlags = TDI_RECEIVE_COPY_LOOKAHEAD | TDI_RECEIVE_NORMAL |
			TDI_RECEIVE_AT_DISPATCH_LEVEL |
			((RcvFlags & TCP_FLAG_PUSH) <<
				((TDI_RECEIVE_ENTIRE_MESSAGE / TCP_FLAG_PUSH) - 1));
#endif
		
        Status = (*Event)(EventContext, ConnContext,
            IndFlags, InBuffer->ipr_size, Size, &BytesTaken,
            InBuffer->ipr_buffer, &ERB);

		IF_TCPDBG(TCP_DEBUG_RECEIVE) {
            TCPTRACE(("%lu bytes taken, status %lx\n", BytesTaken, Status));
        }

#ifndef	VXD
        CTEGetLockAtDPC(&RcvTCB->tcb_lock, NULL);
#endif

        RcvTCB->tcb_flags &= ~IN_RCV_IND;

        // See what the client did. If the return status is MORE_PROCESSING,
        // we've been given a buffer. In that case put it on the front of the
        // buffer queue, and if all the data wasn't taken go ahead and copy
        // it into the new buffer chain.
        //
        // Note that the size and buffer chain we're concerned with here is
        // the one that we passed to the client. Since we're in a rcv. handler,
        // any data that has come in would have been put on the reassembly
        // queue.
        if (Status == TDI_MORE_PROCESSING) {

#ifdef NT
            {
            PTDI_REQUEST_KERNEL_RECEIVE    RequestInformation;
        	PIO_STACK_LOCATION             IrpSp;


		    IF_TCPDBG(TCP_DEBUG_RECEIVE) {
                TCPTRACE(("more processing on receive\n"));
            }

            CTEAssert(ERB != NULL);

        	IrpSp = IoGetCurrentIrpStackLocation(ERB);

	        Status = TCPPrepareIrpForCancel(
			             (PTCP_CONTEXT) IrpSp->FileObject->FsContext,
						 ERB,
						 TCPCancelRequest
						 );

            if (!NT_SUCCESS(Status)) {
				ERB = NULL;
				Status = TDI_NOT_ACCEPTED;
				goto IrpCancelled;
            }

            RequestInformation = (PTDI_REQUEST_KERNEL_RECEIVE)
        	                     &(IrpSp->Parameters);

            CTEAssert(RcvTCB->tcb_rcvhndlr == IndicateData);
            RcvReq->trr_rtn = TCPDataRequestComplete;
            RcvReq->trr_context = ERB;
            RcvReq->trr_buffer = ERB->MdlAddress;
            RcvReq->trr_size =   RequestInformation->ReceiveLength;
            RcvReq->trr_uflags = (ushort *)
			                      &(RequestInformation->ReceiveFlags);
            RcvReq->trr_flags = (uint)(RequestInformation->ReceiveFlags);
            RcvReq->trr_offset = 0;
            RcvReq->trr_amt = 0;
            }

#else  // NT

            CTEAssert(RcvTCB->tcb_rcvhndlr == IndicateData);
            RcvReq->trr_rtn = ERB.erb_rtn;
            RcvReq->trr_context = ERB.erb_context;
            RcvReq->trr_buffer = ERB.erb_buffer;
            RcvReq->trr_size = ERB.erb_size;
            RcvReq->trr_uflags = ERB.erb_flags;
			CTEAssert(ERB.erb_flags != NULL);
            RcvReq->trr_flags = (uint)(*ERB.erb_flags);
            RcvReq->trr_offset = 0;
            RcvReq->trr_amt = 0;
#endif // NT

            // Push him on the front of the rcv. queue.
            CTEAssert((RcvTCB->tcb_currcv == NULL) ||
                (RcvTCB->tcb_currcv->trr_amt == 0));

            if (RcvTCB->tcb_rcvhead == NULL) {
                RcvTCB->tcb_rcvhead = RcvReq;
                RcvTCB->tcb_rcvtail = RcvReq;
                RcvReq->trr_next = NULL;
            } else {
                RcvReq->trr_next = RcvTCB->tcb_rcvhead;
                RcvTCB->tcb_rcvhead = RcvReq;
            }

            RcvTCB->tcb_currcv = RcvReq;
            RcvTCB->tcb_rcvhndlr = BufferData;

            CTEAssert(BytesTaken <= Size);

            RcvTCB->tcb_indicated -= BytesTaken;
            if ((Size -= BytesTaken) != 0) {

                // Not everything was taken. Adjust the buffer chain to point
                // beyond what was taken.
                InBuffer = FreePartialRB(InBuffer, BytesTaken);

                CTEAssert(InBuffer != NULL);

                // We've adjusted the buffer chain. Call the BufferData
                // handler.
                BytesTaken += BufferData(RcvTCB, RcvFlags, InBuffer, Size);

            } else  {
                // All of the data was taken. Free the buffer chain.
                FreeRBChain(InBuffer);
            }

            return BytesTaken;

        }

#ifdef NT

IrpCancelled:

        CTEAssert(ERB == NULL);

#endif // NT

        // Status is not more processing. If it's not SUCCESS, the client
        // didn't take any of the data. In either case we now need to
        // see if all of the data was taken. If it wasn't, we'll try and
        // push it onto the front of the pending queue.

        FreeRcvReq(RcvReq);             // This won't be needed.
        if (Status == TDI_NOT_ACCEPTED)
            BytesTaken = 0;

        CTEAssert(BytesTaken <= Size);

        RcvTCB->tcb_indicated -= BytesTaken;

        CTEAssert(RcvTCB->tcb_rcvhndlr == IndicateData);

        // Check to see if a rcv. buffer got posted during the indication.
        // If it did, reset the recv. handler now.
        if (RcvTCB->tcb_rcvhead != NULL)
            RcvTCB->tcb_rcvhndlr = BufferData;


        // See if all of the data was taken.
        if (BytesTaken == Size) {
            CTEAssert(RcvTCB->tcb_indicated == 0);

            FreeRBChain(InBuffer);
            return BytesTaken;          // It was all taken.
        }

        // It wasn't all taken. Adjust for what was taken, and push
        // on the front of the pending queue. We also need to check to
        // see if a receive buffer got posted during the indication. This
        // would be weird, but not impossible.
        InBuffer = FreePartialRB(InBuffer, BytesTaken);
        if (RcvTCB->tcb_rcvhead == NULL) {
            IPRcvBuf        *LastBuf;

            RcvTCB->tcb_rcvhndlr = PendData;
            NewBuf = CopyRBChain(InBuffer, &LastBuf, Size - BytesTaken);
            if (NewBuf != NULL) {
                // We have a duplicate chain. Push it on the front of the
                // pending q.
                if (RcvTCB->tcb_pendhead == NULL) {
                    RcvTCB->tcb_pendhead = NewBuf;
                    RcvTCB->tcb_pendtail = LastBuf;
                } else {
                    LastBuf->ipr_next = RcvTCB->tcb_pendhead;
                    RcvTCB->tcb_pendhead = NewBuf;
                }
                RcvTCB->tcb_pendingcnt += Size - BytesTaken;
                BytesTaken = Size;
            } else {
                FreeRBChain(InBuffer);
            }

            return BytesTaken;
        } else {
            // Just great. There's now a rcv. buffer on the TCB. Call the
            // BufferData handler now.
            CTEAssert(RcvTCB->tcb_rcvhndlr = BufferData);

            BytesTaken += BufferData(RcvTCB, RcvFlags, InBuffer,
                Size - BytesTaken);

            return BytesTaken;
        }



    } else {
        // Couldn't get a recv. request. We must be really low on resources,
        // so just bail out now.
        FreeRBChain(InBuffer);
        return 0;
    }

}


//* IndicatePendingData - Indicate pending data to a client.
//
//  Called when we need to indicate pending data to an upper layer client,
//  usually because data arrived when we were in a state that it couldn't
//  be indicated.
//
//  Many of the comments in the BufferData header about the consistency of
//  tcb_pendingcnt apply here also.
//
//  Input:  RcvTCB              - TCB on which to indicate the data.
//          RcvReq              - Rcv. req. to use to indicate it.
//
//  Returns: Nothing.
//
void
#ifdef VXD
IndicatePendingData(TCB *RcvTCB, TCPRcvReq *RcvReq)
#else
IndicatePendingData(TCB *RcvTCB, TCPRcvReq *RcvReq, CTELockHandle TCBHandle)
#endif
{

    TDI_STATUS      Status;
    PRcvEvent       Event;
    PVOID           EventContext, ConnContext;
    uint            BytesTaken = 0;
#ifdef NT
    EventRcvBuffer  *ERB = NULL;
#else
    EventRcvBuffer  ERB;
#endif
    IPRcvBuf        *NewBuf;
    uint            Size;

#ifdef VXD
    CTELockHandle   TCBHandle;              // For debug builds.
#endif

    CTEStructAssert(RcvTCB, tcb);

    CTEAssert(RcvTCB->tcb_refcnt != 0);
    CTEAssert(RcvTCB->tcb_rcvind != NULL);
    CTEAssert(RcvTCB->tcb_rcvhead == NULL);
    CTEAssert(RcvTCB->tcb_pendingcnt != 0);
    CTEAssert(RcvReq != NULL);

#ifdef VXD
    CTEGetLock(&RcvTCB->tcb_lock, &TCBHandle);
#endif

    for (;;) {
        CTEAssert(RcvTCB->tcb_rcvhndlr == PendData);

        // The indicate handler is saved in the TCB. Just call up into it.
        Event = RcvTCB->tcb_rcvind;
        EventContext = RcvTCB->tcb_ricontext;
        ConnContext = RcvTCB->tcb_conncontext;
        RcvTCB->tcb_indicated = RcvTCB->tcb_pendingcnt;
        RcvTCB->tcb_flags |= IN_RCV_IND;

        CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);

		IF_TCPDBG(TCPDebug & TCP_DEBUG_RECEIVE) {
            TCPTRACE((
			    "Indicating pending %d bytes, %d available\n",
                RcvTCB->tcb_pendhead->ipr_size, RcvTCB->tcb_pendingcnt
	            ));
        }

        Status = (*Event)(EventContext, ConnContext,
            TDI_RECEIVE_COPY_LOOKAHEAD | TDI_RECEIVE_NORMAL |
            TDI_RECEIVE_ENTIRE_MESSAGE,
            RcvTCB->tcb_pendhead->ipr_size, RcvTCB->tcb_pendingcnt,
            &BytesTaken, RcvTCB->tcb_pendhead->ipr_buffer, &ERB);

		IF_TCPDBG(TCPDebug & TCP_DEBUG_RECEIVE) {
            TCPTRACE(("%d bytes taken\n", BytesTaken));
        }

        CTEGetLock(&RcvTCB->tcb_lock, &TCBHandle);
        RcvTCB->tcb_flags &= ~IN_RCV_IND;

        // See what the client did. If the return status is MORE_PROCESSING,
        // we've been given a buffer. In that case put it on the front of the
        // buffer queue, and if all the data wasn't taken go ahead and copy
        // it into the new buffer chain.
        if (Status == TDI_MORE_PROCESSING) {

#ifdef NT

            {
            PTDI_REQUEST_KERNEL_RECEIVE    RequestInformation;
        	PIO_STACK_LOCATION             IrpSp;


    		IF_TCPDBG(TCP_DEBUG_RECEIVE) {
                TCPTRACE(("more processing on receive\n"));
            }

            CTEAssert(ERB != NULL);

        	IrpSp = IoGetCurrentIrpStackLocation(ERB);

	        Status = TCPPrepareIrpForCancel(
			             (PTCP_CONTEXT) IrpSp->FileObject->FsContext,
						 ERB,
						 TCPCancelRequest
						 );

            if (!NT_SUCCESS(Status)) {
				ERB = NULL;
				Status = TDI_NOT_ACCEPTED;
				goto IrpCancelled2;
            }

            RequestInformation = (PTDI_REQUEST_KERNEL_RECEIVE)
        	                     &(IrpSp->Parameters);

            RcvReq->trr_rtn = TCPDataRequestComplete;
            RcvReq->trr_context = ERB;
            RcvReq->trr_buffer = ERB->MdlAddress;
            RcvReq->trr_size =   RequestInformation->ReceiveLength;
            RcvReq->trr_uflags = (ushort *)
			                      &(RequestInformation->ReceiveFlags);
            RcvReq->trr_flags = (uint)(RequestInformation->ReceiveFlags);
            RcvReq->trr_offset = 0;
            RcvReq->trr_amt = 0;
            }

#else // NT

            RcvReq->trr_rtn = ERB.erb_rtn;
            RcvReq->trr_context = ERB.erb_context;
            RcvReq->trr_buffer = ERB.erb_buffer;
            RcvReq->trr_size = ERB.erb_size;
            RcvReq->trr_uflags = ERB.erb_flags;
            RcvReq->trr_flags = (uint)(*ERB.erb_flags);
            RcvReq->trr_offset = 0;
            RcvReq->trr_amt = 0;

#endif // NT

            // Push him on the front of the rcv. queue.
            CTEAssert((RcvTCB->tcb_currcv == NULL) ||
                (RcvTCB->tcb_currcv->trr_amt == 0));

            if (RcvTCB->tcb_rcvhead == NULL) {
                RcvTCB->tcb_rcvhead = RcvReq;
                RcvTCB->tcb_rcvtail = RcvReq;
                RcvReq->trr_next = NULL;
            } else {
                RcvReq->trr_next = RcvTCB->tcb_rcvhead;
                RcvTCB->tcb_rcvhead = RcvReq;
            }

            RcvTCB->tcb_currcv = RcvReq;
            RcvTCB->tcb_rcvhndlr = BufferData;

            // Have to pick up the new size and pointers now, since things could
            // have changed during the upcall.
            Size = RcvTCB->tcb_pendingcnt;
            NewBuf = RcvTCB->tcb_pendhead;

            RcvTCB->tcb_pendingcnt = 0;
            RcvTCB->tcb_pendhead = NULL;

            CTEAssert(BytesTaken <= Size);

            RcvTCB->tcb_indicated -= BytesTaken;
            if ((Size -= BytesTaken) != 0) {

                // Not everything was taken. Adjust the buffer chain to point
                // beyond what was taken.
                NewBuf = FreePartialRB(NewBuf, BytesTaken);

                CTEAssert(NewBuf != NULL);

                // We've adjusted the buffer chain. Call the BufferData
                // handler.
#ifdef VXD
                CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);
                (void)BufferData(RcvTCB, TCP_FLAG_PUSH, NewBuf, Size);
#else
                (void)BufferData(RcvTCB, TCP_FLAG_PUSH, NewBuf, Size);
                CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);
#endif

            } else  {
                // All of the data was taken. Free the buffer chain. Since
                // we were passed a buffer chain which we put on the head of
                // the list, leave the rcvhandler pointing at BufferData.
                CTEAssert(RcvTCB->tcb_rcvhndlr == BufferData);
                CTEAssert(RcvTCB->tcb_indicated == 0);
                CTEAssert(RcvTCB->tcb_rcvhead != NULL);

                CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);
                FreeRBChain(NewBuf);
            }
            return;

        }

        // Status is not more processing. If it's not SUCCESS, the client
        // didn't take any of the data. In either case we now need to
        // see if all of the data was taken. If it wasn't, we're done.

#ifdef NT

IrpCancelled2:

        CTEAssert(ERB == NULL);

#endif // NT

        if (Status == TDI_NOT_ACCEPTED)
            BytesTaken = 0;

        CTEAssert(RcvTCB->tcb_rcvhndlr == PendData);

        RcvTCB->tcb_indicated -= BytesTaken;
        Size = RcvTCB->tcb_pendingcnt;
        NewBuf = RcvTCB->tcb_pendhead;

        CTEAssert(BytesTaken <= Size);

        // See if all of the data was taken.
        if (BytesTaken == Size) {
            // It was all taken. Zap the pending data information.
            RcvTCB->tcb_pendingcnt = 0;
            RcvTCB->tcb_pendhead = NULL;

            CTEAssert(RcvTCB->tcb_indicated == 0);
            if (RcvTCB->tcb_rcvhead == NULL) {
                if (RcvTCB->tcb_rcvind != NULL)
                    RcvTCB->tcb_rcvhndlr = IndicateData;
            } else
                RcvTCB->tcb_rcvhndlr = BufferData;

            CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);
            FreeRBChain(NewBuf);
            break;
        }

        // It wasn't all taken. Adjust for what was taken, We also need to check
        // to see if a receive buffer got posted during the indication. This
        // would be weird, but not impossible.
        NewBuf = FreePartialRB(NewBuf, BytesTaken);

        CTEAssert(RcvTCB->tcb_rcvhndlr == PendData);

        if (RcvTCB->tcb_rcvhead == NULL) {
            RcvTCB->tcb_pendhead = NewBuf;
            RcvTCB->tcb_pendingcnt -= BytesTaken;
            if (RcvTCB->tcb_indicated != 0 || RcvTCB->tcb_rcvind == NULL) {
                CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);
                break;
            }

            // From here, we'll loop around and indicate the new data that
            // presumably came in during the previous indication.
        } else {
            // Just great. There's now a rcv. buffer on the TCB. Call the
            // BufferData handler now.
            RcvTCB->tcb_rcvhndlr = BufferData;
            RcvTCB->tcb_pendingcnt = 0;
            RcvTCB->tcb_pendhead = NULL;
#ifdef VXD
            CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);
            BytesTaken += BufferData(RcvTCB, TCP_FLAG_PUSH, NewBuf,
                Size - BytesTaken);
#else
            BytesTaken += BufferData(RcvTCB, TCP_FLAG_PUSH, NewBuf,
                Size - BytesTaken);
            CTEFreeLock(&RcvTCB->tcb_lock, TCBHandle);
#endif
            break;
        }

    } // for (;;)

    FreeRcvReq(RcvReq);             // This isn't needed anymore.

}



//* PushData - Push all data back to the client.
//
//  Called when we've received a FIN and need to push data to the client.
//
//  Input:  PushTCB         - TCB to be pushed.
//
//  Returns: Nothing.
//
void
PushData(TCB *PushTCB)
{
    TCPRcvReq       *RcvReq;

    CTEStructAssert(PushTCB, tcb);

    RcvReq = PushTCB->tcb_rcvhead;
    while (RcvReq != NULL) {
        CTEStructAssert(RcvReq, trr);
        RcvReq->trr_flags |= TRR_PUSHED;
        RcvReq = RcvReq->trr_next;
    }

    if (PushTCB->tcb_rcvhead != NULL)
        DelayAction(PushTCB, NEED_RCV_CMPLT);

}



//* SplitRcvBuf - Split an IPRcvBuf into three pieces.
//
//  This function takes an input IPRcvBuf and splits it into three pieces.
//  The first piece is the input buffer, which we just skip over. The second
//  and third pieces are actually copied, even if we already own them, so
//  that the may go to different places.
//
//  Input:  RcvBuf          - RcvBuf chain to be split.
//          Size            - Total size in bytes of rcvbuf chain.
//          Offset          - Offset to skip over.
//          SecondSize      - Size in bytes of second piece.
//          SecondBuf       - Where to return second buffer pointer.
//          ThirdBuf        - Where to return third buffer pointer.
//
//  Returns: Nothing. *SecondBuf and *ThirdBuf are set to NULL if we can't
//      get memory for them.
//
void
SplitRcvBuf(IPRcvBuf *RcvBuf, uint Size, uint Offset, uint SecondSize,
    IPRcvBuf **SecondBuf, IPRcvBuf **ThirdBuf)
{
    IPRcvBuf        *TempBuf;
    uint            ThirdSize;

    CTEAssert(Offset < Size);
    CTEAssert(((Offset + SecondSize) < Size) || (((Offset + SecondSize) == Size)
    	&& ThirdBuf == NULL));

    CTEAssert(RcvBuf != NULL);

    // RcvBuf points at the buffer to copy from, and Offset is the offset into
    // this buffer to copy from.
    if (SecondBuf != NULL) {
        // We need to allocate memory for a second buffer.
        TempBuf = CTEAllocMem(sizeof(IPRcvBuf) + SecondSize);
        if (TempBuf != NULL) {
            TempBuf->ipr_size = SecondSize;
            TempBuf->ipr_owner = IPR_OWNER_TCP;
            TempBuf->ipr_buffer = (uchar *)(TempBuf + 1);
			TempBuf->ipr_next = NULL;
            CopyRcvToBuffer(TempBuf->ipr_buffer, RcvBuf, SecondSize, Offset);
            *SecondBuf = TempBuf;
        } else {
            *SecondBuf = NULL;
            if (ThirdBuf != NULL)
                *ThirdBuf = NULL;
            return;
        }
    }

    if (ThirdBuf != NULL) {
        // We need to allocate memory for a third buffer.
        ThirdSize = Size - (Offset + SecondSize);
        TempBuf = CTEAllocMem(sizeof(IPRcvBuf) + ThirdSize);

        if (TempBuf != NULL) {
            TempBuf->ipr_size = ThirdSize;
            TempBuf->ipr_owner = IPR_OWNER_TCP;
            TempBuf->ipr_buffer = (uchar *)(TempBuf + 1);
			TempBuf->ipr_next = NULL;
            CopyRcvToBuffer(TempBuf->ipr_buffer, RcvBuf, ThirdSize,
                Offset + SecondSize);
            *ThirdBuf = TempBuf;
        } else
            *ThirdBuf = NULL;
    }


}


//* TdiReceive - Process a receive request.
//
//  This is the main TDI receive request handler. We validate the connection
//  and make sure that we have a TCB in the proper state, then we try to
//  allocate a receive request structure. If that succeeds, we'll look and
//  see what's happening on the TCB - if there's pending data, we'll put it
//  in the buffer. Otherwise we'll just queue the receive for later.
//
//  Input:  Request             - TDI_REQUEST structure for this request.
//          Flags               - Pointer to flags word.
//          RcvLength           - Pointer to length in bytes of receive buffer.
//          Buffer              - Pointer to buffer to take data.
//
//  Returns: TDI_STATUS of request.
//
TDI_STATUS
TdiReceive(PTDI_REQUEST Request, ushort *Flags, uint *RcvLength,
    PNDIS_BUFFER Buffer)
{
    TCPConn         *Conn;
    TCB             *RcvTCB;
    TCPRcvReq       *RcvReq;
    CTELockHandle   ConnTableHandle, TCBHandle;
    TDI_STATUS      Error;
    ushort          UFlags;

    CTEGetLock(&ConnTableLock, &ConnTableHandle);

    Conn = GetConnFromConnID((uint)Request->Handle.ConnectionContext);

    if (Conn != NULL) {
        CTEStructAssert(Conn, tc);

        RcvTCB = Conn->tc_tcb;
        if (RcvTCB != NULL) {
            CTEStructAssert(RcvTCB, tcb);
            CTEGetLock(&RcvTCB->tcb_lock, &TCBHandle);
            CTEFreeLock(&ConnTableLock, TCBHandle);
            UFlags = *Flags;

            if ((DATA_RCV_STATE(RcvTCB->tcb_state)  ||
                (RcvTCB->tcb_pendingcnt != 0 && (UFlags & TDI_RECEIVE_NORMAL)))
                && !CLOSING(RcvTCB)) {
                // We have a TCB, and it's valid. Get a receive request now.

                CheckRBList(RcvTCB->tcb_pendhead, RcvTCB->tcb_pendingcnt);

                RcvReq = GetRcvReq();
                if (RcvReq != NULL) {

                    RcvReq->trr_rtn = Request->RequestNotifyObject;
                    RcvReq->trr_context = Request->RequestContext;
                    RcvReq->trr_buffer = Buffer;
                    RcvReq->trr_size = *RcvLength;
                    RcvReq->trr_uflags = Flags;
                    RcvReq->trr_offset = 0;
                    RcvReq->trr_amt = 0;
                    RcvReq->trr_flags = (uint)UFlags;
                    // Put the receive request on the normal receive queue.
                    RcvReq->trr_next = NULL;
                    if (RcvTCB->tcb_rcvhead == NULL) {
                        // The receive queue is empty. Put him on the front.
                        RcvTCB->tcb_rcvhead = RcvReq;
                        RcvTCB->tcb_rcvtail = RcvReq;
                    } else {
                        RcvTCB->tcb_rcvtail->trr_next = RcvReq;
                        RcvTCB->tcb_rcvtail = RcvReq;
                    }

                    // If tcb_currcv is NULL, there is no currently
                    // active receive. In this case, check to see if
                    // there is pending data and that we are not
                    // currently in a receive indication handler. If
                    // both of these are true then deal with the
                    // pending data.
                    if (RcvTCB->tcb_currcv == NULL) {
								RcvTCB->tcb_currcv = RcvReq;
								// No currently active receive.
								if (!(RcvTCB->tcb_flags & IN_RCV_IND)) {
									// Not in a rcv. indication.
									RcvTCB->tcb_rcvhndlr = BufferData;
									if (RcvTCB->tcb_pendhead == NULL) {
										CTEFreeLock(&RcvTCB->tcb_lock,
											ConnTableHandle);
										return TDI_PENDING;
									} else {
										IPRcvBuf        *PendBuffer;
										uint 			PendSize;
										uint			OldRcvWin;
										
										// We have pending data to deal with.
										PendBuffer = RcvTCB->tcb_pendhead;
										PendSize = RcvTCB->tcb_pendingcnt;
										RcvTCB->tcb_pendhead = NULL;
										RcvTCB->tcb_pendingcnt = 0;
										RcvTCB->tcb_refcnt++;
										
										// We assume that BufferData holds
										// the lock (does not yield) during
										// this call. If this changes for some
										// reason, we'll have to fix the code
										// below that does the window update
										// check. See the comments in the
										// BufferData() routine for more info.
#ifdef VXD
										CTEFreeLock(&RcvTCB->tcb_lock,
											ConnTableHandle);
										(void)BufferData(RcvTCB, TCP_FLAG_PUSH,
											PendBuffer, PendSize);
										CTEGetLock(&RcvTCB->tcb_lock,
											&ConnTableHandle);
#else
										(void)BufferData(RcvTCB, TCP_FLAG_PUSH,
											PendBuffer, PendSize);
#endif
										CheckTCBRcv(RcvTCB);
										// Now we need to see if the window
										// has changed. If it has, send an
										// ACK.
										OldRcvWin = RcvTCB->tcb_rcvwin;
										if (OldRcvWin != RcvWin(RcvTCB)) {
											// The window has changed, so send
											// an ACK.
											
 											DelayAction(RcvTCB, NEED_ACK);
										}
										
										DerefTCB(RcvTCB, ConnTableHandle);
										ProcessTCBDelayQ();
										return TDI_PENDING;
									}
								}
								// In a receive indication. The recv. request
								// is now on the queue, so just fall through
								// to the return.

                            }
                            // A rcv. is currently active. No need to do
                            // anything else.
                        CTEFreeLock(&RcvTCB->tcb_lock, ConnTableHandle);
                        return TDI_PENDING;
                } else {
                    // Couldn't get a rcv. req.
                    Error = TDI_NO_RESOURCES;
                }
            } else {
                // The TCB is in an invalid state.
                Error =  TDI_INVALID_STATE;
            }
            CTEFreeLock(&RcvTCB->tcb_lock, ConnTableHandle);
            return Error;
        } else              // No TCB for connection.
            Error = TDI_INVALID_STATE;
    } else          // No connection.
        Error = TDI_INVALID_CONNECTION;

    CTEFreeLock(&ConnTableLock, ConnTableHandle);
    return Error;

}
