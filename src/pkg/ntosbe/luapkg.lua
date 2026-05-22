-- ntosbe.luapkg — helpers for staging Lua packages onto the disk.
--
-- A Lua "package" is a directory under src/pkg/<name>/ whose modules
-- are require()d as <name>.<sub>...  Two ways to put one on the image,
-- both producing file entries for a layer's files() to return:
--
--   luapkg.zip(name, paths, list_tree)
--       Pack src/pkg/<name>/**.lua into a single STORED archive at
--       pkg/<name>.zip (composed in memory — no temp file).  Member
--       names are prefixed with <name>/ so the on-target zip searcher's
--       module->member map (a.b.c -> <name>.zip:a/b/c.lua) holds.
--       This is the default for directory packages (nt, ntosbe, test).
--
--   luapkg.loose(rel, paths)
--       Stage one source file src/pkg/<rel> loose at pkg/<rel>.  For
--       files that CANNOT live in a zip: the io/os bootstrap shims
--       (the preamble loads them before the zip searcher can serve a
--       package) and entry scripts (the kernel loads these by absolute
--       path via Control\Init Args, never through require()).
--
-- Host-side only — runs under the build host's LuaJIT during compose,
-- where io.* is available.

local zip = require('ntosbe.zip')

local M = {}

function M.zip(name, paths, list_tree)
    local root    = paths.pkg_root .. "/" .. name
    local members = {}
    for _, rel in ipairs(list_tree(root)) do
        if rel:match("%.lua$") then
            local fh = assert(io.open(root .. "/" .. rel, "rb"),
                              "luapkg.zip: cannot open " .. root .. "/" .. rel)
            members[#members + 1] = { name = name .. "/" .. rel,
                                      data = fh:read("*a") }
            fh:close()
        end
    end
    if #members == 0 then
        error("luapkg.zip: no .lua members under " .. root)
    end
    return { dest = "pkg/" .. name .. ".zip", bytes = zip.build(members) }
end

function M.loose(rel, paths)
    return { dest = "pkg/" .. rel, src = paths.pkg_root .. "/" .. rel }
end

return M
