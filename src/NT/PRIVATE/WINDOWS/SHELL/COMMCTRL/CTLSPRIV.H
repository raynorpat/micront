#define STRICT

/* disable "non-standard extension" warnings in our code
 */
#ifndef RC_INVOKED
#pragma warning(disable:4001)
#endif

#ifdef WIN32
#define _INC_OLE
#define CONST_VTABLE
#endif

#include <windows.h>
#include <windowsx.h>
#include <ole2.h>               // to get IStream for image.c
#include <commctrl.h>
#include <port32.h>
#include <winerror.h>
#include <daytona.h>

#include "mem.h"
#include "rcids.h"
#include "cstrings.h"

//
// This is a very important piece of performance hack for non-DBCS codepage.
//
#ifndef DBCS
// NB - These are already macros in Win32 land.
#ifdef WIN32
#undef AnsiNext
#undef AnsiPrev
#endif

#define AnsiNext(x) ((x)+1)
#define AnsiPrev(y,x) ((x)-1)
#define IsDBCSLeadByte(x) ((x), FALSE)
#else
#include <imm.h>
#endif // DBCS

#define CH_PREFIX '&'

void FAR PASCAL InitGlobalMetrics(WPARAM);
void FAR PASCAL InitGlobalColors();

BOOL FAR PASCAL InitToolbarClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitToolTipsClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitStatusClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitHeaderClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitButtonListBoxClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitTrackBar(HINSTANCE hInstance);
BOOL FAR PASCAL InitUpDownClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitProgressClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitHotKeyClass(HINSTANCE hInstance);
BOOL FAR PASCAL InitToolTips(HINSTANCE hInstance);


/* cutils.c */
BOOL FAR PASCAL CheckForDragBegin(HWND hwnd, int x, int y);

void FAR PASCAL NewSize(HWND hWnd, int nHeight, LONG style, int left, int top, int width, int height);
BOOL FAR PASCAL MGetTextExtent(HDC hdc, LPCSTR lpstr, int cnt, int FAR * pcx, int FAR * pcy);
void FAR PASCAL RelayToToolTips(HWND hwndToolTips, HWND hWnd, UINT wMsg, WPARAM wParam, LPARAM lParam);
BOOL FAR PASCAL IncrementSearchString(UINT ch, LPSTR FAR *lplpstr);
void FAR PASCAL StripAccelerators(LPSTR lpszFrom, LPSTR lpszTo);
//
// Global variables
//
// Retail debug NOPs.  These files call DebugMsg/AssertMsg/Assert with the
// DM_* severity levels, but the NT 3.5 debug header that defined them isn't
// present in the leak, so they were resolving as implicit (unlinkable)
// functions.  Under the retail build (DBG=0) they are no-ops; the ternary
// dead-branch keeps the arguments type-checked without evaluating them, and
// works for any argument count.
#define DM_TRACE            0x0001
#define DM_WARNING          0x0002
#define DM_ERROR            0x0004
#define DM_ASSERT           0x0008
// DebugMsg/AssertMsg always carry a level + message, so the object-like
// ternary (which absorbs the trailing argument list as a cast) is safe.
#define DebugMsg            1 ? (void)0 : (void)
#define AssertMsg           1 ? (void)0 : (void)
// Assert takes a single condition that can expand to nothing in retail (e.g.
// Assert(IsDSA(p)) where IsDSA is a DEBUG-only macro), so it must be a
// function-like macro that swallows its argument.
#define Assert(x)

// DrawTextEx + its DT_* ellipsis flags are NT4-era user32 additions the tab
// control uses; they exist in our user32 (DrawTextExA/W are exported) but not
// in the NT 3.5 public winuser.h.  Declared here to keep that core header
// untouched.
#define DT_EDITCONTROL      0x00002000
#define DT_PATH_ELLIPSIS    0x00004000
#define DT_END_ELLIPSIS     0x00008000
#define DT_MODIFYSTRING     0x00010000
#define DT_RTLREADING       0x00020000

// NT4-era extended window styles used by the controls (absent from the
// NT 3.5 public winuser.h).
#define WS_EX_CLIENTEDGE    0x00000200L
#define WS_EX_TOOLWINDOW    0x00000800L

// WM_SETTINGCHANGE is the NT4 rename of WM_WININICHANGE.
#define WM_SETTINGCHANGE    WM_WININICHANGE
// WM_HELP (F1 / context help) is an NT4 addition absent from Daytona winuser.h.
#define WM_HELP             0x0053
#define WM_SETICON          0x0080
#define WM_CONTEXTMENU      0x007B
#define WM_DEVICECHANGE     0x0219
#define DM_REPOSITION       (WM_USER+2)	// dialog reposition (with DM_GET/SETDEFID)

// Property-sheet internal limits + the one context-help ID it references from
// the (absent) help.h.  The help ID only maps IDD_APPLYNOW to a help topic;
// a placeholder is harmless since context help isn't wired up.
#define MAXPROPPAGES        100
#define IDH_COMM_APPLYNOW   28450
#define HELP_CONTEXTMENU    0x000a
#define HELP_WM_HELP        0x000c

// HELPINFO — WM_HELP lParam payload (NT4 winuser addition).
#define HELPINFO_WINDOW     0x0001
#define HELPINFO_MENUITEM   0x0002
typedef struct tagHELPINFO {
    UINT    cbSize;
    int     iContextType;
    int     iCtrlId;
    HANDLE  hItemHandle;
    DWORD   dwContextId;
    POINT   MousePos;
} HELPINFO, FAR *LPHELPINFO;

// LoadImage / DrawIconEx constants (NT4 user32 additions) used by image.c.
#define IMAGE_BITMAP        0
#define IMAGE_ICON          1
#define IMAGE_CURSOR        2
#define LR_DEFAULTCOLOR     0x0000
#define LR_MONOCHROME       0x0001
#define LR_COPYRETURNORG    0x0004
#define LR_COPYDELETEORG    0x0008
#define LR_LOADFROMFILE     0x0010
#define DI_MASK             0x0001
#define DI_IMAGE            0x0002
#define DI_NORMAL           0x0003
#define DI_COMPAT           0x0004
#define DI_DEFAULTSIZE      0x0008

typedef struct tagDRAWTEXTPARAMS
{
    UINT    cbSize;
    int     iTabLength;
    int     iLeftMargin;
    int     iRightMargin;
    UINT    uiLengthDrawn;
} DRAWTEXTPARAMS, FAR *LPDRAWTEXTPARAMS;

int WINAPI DrawTextExA(HDC, LPSTR, int, LPRECT, UINT, LPDRAWTEXTPARAMS);
int WINAPI DrawTextExW(HDC, LPWSTR, int, LPRECT, UINT, LPDRAWTEXTPARAMS);
#ifdef UNICODE
#define DrawTextEx  DrawTextExW
#else
#define DrawTextEx  DrawTextExA
#endif

// LoadImage (NT4 user32 addition) — user32 exports LoadImageA/W but the NT 3.5
// winuser.h neither declares it nor provides the A/W macro.
HANDLE WINAPI LoadImageA(HINSTANCE, LPCSTR, UINT, int, int, UINT);
HANDLE WINAPI LoadImageW(HINSTANCE, LPCWSTR, UINT, int, int, UINT);
#ifdef UNICODE
#define LoadImage   LoadImageW
#else
#define LoadImage   LoadImageA
#endif

// treeview.c calls StrNCmpI, which is just the alternate spelling of the
// StrCmpNI implemented in strings.c (same signature).
int FAR PASCAL StrCmpNI(LPCSTR lpStr1, LPCSTR lpStr2, int nChar);
#define StrNCmpI  StrCmpNI

// hash.c defines the HASHTABLE struct + PHASHTABLE typedef locally; forward-
// declare the pointer type here so commctrl.c can reference g_pHashTable.
typedef struct _HashTable FAR *PHASHTABLE;

// Private MRU (most-recently-used list) API implemented by mru.c and exported
// @Internal from comctl32.  The public commctrl.h never carried these, so the
// definitions the implementation compiles against are reconstructed here.
#define MRU_BINARY          0x0001      // items are binary blobs, not strings
#define MRU_CACHEWRITE      0x0002      // defer the registry write-back

typedef int (CALLBACK *MRUCMPPROC)(LPCSTR, LPCSTR);
typedef int (CALLBACK *MRUCMPDATAPROC)(const void FAR *, const void FAR *, UINT);

typedef struct _MRUINFO {
    UINT        fFlags;
    UINT        uMax;
    HKEY        hKey;
    LPCSTR      lpszSubKey;
    LPVOID      lpfnCompare;
} MRUINFO, FAR *LPMRUINFO;

HANDLE WINAPI CreateMRUList(LPMRUINFO lpmi);
void   WINAPI FreeMRUList(HANDLE hMRU);
int    WINAPI AddMRUString(HANDLE hMRU, LPCSTR szString);
int    WINAPI AddMRUData(HANDLE hMRU, const void FAR *lpData, UINT cbData);
int    WINAPI EnumMRUList(HANDLE hMRU, int nItem, LPVOID lpData, UINT uLen);
int    WINAPI FindMRUString(HANDLE hMRU, LPCSTR szString, LPINT lpiSlot);
int    WINAPI FindMRUData(HANDLE hMRU, const void FAR *lpData, UINT cbData, LPINT lpiSlot);

extern HINSTANCE g_hinst;
extern UINT uDragListMsg;
extern int g_iIncrSearchFailed;

// Globals from toolbar.c (Ugly!)
extern const int g_dxButtonSep;
extern int g_nSelectedBM;
extern HDC g_hdcGlyphs;
extern HDC g_hdcMono;
extern HBITMAP g_hbmMono;


#define HINST_THISDLL	g_hinst

#ifdef WIN32

void Controls_EnterCriticalSection(void);
void Controls_LeaveCriticalSection(void);

#define ENTERCRITICAL   Controls_EnterCriticalSection();
#define LEAVECRITICAL   Controls_LeaveCriticalSection();

#else // WIN32
#define ENTERCRITICAL
#define LEAVECRITICAL
#endif // WIN32

// REVIEW, should this be a function? (inline may generate a lot of code)
#define CBBITMAPBITS(cx, cy, cPlanes, cBitsPerPixel)    \
        (((((cx) * (cBitsPerPixel) + 15) & ~15) >> 3)   \
        * (cPlanes) * (cy))

#define WIDTHBYTES(cx, cBitsPerPixel)   \
        ((((cx) * (cBitsPerPixel) + 31) / 32) * 4)


#define ARRAYSIZE(a)    (sizeof(a)/sizeof(a[0]))                          /* ;Internal */

extern HBRUSH g_hbrMonoDither;              // gray dither brush from image.c
void FAR PASCAL InitDitherBrush();
void FAR PASCAL TerminateDitherBrush();



#define SHDT_DRAWTEXT       0x0001
#define SHDT_ELLIPSES       0x0002
#define SHDT_CLIPPED        0x0004
#define SHDT_SELECTED       0x0008
#define SHDT_DESELECTED     0x0010
#define SHDT_DEPRESSED      0x0020
#define SHDT_EXTRAMARGIN    0x0040
#define SHDT_TRANSPARENT    0x0080

void WINAPI SHDrawText(HDC hdc, LPCSTR pszText, RECT FAR* prc,
        int fmt, UINT flags, int cyChar, int cxEllipses,
        COLORREF clrText, COLORREF clrTextBk);




// Global System metrics.

extern int g_cxEdge;
extern int g_cyEdge;
extern int g_cxBorder;
extern int g_cyBorder;
extern int g_cxScreen;
extern int g_cyScreen;
//extern int g_cxSmIcon;
//extern int g_cySmIcon;
//extern int g_cxIcon;
//extern int g_cyIcon;
extern int g_cxFrame;
extern int g_cyFrame;
extern int g_cxIconSpacing, g_cyIconSpacing;
extern int g_cxScrollbar, g_cyScrollbar;
extern int g_cxIconMargin, g_cyIconMargin;
extern int g_cyLabelSpace;
extern int g_cxLabelMargin;
//extern int g_cxIconOffset, g_cyIconOffset;
extern int g_cxVScroll;
extern int g_cyHScroll;
extern int g_cxHScroll;
extern int g_cyVScroll;
//extern int g_xWorkArea;
//extern int g_yWorkArea;

extern COLORREF g_clrWindow;
extern COLORREF g_clrWindowText;
extern COLORREF g_clrWindowFrame;
extern COLORREF g_clrGrayText;
extern COLORREF g_clrBtnText;
extern COLORREF g_clrBtnFace;
extern COLORREF g_clrBtnShadow;
extern COLORREF g_clrBtnHighlight;
extern COLORREF g_clrHighlight;
extern COLORREF g_clrHighlightText;

extern HBRUSH g_hbrGrayText;
extern HBRUSH g_hbrWindow;
extern HBRUSH g_hbrWindowText;
extern HBRUSH g_hbrWindowFrame;
extern HBRUSH g_hbrBtnFace;
extern HBRUSH g_hbrBtnHighlight;
extern HBRUSH g_hbrBtnShadow;
extern HBRUSH g_hbrHighlight;

#ifdef WIN31

extern HBRUSH g_hbr3DDkShadow;
extern HBRUSH g_hbr3DFace;
extern HBRUSH g_hbr3DHilight;
extern HBRUSH g_hbr3DLight;
extern HBRUSH g_hbr3DShadow;
extern HBRUSH g_hbrBtnText;
extern HBRUSH g_hbrWhite;
extern HBRUSH g_hbrGray;
extern HBRUSH g_hbrBlack;

extern int g_oemInfo_Planes;
extern int g_oemInfo_BitsPixel;
extern int g_oemInfo_BitCount;

#define CXEDGE          g_cxEdge
#define CXBORDER        g_cxBorder
#define CYBORDER        g_cyBorder

#define RGB_3DFACE      g_clrBtnFace
#define RGB_3DHILIGHT   g_clrBtnHighlight
#define RGB_3DDKSHADOW  RGB(  0,   0,   0)
#define RGB_3DLIGHT     RGB(223, 223, 223)
#define RGB_WINDOWFRAME g_clrWindowFrame
#define RGB_3DSHADOW    g_clrBtnShadow

#define HBR_3DDKSHADOW  g_hbr3DDkShadow
#define HBR_3DFACE      g_hbr3DFace
#define HBR_3DHILIGHT   g_hbr3DHilight
#define HBR_3DLIGHT     g_hbr3DLight
#define HBR_3DSHADOW    g_hbr3DShadow
#define HBR_WINDOW      g_hbrWindow
#define HBR_WINDOWFRAME g_hbrWindowFrame
#define HBR_BTNTEXT     g_hbrBtnText
#define HBR_WINDOWTEXT  g_hbrWindowText
#define HBR_GRAYTEXT    g_hbrGrayText
#define hbrGray         g_hbrGray
#define hbrWhite        g_hbrWhite
#define hbrBlack        g_hbrBlack


BOOL API DrawFrameControl(HDC hdc, LPRECT lprc, UINT wType, UINT wState);
void FAR DrawPushButton(HDC hdc, LPRECT lprc, UINT state, UINT flags);


#endif

extern HFONT g_hfontSystem;

//
// Defining FULL_DEBUG makes us debug memory problems.
//
#if defined(FULL_DEBUG) && defined(WIN32)
#include <deballoc.h>
#endif // defined(FULL_DEBUG) && defined(WIN32)
