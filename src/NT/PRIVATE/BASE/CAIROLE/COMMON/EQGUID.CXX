
#include  <windows.h>
#include  <ole2.h>
#include  <stdlib.h>

//+-------------------------------------------------------------------------
//
//  Function:	IsEqualGUID  (public)
//
//  Synopsis:	compares two guids for equality
//
//  Arguments:	[guid1]	- the first guid
//		[guid2] - the second guid to compare the first one with
//
//  Returns:	TRUE if equal, FALSE if not.
//
//--------------------------------------------------------------------------

// Signature matches objbase.h's STDAPI_(BOOL) IsEqualGUID(REFGUID, REFGUID)
// declaration (REFGUID == const GUID&); the original GUID& form gave a
// second-C-linkage overload error against the public prototype.
extern "C" BOOL  __stdcall IsEqualGUID(REFGUID guid1, REFGUID guid2)
{
    return !memcmp((void *)&guid1,(void *)&guid2,sizeof(GUID));
}
