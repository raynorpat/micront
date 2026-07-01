
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

// objbase.h defines IsEqualGUID as a macro alias for the InlineIsEqualGUID
// inline; drop the macro so this compiles to the real exported stdcall
// symbol (IsEqualGUID@8, ordinal 38 in COMPOB32.DEF). REFGUID == const GUID&.
#undef IsEqualGUID
extern "C" BOOL  __stdcall IsEqualGUID(REFGUID guid1, REFGUID guid2)
{
    return !memcmp((void *)&guid1,(void *)&guid2,sizeof(GUID));
}
