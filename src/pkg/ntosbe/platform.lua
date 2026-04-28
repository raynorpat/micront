-- ntosbe.platform — host-vs-OS abstraction.
--
-- The build environment runs in two places: on the host (LuaJIT built
-- by bootstrap.sh, full lib_io / lib_os, POSIX file I/O) and inside
-- MicroNT (LuaJIT-on-NT, lib_io / lib_os disabled, file I/O via
-- nt.dll.fs).  This module hides the difference so hive.lua, disk.lua,
-- and the profiles don't need to care.
--
-- Detection: presence of io.open is the load-bearing signal.  The
-- MicroNT build of LuaJIT excludes lib_io entirely (see bootstrap.sh's
-- LJLIB_O note for why the host build flips it back on).  That gives
-- us a one-liner check that doesn't need any nt.* modules to be
-- importable yet.
--
-- Surface (current — grows as ports need more):
--   read_file(path)        -> bytes | nil
--   write_file(path, bytes)
--   file_size(path)        -> bytes | nil
--   file_exists(path)      -> bool
--   mtime(path)            -> unix-timestamp | nil
--   now()                  -> unix-timestamp
--   list_dir(path)         -> array of names
--   list_tree(root)        -> array of root-relative file paths (recursive)
--   mkdir_p(path)
--   log(msg)               -> stderr (host) / DbgPrint (in-OS)
--   die(msg)               -> log + exit(1)
--   on_host                -> bool flag for callers that need to branch
--
-- Process spawn is intentionally NOT here yet — only build.lua needs
-- it, and it has its own POSIX bindings.  We'll factor those in when
-- something inside pkg/ntosbe/ actually needs to spawn.

local M = {}

local on_host = (type(io) == 'table' and type(io.open) == 'function')
M.on_host = on_host

-- ----------------------------------------------------------------
-- Host backend — POSIX, builds on stdlib io / os.
--
-- list_dir / list_tree / mtime shell out to ls / stat for now.  A
-- native opendir/readdir/stat FFI binding could replace these later
-- if the syscall fan-out becomes measurable; for the file counts
-- mkdisk handles (~50) the popen overhead is in the noise.
-- ----------------------------------------------------------------

if on_host then

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

    function M.file_size(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local sz = f:seek("end")
        f:close()
        return sz
    end

    function M.file_exists(path)
        local f = io.open(path, "rb")
        if not f then return false end
        f:close()
        return true
    end

    function M.mtime(path)
        local p = io.popen(string.format("stat -c %%Y %q 2>/dev/null", path))
        if not p then return nil end
        local s = p:read("*l")
        p:close()
        return s and tonumber(s) or nil
    end

    function M.now()
        return os.time()
    end

    -- Decompose a unix timestamp into a calendar table {year, month, day,
    -- hour, min, sec}.  Used by FAT directory entries (time/date packed
    -- into 16-bit fields).  Local time matches the host; we don't pretend
    -- to a clock that changes meaning across machines.
    function M.localtime(t)
        local d = os.date('*t', t)
        return {
            year = d.year, month = d.month, day = d.day,
            hour = d.hour, min = d.min, sec = d.sec,
        }
    end

    function M.list_dir(path)
        local names = {}
        local p = io.popen(string.format("ls -A %q 2>/dev/null", path))
        if not p then return names end
        for name in p:lines() do names[#names + 1] = name end
        p:close()
        return names
    end

    function M.list_tree(root)
        -- Depth-first recursive walk; returns paths relative to root,
        -- files only (directories implicit).  Ordering: sorted at each
        -- level, which gives deterministic disk-image layouts run-to-run.
        local out = {}
        local function walk(rel)
            local full = (rel == "") and root or (root .. "/" .. rel)
            local kids = M.list_dir(full)
            table.sort(kids)
            for _, name in ipairs(kids) do
                local sub = (rel == "") and name or (rel .. "/" .. name)
                local subfull = root .. "/" .. sub
                local p = io.popen(string.format(
                    "test -d %q && echo d || echo f", subfull))
                local kind = p:read("*l")
                p:close()
                if kind == "d" then
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
        os.execute(string.format("mkdir -p %q", path))
    end

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

    local function todo(name)
        return function(...)
            error("ntosbe.platform." .. name ..
                  ": MicroNT backend not implemented yet", 2)
        end
    end

    M.read_file   = todo("read_file")
    M.write_file  = todo("write_file")
    M.file_size   = todo("file_size")
    M.file_exists = todo("file_exists")
    M.mtime       = todo("mtime")
    M.now         = todo("now")
    M.localtime   = todo("localtime")
    M.list_dir    = todo("list_dir")
    M.list_tree   = todo("list_tree")
    M.mkdir_p     = todo("mkdir_p")
    M.die         = todo("die")

    function M.log(msg)
        print(msg)
    end

end

return M
