-- shell.lua — MicroNT Win32 shell (END-OF-LINE).
--
-- Tagged at this point as the "windows-is-cooked" branch. Read this
-- file as the record of why MicroNT is not going to build on the
-- Win32 personality any further.
--
-- Set in mkhive.py's gui profile as
--   HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon\Shell =
--     "%SystemRoot%\lua\runw.exe %SystemRoot%\lua\shell.lua"
-- (the env-var expansion happens in our patched USERINIT.C::ExecApplication;
-- stock NT 3.5 didn't expand, requiring literal paths).
--
-- What this file does: registers a WNDCLASSW, creates an overlapped
-- top-level window with a child BUTTON, pumps messages in a standard
-- GetMessage/TranslateMessage/DispatchMessage loop. WNDPROC is a Lua
-- function cast via ffi.cast('WNDPROC', fn); user32 LPCs back to our
-- process and calls through the cast for every message. WM_PAINT draws
-- via gdi32 TextOutW, WM_COMMAND handles the button click (increments a
-- counter, updates a paint buffer, InvalidateRect to repaint),
-- WM_DESTROY posts WM_QUIT to break the pump.
--
-- -- Findings from the investigation --------------------------------
--
-- 1. Struct layout is correct. verify_structs() below cross-checks
--    WNDCLASSW / MSG / PAINTSTRUCT / POINT / RECT against NT 3.5's
--    WINUSER.H + WINDEF.H (no #pragma pack anywhere). All sizes and
--    field offsets match.
--
-- 2. LuaJIT cannot safely JIT-compile the WNDPROC code path on NT 3.5.
--    With JIT on, after ~5-17 clicks, a trace-recording attempt on
--    the WNDPROC path aborts with LJ_TRERR_BLACKL (err=5, "black-
--    listed"), and recovery from that abort leaves LuaJIT in a state
--    where subsequent callback invocations either jump through
--    corrupt mcode (observed: eip=0x00000003, eip=0x00000202, both
--    suspiciously low integer values that look like message codes
--    being called as function pointers) or hard-hang the entire
--    system. `jit.off(wndproc, true)` prevents the trace recording
--    attempt from ever starting and makes the callback stable.
--    Interpreter-only in the callback body is fine — user events are
--    human-rate, the JIT earns its keep on other Lua code.
--
-- 3. Preallocating paint_buf once and writing in place (instead of
--    reallocating via str.to_wbuf on every click) roughly doubled the
--    click count before the hang hit (7 → 17). Suggests the original
--    symptom had GC-pressure-reveals-liveness-bug component too, but
--    was not the full story — jit.off was still needed for stability.
--
-- 4. "One bad GUI app hangs the whole console" is expected NT 3.5
--    behaviour, not caused by our bugs. The USER subsystem in csrss
--    dispatches WM_SETCURSOR / WM_NCHITTEST / activation-path
--    messages via synchronous LPC with SendMessage semantics; if the
--    foreground app's message pump doesn't reply, csrss's raw-input
--    thread blocks and cursor drawing stops. Microsoft rewrote this
--    for NT 4.0 (win32k.sys, per-thread input queues, timeouts on
--    cross-thread sends) — that was the headline reliability fix.
--    We inherit all the NT 3.5 fragility.
--
-- 5. The correct factoring for a Win32 wrapper would be: one
--    framework-owned WNDPROC (one ffi.cast, one jit.off) dispatching
--    to user-registered Lua handlers; users never own a callback.
--    This is a real engineering job, not a small one, and at the end
--    of it you still have NT 3.5's synchronous input model and
--    csrss's LPC dance as failure modes you can't design around.
--
-- -- Why we're stopping here ----------------------------------------
--
-- The NT *kernel* is genuinely good — object manager, LPC as a
-- primitive, the dispatcher object model, the IO manager, the
-- scheduler. Win32 on top of it is a museum piece of cooperative-era
-- compromises: synchronous input, CSR_API's capture-buffer protocol,
-- the subsystem split, the Win16 compat layer. Building Lua on top
-- of Win32 means inheriting all of that, for no gain — Lua doesn't
-- need HWNDs or DCs or the BUTTON window class; it can have its own
-- UI primitives written in Lua against the framebuffer + input
-- drivers + ntdll directly.
--
-- Branch plan from here: new branch that strips csrss, winsrv,
-- user32, gdi32, kernel32, shell32, smss, winlogon, userinit. Keep
-- the NT kernel, HAL, ntdll, drivers, registry, object manager. Boot
-- direct from kernel → run.exe → Lua via Control\InitExe (the
-- existing micront profile). UI in pure Lua against the framebuffer
-- and keyboard/mouse class drivers.
--
-- This file stays on the windows-is-cooked branch as reference.

local ffi   = require('ffi')
local ntdll = require('nt.dll')
local str   = require('nt.dll.str')

ffi.cdef[[
void __stdcall DbgPrint(const char *Format, ...);

/* Win32 scalar aliases. HWND and UINT are NT-shared, elsewhere in
   nt/dll/ — the rest live here until a second consumer appears. */
typedef void *               HWND;
typedef void *               HINSTANCE;
typedef void *               HICON;
typedef void *               HCURSOR;
typedef void *               HBRUSH;
typedef void *               HMENU;
typedef void *               HDC;
typedef unsigned int         UINT;
typedef unsigned short       ATOM;
typedef unsigned long        DWORD;
typedef int                  BOOL;
typedef unsigned char        BYTE;
typedef long                 LONG;
typedef long                 LRESULT;
typedef unsigned int         WPARAM;
typedef long                 LPARAM;
typedef LRESULT (__stdcall * WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct tagPOINT { LONG x; LONG y; } POINT;
typedef struct tagRECT  { LONG left; LONG top; LONG right; LONG bottom; } RECT;

typedef struct tagWNDCLASSW {
    UINT            style;
    WNDPROC         lpfnWndProc;
    int             cbClsExtra;
    int             cbWndExtra;
    HINSTANCE       hInstance;
    HICON           hIcon;
    HCURSOR         hCursor;
    HBRUSH          hbrBackground;
    const wchar_t * lpszMenuName;
    const wchar_t * lpszClassName;
} WNDCLASSW;

typedef struct tagMSG {
    HWND   hwnd;
    UINT   message;
    WPARAM wParam;
    LPARAM lParam;
    DWORD  time;
    POINT  pt;
} MSG;

typedef struct tagPAINTSTRUCT {
    HDC  hdc;
    BOOL fErase;
    RECT rcPaint;
    BOOL fRestore;
    BOOL fIncUpdate;
    BYTE rgbReserved[32];
} PAINTSTRUCT;

/* user32 — window class + pump + default proc. */
ATOM    __stdcall RegisterClassW(const WNDCLASSW *);
HWND    __stdcall CreateWindowExW(DWORD dwExStyle,
                                  const wchar_t *lpClassName,
                                  const wchar_t *lpWindowName,
                                  DWORD dwStyle, int X, int Y,
                                  int nWidth, int nHeight,
                                  HWND hWndParent, HMENU hMenu,
                                  HINSTANCE hInstance, void *lpParam);
BOOL    __stdcall ShowWindow(HWND, int nCmdShow);
BOOL    __stdcall UpdateWindow(HWND);
BOOL    __stdcall InvalidateRect(HWND, const RECT *, BOOL);
LRESULT __stdcall DefWindowProcW(HWND, UINT, WPARAM, LPARAM);
BOOL    __stdcall GetMessageW(MSG *, HWND, UINT, UINT);
BOOL    __stdcall TranslateMessage(const MSG *);
LRESULT __stdcall DispatchMessageW(const MSG *);
void    __stdcall PostQuitMessage(int);
HDC     __stdcall BeginPaint(HWND, PAINTSTRUCT *);
BOOL    __stdcall EndPaint(HWND, const PAINTSTRUCT *);

/* gdi32 — just what WM_PAINT needs. */
BOOL    __stdcall TextOutW(HDC, int, int, const wchar_t *, int);

/* kernel32 — hInstance for the class. */
HINSTANCE __stdcall GetModuleHandleW(const wchar_t *);
]]

local user32   = ffi.load('user32')
local gdi32    = ffi.load('gdi32')
local kernel32 = ffi.load('kernel32')

ntdll.DbgPrint("shell.lua: launched\n")

-- (Diagnostic jit.attach instrumentation removed. Findings recorded
-- at the jit.off call below — we proved that trace recording on the
-- WNDPROC path aborts with LJ_TRERR_BLACKL and hangs on recovery.)

-- Verify cdef layout matches NT 3.5's WINUSER.H / WINDEF.H. Headers
-- carry no #pragma pack; all fields are 4-byte scalars or BYTE[32] at
-- the tail, so natural alignment is what user32 compiled against. A
-- mismatch here is the first thing to rule out when crashes smell
-- like "struct field at the wrong offset".
local function verify_structs()
    local expected = {
        POINT       = { size=8,  offsets={x=0, y=4} },
        RECT        = { size=16, offsets={left=0, top=4, right=8, bottom=12} },
        WNDCLASSW   = { size=40, offsets={
            style=0, lpfnWndProc=4, cbClsExtra=8, cbWndExtra=12,
            hInstance=16, hIcon=20, hCursor=24, hbrBackground=28,
            lpszMenuName=32, lpszClassName=36 } },
        MSG         = { size=28, offsets={
            hwnd=0, message=4, wParam=8, lParam=12, time=16, pt=20 } },
        PAINTSTRUCT = { size=64, offsets={
            hdc=0, fErase=4, rcPaint=8, fRestore=24,
            fIncUpdate=28, rgbReserved=32 } },
    }
    local ok = true
    for name, spec in pairs(expected) do
        local actual_size = ffi.sizeof(name)
        if actual_size ~= spec.size then
            ntdll.DbgPrint("shell.lua: SIZE MISMATCH %s: got=%d want=%d\n",
                name, ffi.new('int', actual_size), ffi.new('int', spec.size))
            ok = false
        end
        for field, want_off in pairs(spec.offsets) do
            local got = ffi.offsetof(name, field)
            if got ~= want_off then
                ntdll.DbgPrint(
                    "shell.lua: OFFSET MISMATCH %s.%s: got=%d want=%d\n",
                    name .. "." .. field,
                    ffi.new('int', got), ffi.new('int', want_off))
                ok = false
            end
        end
    end
    ntdll.DbgPrint("shell.lua: struct layout %s\n",
                   ok and "OK (matches WINUSER.H/WINDEF.H)"
                      or "MISMATCH — see entries above")
end
verify_structs()


local bit = require('bit')

-- Window messages + styles we actually use.
local WM_DESTROY          = 0x0002
local WM_PAINT            = 0x000F
local WM_COMMAND          = 0x0111
local WS_OVERLAPPEDWINDOW = 0x00CF0000
local WS_CHILD            = 0x40000000
local WS_VISIBLE          = 0x10000000
local BS_DEFPUSHBUTTON    = 0x00000001
local SW_SHOWDEFAULT      = 10
local CW_USEDEFAULT       = 0x80000000   -- passed to int arg; wraps to INT_MIN
local COLOR_WINDOW        = 5            -- system-brush index
local IDC_CLICK           = 1001         -- our button's control id

local hInstance  = kernel32.GetModuleHandleW(nil)
local class_name = str.to_wbuf("MicroNTShell")
local title      = str.to_wbuf("MicroNT shell — hello from Lua")
local button_cls = str.to_wbuf("BUTTON")     -- predefined user32 class
local button_lbl = str.to_wbuf("Click me")

-- Interactive state. The WNDPROC upvalues close over these; each click
-- bumps click_count, refills paint_buf in place, and invalidates the
-- client area so WM_PAINT redraws with the new string.
--
-- The paint buffer is preallocated once. Earlier code reallocated via
-- str.to_wbuf on every click — 7 clicks + a redraw storm on desktop
-- switch produced a crash that looked like GC reclaiming an in-use
-- cdata during a WNDPROC callback. Writing in place keeps a single
-- cdata reference live for the window's lifetime.
local PAINT_MAX  = 128           -- wchars; status text is short + ASCII
local paint_buf  = ffi.new('wchar_t[?]', PAINT_MAX)
local paint_len  = 0
local click_count = 0

-- ASCII-only write. Our status strings never exceed 7-bit, so each
-- Lua byte maps 1:1 to a wchar. Non-ASCII content would need
-- str.decode_utf8 + surrogate handling.
local function set_paint(s)
    local n = #s
    if n >= PAINT_MAX then n = PAINT_MAX - 1 end
    for i = 1, n do paint_buf[i-1] = s:byte(i) end
    paint_buf[n] = 0
    paint_len = n
end

set_paint("Click the button.")

local function wndproc(hwnd, msg, wparam, lparam)
    if msg == WM_PAINT then
        local ps = ffi.new('PAINTSTRUCT')
        local hdc = user32.BeginPaint(hwnd, ps)
        if hdc ~= nil then
            gdi32.TextOutW(hdc, 20, 60, paint_buf, paint_len)
            user32.EndPaint(hwnd, ps)
        end
        return 0
    elseif msg == WM_COMMAND then
        -- LOWORD(wparam) = control id, HIWORD(wparam) = notification.
        -- BUTTON's BN_CLICKED is 0, so we don't bother checking it.
        if bit.band(tonumber(wparam), 0xFFFF) == IDC_CLICK then
            click_count = click_count + 1
            set_paint(string.format("Button clicks: %d", click_count))
            ntdll.DbgPrint("shell.lua: click #%d\n",
                           ffi.new('int', click_count))
            user32.InvalidateRect(hwnd, nil, 1)
        end
        return 0
    elseif msg == WM_DESTROY then
        user32.PostQuitMessage(0)
        return 0
    end
    return user32.DefWindowProcW(hwnd, msg, wparam, lparam)
end

-- Disable JIT trace recording on this function and every function
-- called from within it. Required on NT 3.5: JIT instrumentation
-- (jit.attach "trace") showed that when LuaJIT attempts to record a
-- trace on the WNDPROC code path it aborts with LJ_TRERR_BLACKL
-- (err_code 5 = "blacklisted") after repeated failed recordings, and
-- recovery from that abort leaves LuaJIT in a state where the next
-- callback invocation either calls through corrupt mcode (observed:
-- eip=0x00000003 / eip=0x00000202 after a desktop-switch message
-- storm) or hard-hangs the system entirely.
--
-- The callback itself is called at user-interaction rates (tens to
-- hundreds per second at most), so the interpreter path is plenty
-- fast; the JIT earns its keep on the rest of the program, which is
-- untouched by this switch.
--
-- When we factor the user32 cdefs into a proper `user32.window`
-- wrapper, this jit.off must move there and apply to the single
-- framework-owned WNDPROC. User-written handlers run outside the
-- callback frame (registered via window:on(msg, fn) and dispatched
-- from the wrapper's WNDPROC) so they remain JIT-eligible.
jit.off(wndproc, true)

-- ffi.cast('WNDPROC', fn) produces a C-callable stdcall trampoline
-- backed by one of LuaJIT's reserved callback slots (pool of ~32).
-- Must be held in a Lua-visible ref for the window's whole lifetime —
-- if it gets GC'd the slot is reclaimed and re-used, and a late
-- DispatchMessageW would call into a dead trampoline.
local wndproc_cb = ffi.cast('WNDPROC', wndproc)

local wc = ffi.new('WNDCLASSW')
wc.style         = 0x0003                  -- CS_HREDRAW | CS_VREDRAW
wc.lpfnWndProc   = wndproc_cb
wc.hInstance     = hInstance
-- Default system background brush. User32 treats (HBRUSH)(COLOR_*+1)
-- as a system-colour sentinel rather than a real handle.
wc.hbrBackground = ffi.cast('HBRUSH', COLOR_WINDOW + 1)
wc.lpszClassName = class_name

local atom = user32.RegisterClassW(wc)
ntdll.DbgPrint("shell.lua: RegisterClassW atom=%d\n", ffi.new('int', atom))
if atom == 0 then
    ntdll.DbgPrint("shell.lua: RegisterClassW failed, bailing\n")
    return
end

local hwnd = user32.CreateWindowExW(
    0, class_name, title,
    WS_OVERLAPPEDWINDOW,
    CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
    nil, nil, hInstance, nil)
ntdll.DbgPrint("shell.lua: CreateWindowExW hwnd=%p\n", hwnd)
if hwnd == nil then
    ntdll.DbgPrint("shell.lua: CreateWindowExW returned NULL, bailing\n")
    return
end

-- Child button. user32's predefined "BUTTON" class handles its own
-- drawing + state; parent receives WM_COMMAND on click. The HMENU slot
-- is reinterpreted as the child's control id when WS_CHILD is set.
local hbutton = user32.CreateWindowExW(
    0, button_cls, button_lbl,
    bit.bor(WS_CHILD, WS_VISIBLE, BS_DEFPUSHBUTTON),
    20, 20, 120, 28,
    hwnd, ffi.cast('HMENU', IDC_CLICK), hInstance, nil)
ntdll.DbgPrint("shell.lua: CreateWindowExW(BUTTON) hwnd=%p\n", hbutton)

user32.ShowWindow(hwnd, SW_SHOWDEFAULT)
user32.UpdateWindow(hwnd)

ntdll.DbgPrint("shell.lua: entering message pump\n")
local msg = ffi.new('MSG')
while user32.GetMessageW(msg, nil, 0, 0) ~= 0 do
    user32.TranslateMessage(msg)
    user32.DispatchMessageW(msg)
end
ntdll.DbgPrint("shell.lua: pump exited, shell returning\n")

-- Pin callback + wbufs past the pump. JIT liveness (NOTES.md) — touch
-- after the loop so the trace can't drop them mid-window-lifetime.
if wndproc_cb and class_name and title and paint_buf
   and button_cls and button_lbl and hbutton then end
