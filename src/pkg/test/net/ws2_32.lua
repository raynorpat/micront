-- ws2_32 — Winsock-2 DLL conformance, driven straight through the DLL's own
-- exports (not nt.net.afd) -- the path a real Win32 program (Rust std, etc.)
-- takes. Covers the synchronous, single-socket surface: WSAStartup, socket,
-- bind, getsockname (local addr), getsockopt, getpeername, listen, closesocket.
-- Loopback-only, no network dependency; the connect/accept/data round trip
-- lives in the multi-threaded netloop.rs Rust test.
--
-- Loading ws2_32 pulls in kernel32, exercising its NLS client init in a
-- NATIVE-subsystem process.

local ffi = require('ffi')
local t   = require('test')

t.suite("ws2_32")

ffi.cdef[[
typedef uintptr_t SOCKET;

typedef struct {
    short          sin_family;
    unsigned short sin_port;     /* network byte order */
    unsigned long  sin_addr;     /* network byte order */
    char           sin_zero[8];
} sockaddr_in;                   /* 16 bytes, naturally aligned */

/* All Winsock entry points are PASCAL / WINAPI == __stdcall on x86. */
int            __stdcall WSAStartup(unsigned short wVersionRequested, void *lpWSAData);
int            __stdcall WSACleanup(void);
SOCKET         __stdcall socket(int af, int type, int protocol);
int            __stdcall bind(SOCKET s, const void *name, int namelen);
int            __stdcall listen(SOCKET s, int backlog);
int            __stdcall closesocket(SOCKET s);
int            __stdcall getsockname(SOCKET s, void *name, int *namelen);
int            __stdcall getpeername(SOCKET s, void *name, int *namelen);
int            __stdcall getsockopt(SOCKET s, int level, int optname, char *optval, int *optlen);
int            __stdcall WSAGetLastError(void);
unsigned short __stdcall htons(unsigned short hostshort);
unsigned short __stdcall ntohs(unsigned short netshort);
unsigned long  __stdcall inet_addr(const char *cp);
]]

local AF_INET        = 2
local SOCK_STREAM    = 1
local SOCK_DGRAM     = 2
local IPPROTO_TCP    = 6
local IPPROTO_UDP    = 17
local SOCKET_ERROR   = -1
local INVALID_SOCKET = ffi.cast('SOCKET', -1)   -- 0xFFFFFFFF on i386
local SOL_SOCKET     = 0xffff
local SO_TYPE        = 0x1008
local WSAENOTCONN    = 10057
local SIN_LEN        = ffi.sizeof('sockaddr_in') -- 16

-- ffi.load triggers LdrLoadDll(ws2_32) -> kernel32 DllMain. A failure there is
-- a hard error (not a Lua error) pcall can't catch; report it as the one
-- failing test rather than wedging the suite.
local ok_load, ws2 = pcall(ffi.load, 'ws2_32')
if not ok_load then
    t.test("ws2_32 DLL loads", function()
        t.ok(false, "ffi.load('ws2_32') failed: " .. tostring(ws2))
    end)
    return
end

-- WSAStartup once for the whole suite; Winsock ref-counts, and process exit
-- unwinds it (no WSACleanup, which would tear it down mid-suite).
local wsadata    = ffi.new('char[512]')          -- WSADATA is ~400B
local startup_rc = ws2.WSAStartup(0x0202, wsadata)

local function make_sin(ip, port)
    local sin = ffi.new('sockaddr_in')
    sin.sin_family = AF_INET
    sin.sin_port   = ws2.htons(port)
    sin.sin_addr   = ws2.inet_addr(ip)
    return sin
end

-- Open a fresh socket (asserting success) and defer its close.
local function open_socket(kind, proto)
    local s = ws2.socket(AF_INET, kind, proto)
    t.ok(s ~= INVALID_SOCKET, "socket() should not be INVALID_SOCKET")
    t.defer(function() if s ~= INVALID_SOCKET then ws2.closesocket(s) end end)
    return s
end

-- Bind, then verify getsockname round-trips the *exact* bound address. This is
-- the regression guard for the TDI get-address buffer-overflow fix: before it,
-- getsockname returned WSAEMSGSIZE (10040). Returns the assigned port.
local function try_bind(s, ip, port)
    t.eq(ws2.bind(s, make_sin(ip, port), SIN_LEN), 0)        -- bind succeeds

    local sin = ffi.new('sockaddr_in')
    local len = ffi.new('int[1]', SIN_LEN)
    t.eq(ws2.getsockname(s, sin, len), 0)                    -- not SOCKET_ERROR/WSAEMSGSIZE
    t.eq(tonumber(len[0]), SIN_LEN)                          -- namelen unchanged at 16
    t.eq(tonumber(sin.sin_family), AF_INET)                  -- family preserved
    t.eq(tonumber(sin.sin_addr), tonumber(ws2.inet_addr(ip)))-- bound IP echoed back
    local assigned = ws2.ntohs(sin.sin_port)
    t.ok(assigned ~= 0, "an ephemeral port was assigned")
    return assigned
end

-- ------------------------------------------------------------------

t.test("WSAStartup(2.2)", function()
    t.eq(startup_rc, 0)
end)

t.test("socket(SOCK_STREAM) creates a TCP socket", function()
    open_socket(SOCK_STREAM, IPPROTO_TCP)
end)

t.test("socket(SOCK_DGRAM) creates a UDP socket", function()
    open_socket(SOCK_DGRAM, IPPROTO_UDP)
end)

t.test("getsockopt SO_TYPE reports the socket type", function()
    local s   = open_socket(SOCK_STREAM, IPPROTO_TCP)
    local opt = ffi.new('int[1]')
    local len = ffi.new('int[1]', 4)
    t.eq(ws2.getsockopt(s, SOL_SOCKET, SO_TYPE, ffi.cast('char*', opt), len), 0)
    t.eq(tonumber(opt[0]), SOCK_STREAM)
end)

t.test("bind+getsockname TCP 0.0.0.0:0 (wildcard)", function()
    try_bind(open_socket(SOCK_STREAM, IPPROTO_TCP), "0.0.0.0", 0)
end)

t.test("bind+getsockname TCP 127.0.0.1:0 (loopback)", function()
    try_bind(open_socket(SOCK_STREAM, IPPROTO_TCP), "127.0.0.1", 0)
end)

t.test("bind+getsockname UDP 127.0.0.1:0 (loopback)", function()
    try_bind(open_socket(SOCK_DGRAM, IPPROTO_UDP), "127.0.0.1", 0)
end)

t.test("getpeername on an unconnected socket -> WSAENOTCONN", function()
    local s   = open_socket(SOCK_STREAM, IPPROTO_TCP)
    local sin = ffi.new('sockaddr_in')
    local len = ffi.new('int[1]', SIN_LEN)
    t.eq(ws2.getpeername(s, sin, len), SOCKET_ERROR)
    t.eq(ws2.WSAGetLastError(), WSAENOTCONN)
end)

t.test("listen after a successful TCP bind", function()
    local s = open_socket(SOCK_STREAM, IPPROTO_TCP)
    try_bind(s, "127.0.0.1", 0)
    t.eq(ws2.listen(s, 5), 0)
end)
