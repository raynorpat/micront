-- ws2_32 — Winsock-2 DLL conformance, driven straight through the DLL's own
-- exports (not nt.net.afd) -- the path a real Win32 program (Rust std, etc.)
-- takes. Covers the synchronous hot path Rust uses:
--   * single-socket surface: WSAStartup, socket, bind, getsockname, getsockopt,
--     getpeername, listen, closesocket
--   * a blocking TCP connect/accept/send/recv/shutdown round-trip across two
--     threads (nt.thread), the exact shape std::net drives
--   * a single-threaded non-blocking connect + select() readiness walk
--   * a UDP sendto/recvfrom round-trip
--   * the implemented socket-option matrix, including TCP_NODELAY
--   * real error paths (EADDRINUSE / ECONNREFUSED / EFAULT)
-- Loopback-only, no network dependency. Only implemented behaviour is asserted;
-- unimplemented options/flags are deliberately left untested so nothing locks in
-- a stub.
--
-- Loading ws2_32 pulls in kernel32, exercising its NLS client init in a
-- NATIVE-subsystem process. A SOCKET is a real NT handle whose per-socket state
-- lives in the kernel (AFD), so it is valid in any thread / fresh lua_State --
-- which is what lets the worker thread operate on a parent-created listener by
-- its integer value.

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

typedef struct {                 /* winsock fd_set: count-prefixed array */
    unsigned int fd_count;
    SOCKET       fd_array[64];    /* FD_SETSIZE */
} fd_set;

struct timeval { long tv_sec; long tv_usec; };

/* All Winsock entry points are PASCAL / WINAPI == __stdcall on x86. */
int            __stdcall WSAStartup(unsigned short wVersionRequested, void *lpWSAData);
int            __stdcall WSACleanup(void);
SOCKET         __stdcall socket(int af, int type, int protocol);
int            __stdcall bind(SOCKET s, const void *name, int namelen);
int            __stdcall listen(SOCKET s, int backlog);
SOCKET         __stdcall accept(SOCKET s, void *addr, int *addrlen);
int            __stdcall connect(SOCKET s, const void *name, int namelen);
int            __stdcall send(SOCKET s, const char *buf, int len, int flags);
int            __stdcall recv(SOCKET s, char *buf, int len, int flags);
int            __stdcall sendto(SOCKET s, const char *buf, int len, int flags, const void *to, int tolen);
int            __stdcall recvfrom(SOCKET s, char *buf, int len, int flags, void *from, int *fromlen);
int            __stdcall shutdown(SOCKET s, int how);
int            __stdcall closesocket(SOCKET s);
int            __stdcall getsockname(SOCKET s, void *name, int *namelen);
int            __stdcall getpeername(SOCKET s, void *name, int *namelen);
int            __stdcall getsockopt(SOCKET s, int level, int optname, char *optval, int *optlen);
int            __stdcall setsockopt(SOCKET s, int level, int optname, const char *optval, int optlen);
int            __stdcall ioctlsocket(SOCKET s, long cmd, unsigned long *argp);
int            __stdcall select(int nfds, fd_set *readfds, fd_set *writefds, fd_set *exceptfds, const struct timeval *timeout);
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
local SO_REUSEADDR   = 0x0004
local SO_KEEPALIVE   = 0x0008
local SO_LINGER      = 0x0080
local SO_SNDBUF      = 0x1001
local SO_RCVBUF      = 0x1002
local SO_TYPE        = 0x1008
local TCP_NODELAY    = 0x0001
local SD_RECEIVE     = 0
local SD_SEND        = 1
local FIONBIO        = 0x8004667e   -- _IOW('f', 126, u_long)
local FIONREAD       = 0x4004667f   -- _IOR('f', 127, u_long)
local WSAEFAULT      = 10014
local WSAEWOULDBLOCK = 10035
local WSAEADDRINUSE  = 10048
local WSAENOTCONN    = 10057
local WSAECONNREFUSED= 10061
local SIN_LEN        = ffi.sizeof('sockaddr_in') -- 16
local INT_LEN        = ffi.sizeof('int')

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

-- setsockopt/getsockopt over a single int value.
local function set_int_opt(s, level, name, val)
    local v = ffi.new('int[1]', val)
    return ws2.setsockopt(s, level, name, ffi.cast('char*', v), INT_LEN)
end

local function get_int_opt(s, level, name)
    local v   = ffi.new('int[1]', 0)
    local len = ffi.new('int[1]', INT_LEN)
    t.eq(ws2.getsockopt(s, level, name, ffi.cast('char*', v), len), 0)
    return tonumber(v[0])
end

-- Drain a stream socket to EOF (peer close) and return everything read.
local function recv_all(s)
    local buf   = ffi.new('char[256]')
    local parts = {}
    while true do
        local n = ws2.recv(s, buf, 256, 0)
        if n <= 0 then break end
        parts[#parts+1] = ffi.string(buf, n)
    end
    return table.concat(parts)
end

-- fd_set helpers (winsock fd_set is a count-prefixed array, not a bitmask).
local function fd_zero(set) set.fd_count = 0 end
local function fd_add(set, s)
    set.fd_array[tonumber(set.fd_count)] = s
    set.fd_count = set.fd_count + 1
end
local function fd_isset(set, s)
    local target = tonumber(ffi.cast('intptr_t', s))
    for i = 0, tonumber(set.fd_count) - 1 do
        if tonumber(ffi.cast('intptr_t', set.fd_array[i])) == target then return true end
    end
    return false
end

-- select() one direction with a timeout; returns the rewritten fd_set + count.
local function select_one(s, dir, secs)
    local set = ffi.new('fd_set'); fd_zero(set); fd_add(set, s)
    local tv  = ffi.new('struct timeval'); tv.tv_sec = secs; tv.tv_usec = 0
    local r, w
    if dir == "read"  then r = set end
    if dir == "write" then w = set end
    local n = ws2.select(0, r, w, nil, tv)             -- nfds ignored on Windows
    return n, set
end

-- The server side of the blocking round-trip, run in its own lua_State. It
-- receives the listener SOCKET (a real NT handle) as PAYLOAD, accepts one
-- connection, echoes "pong:" + the request, then closes. Result is a string.
local TCP_SERVER_WORKER = [==[
local ffi = require('ffi')
ffi.cdef[[
typedef uintptr_t SOCKET;
int    __stdcall WSAStartup(unsigned short, void *);
SOCKET __stdcall accept(SOCKET, void *, int *);
int    __stdcall recv(SOCKET, char *, int, int);
int    __stdcall send(SOCKET, const char *, int, int);
int    __stdcall closesocket(SOCKET);
int    __stdcall WSAGetLastError(void);
]]
local ws2 = ffi.load('ws2_32')
local wsadata = ffi.new('char[512]')
ws2.WSAStartup(0x0202, wsadata)

local listener = ffi.cast('SOCKET', tonumber(PAYLOAD))
local peer = ws2.accept(listener, nil, nil)
if tonumber(ffi.cast('intptr_t', peer)) == -1 then
    return "accept-failed:" .. tostring(ws2.WSAGetLastError())
end

local buf   = ffi.new('char[64]')
local parts = {}
while true do
    local n = ws2.recv(peer, buf, 64, 0)
    if n <= 0 then break end          -- 0 on the client's shutdown(SD_SEND)
    parts[#parts+1] = ffi.string(buf, n)
end
local request = table.concat(parts)
local reply   = "pong:" .. request
ws2.send(peer, reply, #reply, 0)
ws2.closesocket(peer)
return "ok:" .. request
]==]

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

t.test("TCP connect/accept/data round-trip + shutdown (blocking, threaded)", function()
    local thread = require('nt.thread')

    local listener = open_socket(SOCK_STREAM, IPPROTO_TCP)
    local port     = try_bind(listener, "127.0.0.1", 0)
    t.eq(ws2.listen(listener, 5), 0)

    -- Hand the listener (an NT handle) to the server thread by integer value.
    local th = thread.run(TCP_SERVER_WORKER,
                          tostring(tonumber(ffi.cast('intptr_t', listener))))
    t.defer(function() th:close() end)

    local client = open_socket(SOCK_STREAM, IPPROTO_TCP)

    -- TCP_NODELAY set BEFORE connect -> exercises buffer-and-apply-at-connect.
    t.eq(set_int_opt(client, IPPROTO_TCP, TCP_NODELAY, 1), 0)

    t.eq(ws2.connect(client, make_sin("127.0.0.1", port), SIN_LEN), 0)

    -- Still on after connect (cached), and a post-connect change pushes to the
    -- live connection immediately.
    t.ok(get_int_opt(client, IPPROTO_TCP, TCP_NODELAY) ~= 0, "nodelay on after connect")
    t.eq(set_int_opt(client, IPPROTO_TCP, TCP_NODELAY, 0), 0)
    t.eq(get_int_opt(client, IPPROTO_TCP, TCP_NODELAY), 0)

    -- getpeername (client side) is the listener's address.
    local sin = ffi.new('sockaddr_in')
    local len = ffi.new('int[1]', SIN_LEN)
    t.eq(ws2.getpeername(client, sin, len), 0)
    t.eq(ws2.ntohs(sin.sin_port), port)

    t.eq(ws2.send(client, "ping-12345", 10, 0), 10)
    t.eq(ws2.shutdown(client, SD_SEND), 0)

    -- The server only returns after it has sent the reply and closed, so by the
    -- time the join completes the reply is buffered -- the recv below can't hang.
    t.ok(th:wait(3.0), "server thread completed within 3s")
    local status, val = th:result()
    t.eq(status, "ok")
    t.eq(val, "ok:ping-12345")

    t.eq(recv_all(client), "pong:ping-12345")
end)

t.test("non-blocking connect + select() readiness walk", function()
    local listener = open_socket(SOCK_STREAM, IPPROTO_TCP)
    local port     = try_bind(listener, "127.0.0.1", 0)
    t.eq(ws2.listen(listener, 5), 0)

    local client = open_socket(SOCK_STREAM, IPPROTO_TCP)
    local nb = ffi.new('unsigned long[1]', 1)
    t.eq(ws2.ioctlsocket(client, FIONBIO, nb), 0)            -- non-blocking

    -- Non-blocking connect returns immediately, in progress.
    t.eq(ws2.connect(client, make_sin("127.0.0.1", port), SIN_LEN), SOCKET_ERROR)
    t.eq(ws2.WSAGetLastError(), WSAEWOULDBLOCK)

    -- Listener becomes readable when the connection arrives.
    local nr, rset = select_one(listener, "read", 3)
    t.ok(nr >= 1 and fd_isset(rset, listener), "listener readable (accept pending)")

    local peer = ws2.accept(listener, nil, nil)
    t.ok(peer ~= INVALID_SOCKET, "accept succeeds after select")
    t.defer(function() ws2.closesocket(peer) end)

    -- Client becomes writable when the connect completes.
    local nw, wset = select_one(client, "write", 3)
    t.ok(nw >= 1 and fd_isset(wset, client), "client writable (connected)")

    -- Data path: send, observe peer readability, FIONREAD count, then recv.
    t.eq(ws2.send(client, "sel", 3, 0), 3)
    local nr2, rset2 = select_one(peer, "read", 3)
    t.ok(nr2 >= 1 and fd_isset(rset2, peer), "peer readable after send")

    local navail = ffi.new('unsigned long[1]', 0)
    t.eq(ws2.ioctlsocket(peer, FIONREAD, navail), 0)
    t.ok(tonumber(navail[0]) >= 3, "FIONREAD reports the pending bytes")

    local buf = ffi.new('char[8]')
    t.eq(ws2.recv(peer, buf, 8, 0), 3)
    t.eq(ffi.string(buf, 3), "sel")
end)

t.test("UDP send_to / recv_from round-trip", function()
    local a = open_socket(SOCK_DGRAM, IPPROTO_UDP)
    local b = open_socket(SOCK_DGRAM, IPPROTO_UDP)
    local pa = try_bind(a, "127.0.0.1", 0)
    local pb = try_bind(b, "127.0.0.1", 0)

    -- Bound the receive with select rather than a blocking recvfrom.
    local nb = ffi.new('unsigned long[1]', 1)
    t.eq(ws2.ioctlsocket(b, FIONBIO, nb), 0)

    t.eq(ws2.sendto(a, "udp-hi", 6, 0, make_sin("127.0.0.1", pb), SIN_LEN), 6)

    local nr, rset = select_one(b, "read", 3)
    t.ok(nr >= 1 and fd_isset(rset, b), "b readable after sendto")

    local from    = ffi.new('sockaddr_in')
    local fromlen = ffi.new('int[1]', SIN_LEN)
    local buf     = ffi.new('char[16]')
    local n = ws2.recvfrom(b, buf, 16, 0, from, fromlen)
    t.eq(n, 6)
    t.eq(ffi.string(buf, 6), "udp-hi")
    t.eq(ws2.ntohs(from.sin_port), pa)                       -- source is a's port
end)

t.test("socket options set/get round-trips (implemented options only)", function()
    local s = open_socket(SOCK_STREAM, IPPROTO_TCP)

    t.eq(set_int_opt(s, SOL_SOCKET, SO_REUSEADDR, 1), 0)
    t.ok(get_int_opt(s, SOL_SOCKET, SO_REUSEADDR) ~= 0, "SO_REUSEADDR reads back set")

    -- Buffer sizes are implementation-defined after a set (the stack may round),
    -- so assert only that the option is accepted and reads back a sane value.
    t.eq(set_int_opt(s, SOL_SOCKET, SO_RCVBUF, 16384), 0)
    t.ok(get_int_opt(s, SOL_SOCKET, SO_RCVBUF) > 0, "SO_RCVBUF reads back > 0")
    t.eq(set_int_opt(s, SOL_SOCKET, SO_SNDBUF, 16384), 0)
    t.ok(get_int_opt(s, SOL_SOCKET, SO_SNDBUF) > 0, "SO_SNDBUF reads back > 0")

    t.eq(set_int_opt(s, SOL_SOCKET, SO_KEEPALIVE, 1), 0)
    t.ok(get_int_opt(s, SOL_SOCKET, SO_KEEPALIVE) ~= 0, "SO_KEEPALIVE reads back set")

    -- TCP_NODELAY on an unconnected socket: buffered on the endpoint, cached for
    -- get; the on/off value must round-trip exactly.
    t.eq(set_int_opt(s, IPPROTO_TCP, TCP_NODELAY, 1), 0)
    t.ok(get_int_opt(s, IPPROTO_TCP, TCP_NODELAY) ~= 0, "TCP_NODELAY reads back on")
    t.eq(set_int_opt(s, IPPROTO_TCP, TCP_NODELAY, 0), 0)
    t.eq(get_int_opt(s, IPPROTO_TCP, TCP_NODELAY), 0)
end)

t.test("double bind to the same port -> WSAEADDRINUSE", function()
    local s1   = open_socket(SOCK_STREAM, IPPROTO_TCP)
    local port = try_bind(s1, "127.0.0.1", 0)
    local s2   = open_socket(SOCK_STREAM, IPPROTO_TCP)
    t.eq(ws2.bind(s2, make_sin("127.0.0.1", port), SIN_LEN), SOCKET_ERROR)
    t.eq(ws2.WSAGetLastError(), WSAEADDRINUSE)
end)

t.test("connect to a closed loopback port -> WSAECONNREFUSED", function()
    -- Reserve then release a port so we have one that is guaranteed free and
    -- has nothing listening on it.
    local probe = ws2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
    t.ok(probe ~= INVALID_SOCKET, "probe socket created")
    t.eq(ws2.bind(probe, make_sin("127.0.0.1", 0), SIN_LEN), 0)
    local sin = ffi.new('sockaddr_in')
    local len = ffi.new('int[1]', SIN_LEN)
    t.eq(ws2.getsockname(probe, sin, len), 0)
    local port = ws2.ntohs(sin.sin_port)
    ws2.closesocket(probe)

    local c = open_socket(SOCK_STREAM, IPPROTO_TCP)
    t.eq(ws2.connect(c, make_sin("127.0.0.1", port), SIN_LEN), SOCKET_ERROR)
    t.eq(ws2.WSAGetLastError(), WSAECONNREFUSED)
end)

t.test("getsockname with a too-small buffer -> WSAEFAULT", function()
    local s = open_socket(SOCK_STREAM, IPPROTO_TCP)
    try_bind(s, "127.0.0.1", 0)
    local sin = ffi.new('sockaddr_in')
    local len = ffi.new('int[1]', 4)                         -- < sizeof(sockaddr_in)
    t.eq(ws2.getsockname(s, sin, len), SOCKET_ERROR)
    t.eq(ws2.WSAGetLastError(), WSAEFAULT)
end)
