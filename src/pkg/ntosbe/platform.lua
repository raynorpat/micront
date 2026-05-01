-- ntosbe.platform — host-vs-OS abstraction.
--
-- The build environment runs in two places: on the host (LuaJIT built
-- by bootstrap.sh, full lib_io / lib_os, POSIX file I/O) and inside
-- MicroNT (LuaJIT-on-NT, lib_io / lib_os disabled, file I/O via
-- nt.dll.fs).  This module hides the difference so hive.lua, disk.lua,
-- the build orchestrator, and everything in pkg/ntosbe/ don't need to
-- branch on host-vs-OS at every callsite.
--
-- Detection: presence of io.open is the load-bearing signal.  The
-- MicroNT build of LuaJIT excludes lib_io entirely (see bootstrap.sh's
-- LJLIB_O note for why the host build flips it back on).  That gives
-- us a one-liner check that doesn't need any nt.* modules to be
-- importable yet.
--
-- Surface (current — grows as ports need more):
--
--   File I/O
--     read_file(path)           -> bytes | nil
--     write_file(path, bytes)
--     copy_file(src, dst)       -> bool, err
--     file_size(path)           -> bytes | nil
--     file_exists(path)         -> bool
--     is_dir(path)              -> bool
--     is_executable(path)       -> bool
--     mtime(path)               -> unix-timestamp | nil
--
--   Directory ops
--     list_dir(path)            -> array of names (excluding . / ..)
--     list_tree(root)           -> array of root-relative file paths
--     mkdir_p(path)
--     unlink(path)              -> bool
--     rmdir(path)               -> bool
--     rmrf(path)                -> bool
--     realpath(path)            -> resolved abs path | nil
--     getcwd()                  -> abs path
--
--   Time
--     now()                     -> unix-timestamp
--     localtime(t)              -> { year, month, day, hour, min, sec }
--
--   Process env
--     setenv(name, value)
--     getenv(name)              -> value | nil
--     environ()                 -> array of "KEY=VAL" strings
--
--   Process spawn
--     spawn_wait{               -> exit status (128+sig if signaled)
--       argv  = {"prog", ...},      argv[0] is the program (or its name
--                                   for PATH lookup if search_path=true)
--       path  = "/abs/prog",        optional; overrides argv[0] as the
--                                   binary to spawn (argv[0] still goes
--                                   to the child).  Wibo wants this so
--                                   the child sees argv[0]="wibo" but
--                                   we exec WIBO_BIN.
--       env   = {"K=V", ...},       optional; default = inherit current
--       cwd   = "/path",            optional; default = inherit
--       search_path = bool,         optional; posix_spawnp vs posix_spawn
--     }
--
--   Logging
--     log(msg)                  -> stderr (host) / DbgPrint (in-OS)
--     die(msg)                  -> log + exit(1)
--
--   Flags
--     on_host                   -> bool, for callers that need to branch

local ffi = require('ffi')
local bit = require('bit')

local M = {}

local on_host = (type(io) == 'table' and type(io.open) == 'function')
M.on_host = on_host

-- ----------------------------------------------------------------
-- Host backend — POSIX FFI, Linux x86_64.
--
-- Layouts (struct stat, struct dirent) are the modern glibc x86_64
-- versions.  bootstrap.sh builds LuaJIT for the host arch; if we ever
-- support 32-bit hosts the layout block below grows an arch branch.
-- ----------------------------------------------------------------

if on_host then

ffi.cdef[[
typedef struct DIR DIR;

typedef struct {
    int64_t  d_ino;
    int64_t  d_off;
    uint16_t d_reclen;
    uint8_t  d_type;
    char     d_name[256];
} ntosbe_dirent_t;

typedef struct {
    int64_t tv_sec;
    int64_t tv_nsec;
} ntosbe_timespec_t;

typedef struct {
    uint64_t           st_dev;
    uint64_t           st_ino;
    uint64_t           st_nlink;
    uint32_t           st_mode;
    uint32_t           st_uid;
    uint32_t           st_gid;
    int32_t            __pad0;
    uint64_t           st_rdev;
    int64_t            st_size;
    int64_t            st_blksize;
    int64_t            st_blocks;
    ntosbe_timespec_t  st_atim;
    ntosbe_timespec_t  st_mtim;
    ntosbe_timespec_t  st_ctim;
    int64_t            __unused[3];
} ntosbe_stat_t;

DIR             *opendir(const char *name);
ntosbe_dirent_t *readdir(DIR *dirp);
int              closedir(DIR *dirp);

int   stat(const char *path, ntosbe_stat_t *statbuf);
int   lstat(const char *path, ntosbe_stat_t *statbuf);
int   access(const char *pathname, int mode);
int   unlink(const char *pathname);
int   rmdir(const char *pathname);
int   mkdir(const char *pathname, uint32_t mode);

char *getcwd(char *buf, size_t size);
char *realpath(const char *path, char *resolved_path);
int   chdir(const char *path);

int   setenv(const char *name, const char *value, int overwrite);
char *getenv(const char *name);

extern char **environ;

typedef int ntosbe_pid_t;
int posix_spawn(ntosbe_pid_t *pid, const char *path,
                const void *file_actions, const void *attrp,
                char *const argv[], char *const envp[]);
int posix_spawnp(ntosbe_pid_t *pid, const char *file,
                 const void *file_actions, const void *attrp,
                 char *const argv[], char *const envp[]);
ntosbe_pid_t waitpid(ntosbe_pid_t pid, int *wstatus, int options);

int errno;
]]

local C = ffi.C

-- POSIX file mode bits (sys/stat.h on Linux x86_64).
local S_IFMT  = 0xF000
local S_IFDIR = 0x4000
local S_IFREG = 0x8000

-- access(2) modes.
local F_OK = 0
local X_OK = 1

-- DT_* values from <dirent.h>.  DT_UNKNOWN means the FS didn't fill
-- d_type at readdir time — fall back to stat().
local DT_UNKNOWN = 0
local DT_DIR     = 4
local DT_REG     = 8

-- ---------------- Stat helpers ----------------

local stat_buf = ffi.new('ntosbe_stat_t')   -- reused; single-threaded

local function stat_or_nil(path)
    if C.stat(path, stat_buf) ~= 0 then return nil end
    return stat_buf
end

function M.file_exists(path)
    return C.stat(path, stat_buf) == 0
end

function M.is_dir(path)
    if C.stat(path, stat_buf) ~= 0 then return false end
    return bit.band(stat_buf.st_mode, S_IFMT) == S_IFDIR
end

function M.is_executable(path)
    return C.access(path, X_OK) == 0
end

function M.file_size(path)
    if C.stat(path, stat_buf) ~= 0 then return nil end
    return tonumber(stat_buf.st_size)
end

function M.mtime(path)
    if C.stat(path, stat_buf) ~= 0 then return nil end
    return tonumber(stat_buf.st_mtim.tv_sec)
end

-- ---------------- File I/O (host: stdio is fine) ----------------

function M.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

function M.write_file(path, bytes)
    local f, err = io.open(path, "wb")
    if not f then
        error("ntosbe.platform.write_file " .. path .. ": " .. err, 2)
    end
    f:write(bytes)
    f:close()
end

function M.copy_file(src, dst)
    local fin, err = io.open(src, "rb")
    if not fin then return false, "open " .. src .. ": " .. (err or "") end
    local fout
    fout, err = io.open(dst, "wb")
    if not fout then
        fin:close()
        return false, "open " .. dst .. ": " .. (err or "")
    end
    -- Stream in 64 KB chunks so we don't materialise the whole file as a
    -- Lua string for large inputs (NT 3.5 binaries are small, but the
    -- hive + disk pipeline can carry larger blobs).
    while true do
        local chunk = fin:read(64 * 1024)
        if not chunk or #chunk == 0 then break end
        fout:write(chunk)
    end
    fin:close()
    fout:close()
    return true
end

-- ---------------- Directory ops ----------------

function M.list_dir(path)
    local d = C.opendir(path)
    if d == nil then return {} end
    local names = {}
    while true do
        local ent = C.readdir(d)
        if ent == nil then break end
        local name = ffi.string(ent.d_name)
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    C.closedir(d)
    return names
end

-- Recursive walk; returns paths relative to root, files only (directories
-- implicit).  Sorted at each level for deterministic disk-image layouts.
-- Uses dirent.d_type when present; falls back to stat() on filesystems
-- that don't fill it (DT_UNKNOWN).
function M.list_tree(root)
    local out = {}
    local function walk(rel)
        local full = (rel == "") and root or (root .. "/" .. rel)
        local d = C.opendir(full)
        if d == nil then return end

        -- Snapshot dir contents first (name + dir-or-file), then sort
        -- and recurse.  Holding readdir state across recursion could
        -- otherwise interleave; cleaner to drain first.
        local kids = {}
        while true do
            local ent = C.readdir(d)
            if ent == nil then break end
            local name = ffi.string(ent.d_name)
            if name ~= "." and name ~= ".." then
                local is_dir
                if ent.d_type == DT_DIR then
                    is_dir = true
                elseif ent.d_type == DT_REG then
                    is_dir = false
                else
                    -- DT_UNKNOWN, DT_LNK etc. — resolve via stat.
                    local sub_full = full .. "/" .. name
                    is_dir = M.is_dir(sub_full)
                end
                kids[#kids + 1] = { name = name, is_dir = is_dir }
            end
        end
        C.closedir(d)

        table.sort(kids, function(a, b) return a.name < b.name end)
        for _, k in ipairs(kids) do
            local sub = (rel == "") and k.name or (rel .. "/" .. k.name)
            if k.is_dir then
                walk(sub)
            else
                out[#out + 1] = sub
            end
        end
    end
    walk("")
    return out
end

-- mkdir -p in pure FFI: walk components, mkdir(0755) each, ignore
-- errors (a later op will surface a real failure if the path is bogus).
function M.mkdir_p(path)
    local accum
    if path:sub(1, 1) == "/" then
        accum = "/"
        path  = path:sub(2)
    else
        accum = ""
    end
    for component in path:gmatch("[^/]+") do
        accum = accum .. component
        C.mkdir(accum, 0x1ed)        -- 0o755
        accum = accum .. "/"
    end
end

function M.unlink(path)
    return C.unlink(path) == 0
end

function M.rmdir(path)
    return C.rmdir(path) == 0
end

-- Recursive remove.  Walks once, deletes files, then deletes empty dirs
-- post-order.  No `rm -rf` shell-out, no `find`.
function M.rmrf(path)
    if not M.file_exists(path) then return true end
    if not M.is_dir(path) then
        return M.unlink(path)
    end
    -- Post-order: collect dir paths going in, delete files going down,
    -- then rmdir going back up.
    local dirs = {}
    local function walk(p)
        dirs[#dirs + 1] = p
        local d = C.opendir(p)
        if d == nil then return end
        local children = {}
        while true do
            local ent = C.readdir(d)
            if ent == nil then break end
            local name = ffi.string(ent.d_name)
            if name ~= "." and name ~= ".." then
                children[#children + 1] = { name = name, type = ent.d_type }
            end
        end
        C.closedir(d)
        for _, c in ipairs(children) do
            local cp = p .. "/" .. c.name
            local is_dir
            if c.type == DT_DIR then
                is_dir = true
            elseif c.type == DT_REG or c.type == 10 then  -- DT_LNK
                is_dir = false
            else
                is_dir = M.is_dir(cp)
            end
            if is_dir then
                walk(cp)
            else
                C.unlink(cp)
            end
        end
    end
    walk(path)
    -- rmdir leaves last (deepest first).
    for i = #dirs, 1, -1 do
        C.rmdir(dirs[i])
    end
    return not M.file_exists(path)
end

local CWD_BUF = ffi.new('char[?]', 4096)

function M.getcwd()
    if C.getcwd(CWD_BUF, 4096) == nil then
        error("ntosbe.platform.getcwd: failed (path > 4095?)", 2)
    end
    return ffi.string(CWD_BUF)
end

local REAL_BUF = ffi.new('char[?]', 4096)

function M.realpath(path)
    -- Linux man: with resolved_path != NULL, glibc requires it to be
    -- PATH_MAX (4096) bytes; we pass a 4096-byte buf so this is safe.
    if C.realpath(path, REAL_BUF) == nil then return nil end
    return ffi.string(REAL_BUF)
end

-- ---------------- Time ----------------

function M.now()
    return os.time()
end

function M.localtime(t)
    local d = os.date('*t', t)
    return {
        year = d.year, month = d.month, day = d.day,
        hour = d.hour, min = d.min, sec = d.sec,
    }
end

-- ---------------- Env ----------------

function M.setenv(name, value)
    C.setenv(name, value, 1)
end

function M.getenv(name)
    -- Lua's os.getenv works on host; no need to FFI for this.
    return os.getenv(name)
end

function M.environ()
    local out = {}
    local i = 0
    while C.environ[i] ~= nil do
        out[#out + 1] = ffi.string(C.environ[i])
        i = i + 1
    end
    return out
end

-- ---------------- Process spawn ----------------

local function strvec(t)
    -- Convert {s1, s2, ...} to a NULL-terminated char*[] suitable for
    -- argv / envp.  The Lua strings in `t` must stay alive through the
    -- spawn syscall (their immutable byte arrays back the cdata
    -- pointers); callers hold them in argv/env tables across the call.
    local n = #t
    local arr = ffi.new('const char *[?]', n + 1)
    for i = 1, n do arr[i - 1] = t[i] end
    arr[n] = nil
    return arr
end

local function exit_status_of(wstatus)
    -- WIFEXITED + WEXITSTATUS; matches what bash $? returns for a
    -- normally-exited child.  Signal-killed children get 128+sig.
    if bit.band(wstatus, 0x7f) == 0 then
        return bit.band(bit.rshift(wstatus, 8), 0xff)
    end
    return 128 + bit.band(wstatus, 0x7f)
end

-- Spawn + wait.  cwd is applied via chdir/restore around the spawn —
-- posix_spawn_file_actions_addchdir_np is glibc-only and we want this
-- portable to MicroNT's eventual native impl.  Single-threaded by
-- design; callers serialize.
function M.spawn_wait(opts)
    local argv = opts.argv
    if not argv or #argv == 0 then
        error("ntosbe.platform.spawn_wait: argv required", 2)
    end

    local env_table = opts.env or M.environ()

    local saved_cwd
    if opts.cwd then
        saved_cwd = M.getcwd()
        if C.chdir(opts.cwd) ~= 0 then
            error("spawn_wait: chdir(" .. opts.cwd .. ") failed", 2)
        end
    end

    -- Hold both vectors in named locals so the cdata isn't GC'd before
    -- posix_spawn returns; the underlying Lua strings live in argv /
    -- env_table on the caller's stack frame.
    local argv_vec = strvec(argv)
    local env_vec  = strvec(env_table)

    local prog = opts.path or argv[1]

    local pid_box = ffi.new('ntosbe_pid_t[1]')
    local rc
    if opts.search_path then
        rc = C.posix_spawnp(pid_box, prog, nil, nil,
                            ffi.cast('char *const*', argv_vec),
                            ffi.cast('char *const*', env_vec))
    else
        rc = C.posix_spawn(pid_box, prog, nil, nil,
                           ffi.cast('char *const*', argv_vec),
                           ffi.cast('char *const*', env_vec))
    end

    if opts.cwd then C.chdir(saved_cwd) end

    if rc ~= 0 then
        error(("spawn_wait: posix_spawn(%s) failed: %d"):format(prog, rc))
    end

    local status_box = ffi.new('int[1]')
    if C.waitpid(pid_box[0], status_box, 0) < 0 then
        error("spawn_wait: waitpid failed")
    end
    return exit_status_of(status_box[0])
end

-- ---------------- Logging ----------------

function M.log(msg)
    io.stderr:write(msg)
    io.stderr:write("\n")
end

function M.die(msg)
    M.log("ntosbe: " .. msg)
    os.exit(1)
end

else

-- ----------------------------------------------------------------
-- MicroNT backend — stubs.
--
-- When self-host arrives, these route through nt.dll.fs (NtCreateFile
-- / NtReadFile / NtWriteFile) and nt.tree (directory enumeration).
-- Until then they error so callers get a clear "build inside the
-- OS isn't wired yet" message rather than a confusing nil deref.
--
-- log() works today via the base library's print, which goes to
-- the inherited stdio handle (Control\Init\Stdio = COM1) — handy
-- for any pkg/ntosbe consumer that wants to be importable from
-- the OS side even before the file-I/O backend lands.
-- ----------------------------------------------------------------

-- All paths the build code passes are forward-slash joined (e.g.
-- "/SystemRoot/src/NT/PRIVATE/NTOS/DD/NULL/SOURCES").  NT syscalls
-- want backslash-joined NT-namespace paths.  Convert at the syscall
-- boundary; build code stays platform-agnostic.
local function to_nt_path(p)
    return (p:gsub("/", "\\"))
end

local FS_FILE_GENERIC_READ            = 0x00120089
local FS_FILE_GENERIC_WRITE           = 0x00120116
local FS_DELETE                       = 0x00010000
local FS_SYNCHRONIZE                  = 0x00100000
local FS_FILE_SHARE_READ              = 0x00000001
local FS_FILE_SHARE_WRITE             = 0x00000002
local FS_FILE_OPEN                    = 1
local FS_FILE_OVERWRITE_IF            = 5
local FS_FILE_DIRECTORY_FILE          = 0x00000001
local FS_FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020
local FS_FILE_NON_DIRECTORY_FILE      = 0x00000040
local FS_FILE_ATTRIBUTE_NORMAL        = 0x00000080
local FS_FILE_ATTRIBUTE_DIRECTORY     = 0x00000010

-- Lazy module imports.  Doing them at platform-load time would cycle
-- (nt.dll.* lazy-load through their own require chains and some test
-- code may load platform before nt is ready).  Instead, defer to
-- first-use; the require cache handles re-entry.
local _bit, _ffi, _fs, _oa, _rtl, _ps, _ke
local function lazy_imports()
    if _fs then return end
    _bit = require('bit')
    _ffi = require('ffi')
    _fs  = require('nt.dll.fs')
    _oa  = require('nt.dll.oa')
    _rtl = require('nt.dll.rtl')
    _ps  = require('nt.dll.ps')
    _ke  = require('nt.dll.ke')
end

-- ---------------- File I/O ----------------

function M.read_file(path)
    lazy_imports()
    local nt_path = to_nt_path(path)
    local noa = _oa.path(nt_path)
    local ok, h = pcall(_fs.NtOpenFile,
        _bit.bor(FS_FILE_GENERIC_READ, FS_SYNCHRONIZE),
        noa.oa,
        _bit.bor(FS_FILE_SHARE_READ, FS_FILE_SHARE_WRITE),
        FS_FILE_SYNCHRONOUS_IO_NONALERT)
    if not ok then return nil end           -- missing / unreadable

    local ok2, ret = pcall(function()
        local std = _fs.query_standard(h)
        local n = tonumber(std.EndOfFile.QuadPart)
        if n == 0 then return "" end
        local buf = _ffi.new('uint8_t[?]', n)
        local got, _st = _fs.NtReadFile(h, buf, n, nil)
        return _ffi.string(buf, got)
    end)
    h:close()
    if not ok2 then error(ret, 0) end
    return ret
end

function M.write_file(path, bytes)
    lazy_imports()
    local nt_path = to_nt_path(path)
    local noa = _oa.path(nt_path)
    local h = _fs.NtCreateFile(
        _bit.bor(FS_FILE_GENERIC_WRITE, FS_SYNCHRONIZE),
        noa.oa,
        nil,                                 -- AllocationSize
        FS_FILE_ATTRIBUTE_NORMAL,
        _bit.bor(FS_FILE_SHARE_READ, FS_FILE_SHARE_WRITE),
        FS_FILE_OVERWRITE_IF,
        _bit.bor(FS_FILE_NON_DIRECTORY_FILE, FS_FILE_SYNCHRONOUS_IO_NONALERT),
        nil, 0)
    local ok, ret = pcall(function()
        if #bytes > 0 then
            _fs.NtWriteFile(h, bytes, #bytes, nil)
        end
    end)
    h:close()
    if not ok then error(ret, 0) end
end

function M.copy_file(src, dst)
    -- Naive: read all + write all.  All build-path files (SOURCES,
    -- _objects.mac, .h/.c outputs, .lib/.obj) fit in RAM comfortably.
    local data = M.read_file(src)
    if not data then return false, "open " .. src end
    M.write_file(dst, data)
    return true
end

function M.file_size(path)
    -- Composed: open + query_standard + close.  Used only by
    -- disk.lua (host-side); on guest the build path doesn't reach
    -- for it.  Provide it anyway so future callers don't trip.
    lazy_imports()
    local noa = _oa.path(to_nt_path(path))
    local ok, h = pcall(_fs.NtOpenFile,
        _bit.bor(FS_FILE_GENERIC_READ, FS_SYNCHRONIZE),
        noa.oa,
        _bit.bor(FS_FILE_SHARE_READ, FS_FILE_SHARE_WRITE),
        FS_FILE_SYNCHRONOUS_IO_NONALERT)
    if not ok then return nil end
    local std = _fs.query_standard(h)
    h:close()
    return tonumber(std.EndOfFile.QuadPart)
end

-- ---------------- Stat-like ----------------

function M.file_exists(path)
    lazy_imports()
    return _fs.query_attributes(to_nt_path(path)) ~= nil
end

function M.is_dir(path)
    lazy_imports()
    local info = _fs.query_attributes(to_nt_path(path))
    if info == nil then return false end
    return _bit.band(info.FileAttributes, FS_FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

function M.is_executable(path)
    -- NT 3.5 has no executable bit.  Build code only checks this for
    -- the host-side wibo binary, gated by `platform.on_host` already.
    -- On guest, return true for any existing file so callers don't
    -- false-negative.
    return M.file_exists(path)
end

function M.mtime(path)
    lazy_imports()
    local info = _fs.query_attributes(to_nt_path(path))
    if info == nil then return nil end
    return _rtl.li_to_unix(info.LastWriteTime)
end

-- ---------------- Directory ops ----------------

function M.list_dir(path)
    lazy_imports()
    return _fs.list_dir(to_nt_path(path))
end

function M.list_tree(root)
    -- Recursive walk; returns root-relative paths, files only.
    -- Pure Lua over list_dir + is_dir.
    local out = {}
    local function walk(rel)
        local full = (rel == "") and root or (root .. "/" .. rel)
        for _, name in ipairs(M.list_dir(full)) do
            local sub = (rel == "") and name or (rel .. "/" .. name)
            if M.is_dir(full .. "/" .. name) then
                walk(sub)
            else
                out[#out + 1] = sub
            end
        end
    end
    walk("")
    return out
end

function M.mkdir_p(path)
    -- Walk components, ensure each exists as a directory.  Uses the
    -- create_dir helper which combines NtCreateFile(DIR, OPEN_IF).
    lazy_imports()
    local nt_path = to_nt_path(path)
    -- Split on backslashes and re-accumulate, opening at each step.
    -- Skip empty leading component (absolute paths begin with `\`).
    local parts = {}
    for p in nt_path:gmatch("[^\\]+") do parts[#parts + 1] = p end
    local accum = nt_path:sub(1, 1) == "\\" and "" or parts[1]
    if nt_path:sub(1, 1) ~= "\\" then table.remove(parts, 1) end
    for _, comp in ipairs(parts) do
        accum = accum .. "\\" .. comp
        local ok, h = pcall(_fs.create_dir, accum)
        if ok then h:close() end
        -- Errors are tolerated — a path component that's a file
        -- (rather than a missing dir) will surface later when an op
        -- inside that path fails.
    end
end

function M.unlink(path)
    lazy_imports()
    local noa = _oa.path(to_nt_path(path))
    local ok, h = pcall(_fs.NtOpenFile,
        _bit.bor(FS_DELETE, FS_SYNCHRONIZE),
        noa.oa,
        _bit.bor(FS_FILE_SHARE_READ, FS_FILE_SHARE_WRITE,
                 0x00000004 --[[FILE_SHARE_DELETE]]),
        FS_FILE_SYNCHRONOUS_IO_NONALERT)
    if not ok then return false end
    local ok2 = pcall(_fs.set_disposition, h, true)
    h:close()
    return ok2
end

function M.rmdir(path)
    -- NT 3.5 set_disposition works on directory handles too — same
    -- code path as unlink.
    return M.unlink(path)
end

function M.rmrf(path)
    if not M.file_exists(path) then return true end
    if not M.is_dir(path) then
        return M.unlink(path)
    end
    -- Post-order: collect dir paths going in, delete files going down,
    -- then rmdir going back up.  Same shape as host rmrf.
    local dirs = {}
    local function walk(p)
        dirs[#dirs + 1] = p
        for _, name in ipairs(M.list_dir(p)) do
            local sub = p .. "/" .. name
            if M.is_dir(sub) then
                walk(sub)
            else
                M.unlink(sub)
            end
        end
    end
    walk(path)
    for i = #dirs, 1, -1 do
        M.rmdir(dirs[i])
    end
    return not M.file_exists(path)
end

function M.realpath(path)
    -- Build code uses this only for the host-side bootstrap.  On
    -- guest, return the input unchanged — caller has already
    -- normalised it.
    return path
end

function M.getcwd()
    lazy_imports()
    return _rtl.getcwd()
end

-- ---------------- Time ----------------

function M.now()
    lazy_imports()
    return _rtl.li_to_unix(_ke.NtQuerySystemTime())
end

function M.localtime(t)
    lazy_imports()
    return _rtl.unix_to_table(t)
end

-- ---------------- Env ----------------

function M.setenv(name, value)
    lazy_imports()
    _rtl.set_env(name, value)
end

function M.getenv(name)
    lazy_imports()
    return _rtl.query_env(name)
end

function M.environ()
    lazy_imports()
    return _rtl.environ()
end

-- ---------------- Process spawn ----------------

-- Quote an argv element if it contains spaces, tabs, or double-quotes.
-- Embedded quotes get backslash-escaped (Win32 / NT cmdline convention).
local function quote_arg(s)
    if s:find('[ \t"]') then
        return '"' .. s:gsub('"', '\\"') .. '"'
    end
    return s
end

local function argv_to_cmdline(argv)
    local parts = {}
    for i, a in ipairs(argv) do
        parts[i] = quote_arg(a)
    end
    return table.concat(parts, " ")
end

function M.spawn_wait(opts)
    lazy_imports()
    if not opts.argv or #opts.argv == 0 then
        error("ntosbe.platform.spawn_wait: argv required", 2)
    end
    if opts.search_path then
        error("ntosbe.platform.spawn_wait: search_path not supported on NT (pass an absolute path)", 2)
    end

    local exe     = to_nt_path(opts.path or opts.argv[1])
    local cmdline = argv_to_cmdline(opts.argv)
    local cwd     = opts.cwd and to_nt_path(opts.cwd) or nil

    local proc = _ps.spawn{
        exe      = exe,
        cmdline  = cmdline,
        env      = opts.env,
        cwd      = cwd,
        dll_path = opts.dll_path,                    -- toolchain DLL search list
    }
    return _ps.wait_exit(proc)
end

-- ---------------- Logging ----------------

function M.log(msg)
    print(msg)
end

function M.die(msg)
    print("ntosbe: " .. msg)
    error(msg, 0)
end

end

return M
