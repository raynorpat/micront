/*****************************************************************************\
*                                                                             *
* prsht.h -  Property sheet definitions                                       *
*                                                                             *
*  Reconstructed for MicroNT: the NT 3.5 leak ships the property-sheet        *
*  implementation (SHELL/COMMCTRL/prsht.c + the private prshtp.h) but not     *
*  the public <prsht.h> it compiles against.  This header supplies the        *
*  public API the implementation and its consumers expect: the PROPSHEETPAGE  *
*  / PROPSHEETHEADER structures, the PSP_/PSH_/PSN_/PSM_/PSNRET_ constants,    *
*  and the three exported entry points.  Values follow the canonical Win32    *
*  layout; a few version-specific notifications used only internally by this  *
*  comctl32 are assigned consistent values in the PSN_ range.                 *
*                                                                             *
\*****************************************************************************/

#ifndef _PRSHT_H_
#define _PRSHT_H_

#ifdef __cplusplus
extern "C" {
#endif

// Opaque property-sheet-page handle.  The private prshtp.h completes
// struct _PSP and re-typedefs this to the same pointer type.
struct _PSP;
typedef struct _PSP FAR *HPROPSHEETPAGE;

typedef UINT (CALLBACK *LPFNPSPCALLBACK)(HWND, UINT, struct _PROPSHEETPAGE FAR *);
typedef int  (CALLBACK *PFNPROPSHEETCALLBACK)(HWND, UINT, LPARAM);
typedef BOOL (CALLBACK *LPFNADDPROPSHEETPAGE)(HPROPSHEETPAGE, LPARAM);
typedef BOOL (CALLBACK *LPFNADDPROPSHEETPAGES)(LPVOID, LPFNADDPROPSHEETPAGE, LPARAM);

//
// Property-sheet-page flags (PROPSHEETPAGE.dwFlags)
//
#define PSP_DEFAULT             0x00000000
#define PSP_DLGINDIRECT         0x00000001
#define PSP_USEHICON            0x00000002
#define PSP_USEICONID           0x00000004
#define PSP_USETITLE            0x00000008
#define PSP_RTLREADING          0x00000010
#define PSP_HASHELP             0x00000020
#define PSP_USEREFPARENT        0x00000040
#define PSP_USERELEASEFUNC      0x00000080

#define PSP_ALL                 0x000000FF

typedef struct _PROPSHEETPAGE {
    DWORD               dwSize;
    DWORD               dwFlags;
    HINSTANCE           hInstance;
    union {
        LPCTSTR             pszTemplate;
        LPCDLGTEMPLATE      pResource;
    };
    union {
        HICON               hIcon;
        LPCTSTR             pszIcon;
    };
    LPCTSTR             pszTitle;
    DLGPROC             pfnDlgProc;
    LPARAM              lParam;
    LPFNPSPCALLBACK     pfnCallback;
    // Called on page destroy when PSP_USERELEASEFUNC is set (this comctl32).
    void (CALLBACK *    pfnRelease)(struct _PROPSHEETPAGE FAR *);
    UINT FAR *          pcRefParent;
} PROPSHEETPAGE, FAR *LPPROPSHEETPAGE;

typedef const PROPSHEETPAGE FAR *LPCPROPSHEETPAGE;

//
// Property-sheet-header flags (PROPSHEETHEADER.dwFlags)
//
#define PSH_DEFAULT             0x00000000
#define PSH_PROPTITLE           0x00000001
#define PSH_USEHICON            0x00000002
#define PSH_USEICONID           0x00000004
#define PSH_PROPSHEETPAGE       0x00000008
#define PSH_WIZARDHASFINISH     0x00000010
#define PSH_WIZARD              0x00000020
#define PSH_USEPSTARTPAGE       0x00000040
#define PSH_NOAPPLYNOW          0x00000080
#define PSH_USECALLBACK         0x00000100
#define PSH_HASHELP             0x00000200
#define PSH_MODELESS            0x00000400
#define PSH_RTLREADING          0x00000800

#define PSH_ALL                 0x00000FFF

typedef struct _PROPSHEETHEADER {
    DWORD               dwSize;
    DWORD               dwFlags;
    HWND                hwndParent;
    HINSTANCE           hInstance;
    union {
        HICON               hIcon;
        LPCTSTR             pszIcon;
    };
    LPCTSTR             pszCaption;
    UINT                nPages;
    union {
        UINT                nStartPage;
        LPCTSTR             pStartPage;
    };
    union {
        LPCPROPSHEETPAGE    ppsp;
        HPROPSHEETPAGE FAR *phpage;
    };
    PFNPROPSHEETCALLBACK pfnCallback;
} PROPSHEETHEADER, FAR *LPPROPSHEETHEADER;

typedef const PROPSHEETHEADER FAR *LPCPROPSHEETHEADER;

//
// PropertySheet messages (sent to the sheet frame; PSM_FIRST = WM_USER+100)
//
#define PSM_FIRST               (WM_USER + 100)

#define PSM_SETCURSEL           (PSM_FIRST + 1)
#define PSM_REMOVEPAGE          (PSM_FIRST + 2)
#define PSM_ADDPAGE             (PSM_FIRST + 3)
#define PSM_CHANGED             (PSM_FIRST + 4)
#define PSM_RESTARTWINDOWS      (PSM_FIRST + 5)
#define PSM_REBOOTSYSTEM        (PSM_FIRST + 6)
#define PSM_CANCELTOCLOSE       (PSM_FIRST + 7)
#define PSM_QUERYSIBLINGS       (PSM_FIRST + 8)
#define PSM_UNCHANGED           (PSM_FIRST + 9)
#define PSM_APPLY               (PSM_FIRST + 10)
#define PSM_SETTITLE            (PSM_FIRST + 11)
#define PSM_SETWIZBUTTONS       (PSM_FIRST + 12)
#define PSM_PRESSBUTTON         (PSM_FIRST + 13)
#define PSM_SETCURSELID         (PSM_FIRST + 14)

//
// Wizard button flags for PSM_SETWIZBUTTONS
//
#define PSWIZB_BACK             0x00000001
#define PSWIZB_NEXT             0x00000002
#define PSWIZB_FINISH           0x00000004
#define PSWIZB_DISABLEDFINISH   0x00000008

//
// Push-button indices (PSM_PRESSBUTTON)
//
#define PSBTN_BACK              0
#define PSBTN_NEXT              1
#define PSBTN_FINISH            2
#define PSBTN_OK                3
#define PSBTN_APPLYNOW          4
#define PSBTN_CANCEL            5
#define PSBTN_HELP              6
#define PSBTN_MAX               6

//
// PropertySheet notifications (WM_NOTIFY code; PSN_FIRST = -200)
//
#define PSN_FIRST               (0U-200U)
#define PSN_LAST                (0U-299U)

#define PSN_SETACTIVE           (PSN_FIRST-0)
#define PSN_KILLACTIVE          (PSN_FIRST-1)
#define PSN_APPLY               (PSN_FIRST-2)
#define PSN_RESET               (PSN_FIRST-3)
#define PSN_HELP                (PSN_FIRST-5)
#define PSN_WIZBACK             (PSN_FIRST-6)
#define PSN_WIZNEXT             (PSN_FIRST-7)
#define PSN_WIZFINISH           (PSN_FIRST-8)
#define PSN_QUERYCANCEL         (PSN_FIRST-9)
// Version-specific internal notifications (this comctl32 only).
#define PSN_CHANGED             (PSN_FIRST-10)
#define PSN_CANCELTOCLOSE       (PSN_FIRST-11)
#define PSN_HASHELP             (PSN_FIRST-12)
#define PSN_INVALID_NOCHANGEPAGE (PSN_FIRST-13)
#define PSN_REBOOTSYSTEM        (PSN_FIRST-14)
#define PSN_RESTARTWINDOWS      (PSN_FIRST-15)

//
// PSN_APPLY / PSN_KILLACTIVE result codes (DWL_MSGRESULT)
//
#define PSNRET_NOERROR              0
#define PSNRET_INVALID              1
#define PSNRET_INVALID_NOCHANGEPAGE 2

//
// PropertySheet() return values requesting a restart / reboot
//
#define ID_PSRESTARTWINDOWS         0x2
#define ID_PSREBOOTSYSTEM           0x3

//
// Private PROPSHEETPAGE.dwFlags bit marking a 16-bit proxy page (internal to
// comctl32; kept above the public PSP_* bits so it never collides).
//
#define PSP_IS16                    0x00010000

//
// Exported entry points
//
int             WINAPI PropertySheet(LPCPROPSHEETHEADER lppsph);
HPROPSHEETPAGE  WINAPI CreatePropertySheetPage(LPCPROPSHEETPAGE lppsp);
BOOL            WINAPI DestroyPropertySheetPage(HPROPSHEETPAGE hpsp);

#ifdef __cplusplus
}
#endif

#endif  // _PRSHT_H_
