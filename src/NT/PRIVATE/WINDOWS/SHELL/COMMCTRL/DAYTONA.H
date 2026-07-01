//
// This define turns off the unresolved functions in
// the source code.
//

#define CHICAGO              0


//
// These two defines are not in Cairo's winuser.h, and their
// ID values are being used.
//


//
// The Chicago/NT4 dialog styles below are absent from Daytona's public
// winuser.h.  Their bits are unused in the NT 3.5 DS_* space, so define them
// to the real Win32 values.  DS_RECURSE aliases DS_CONTROL, so DS_CONTROL
// must come first.
//

#define DS_3DLOOK            0x0004L
#define DS_CONTROL           0x0400L
#define DS_CONTEXTHELP       0x2000L

// SS_SUNKEN (the NT4-era sunken-static style) is likewise absent from
// Daytona's winuser.h; property-sheet dialogs use it for divider lines.
#define SS_SUNKEN            0x00001000L

#define DS_RECURSE           DS_CONTROL
#define LR_COPYFROMRESOURCE  LR_COPYDELETEORG

//
// IDHELP (the standard Help-button ID, 9) is another NT4-era winuser.h
// addition missing from Daytona; the property-sheet Help button uses it.
//

#define IDHELP               9



//
// Daytona does not have a SetObjectOwner api.  This
// is necessary in Chicago because their global variables
// are in a shared data area (among all processes).  So
// they use this api to set the data to a particular DLL/process
//

#define SetObjectOwner(x,y)


//
// Chicago uses the ReinitializeCriticalSection api which Daytona
// doesn't have.  ChrisG was going to look into this some more.
//

#define ReinitializeCriticalSection(x) InitializeCriticalSection(x)
