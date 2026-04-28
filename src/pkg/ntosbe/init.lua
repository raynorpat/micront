-- ntosbe — the NT OS Build Environment.
--
-- The MicroNT build system as a self-sufficient Lua package, with no
-- Python dependency and no host-only assumptions.  Runs on the host
-- during bootstrap (src/build.lua dispatches into here) and, once
-- Phase E lands, inside MicroNT itself — closing the orobouros
-- self-build loop.
--
-- pkg/ntosbe/ is staged at \SystemRoot\lua\ntosbe\ on disk like every
-- other package, so a booted MicroNT image automatically carries its
-- own build environment.  No separate "now we copy tools into the OS"
-- step.
--
-- Subpackage layout:
--
--   platform.lua    host-vs-OS abstraction: file I/O, directory
--                   listing, timestamps, logging.
--   hive.lua        NT 3.5 registry hive serializer (port of the
--                   library half of tools/mkhive.py).
--   disk.lua        MBR + FAT16 raw image builder (port of the
--                   library half of tools/mkdisk.py).  GPT + NTFS will
--                   land as peer encoders later.
--   profiles/       one .lua per platform target.  Declarative
--                   description of {boot driver, services list,
--                   drivers to stage, network config, init exe}.
--                   Today's mkhive build_system_hive + mkdisk
--                   _CORE_FILES live in profiles/ide.lua.

local M = {}

M.platform = require('ntosbe.platform')
M.hive     = require('ntosbe.hive')
M.disk     = require('ntosbe.disk')

-- ----------------------------------------------------------------
-- build_image — builds SYSTEM hive + ESP boot disk for a given profile.
--
-- opts (table):
--   profile      = profile name (default "ide")
--   init         = { exe, args, stdio }  partial overrides ok
--   efi_binary   = absolute path to BOOTX64.EFI                (required)
--   output_dir   = where SYSTEM + esp.img land                 (required)
--   src_root     = absolute path to repo's src/ directory      (required)
--   size_mb      = ESP image size, default 64
--
-- Writes <output_dir>/SYSTEM (the hive — kept on disk for inspection)
-- and <output_dir>/esp.img (the boot image, with the same hive embedded
-- at \System32\config\SYSTEM).  Returns 0 on success.
-- ----------------------------------------------------------------

function M.build_image(opts)
    local platform = M.platform
    local profile  = require('ntosbe.profiles.' .. (opts.profile or "ide"))
    local now      = platform.now()

    -- Resolve the paths the profile asks for.
    local nt    = opts.src_root .. "/NT"
    local paths = {
        nt       = nt,
        sdk_lib  = nt .. "/PUBLIC/SDK/LIB/I386",
        cr_dir   = opts.src_root .. "/cr",
        pkg_root = opts.src_root .. "/pkg",
        obj      = function(comp)
                       return nt .. "/PRIVATE/" .. comp .. "/obj/i386"
                   end,
    }

    -- ---- Build hive ----
    local h = M.hive.new("SYSTEM")
    profile.apply(h, opts.init)
    local hive_bytes = h:build(now)

    -- ---- Resolve disk file list + check sources exist ----
    local files = profile.disk_files(paths, platform.list_tree)
    -- EFI binary at the front so the partition gets it for OVMF.
    table.insert(files, 1,
                 { dest = "EFI/BOOT/BOOTX64.EFI", src = opts.efi_binary })

    local missing = {}
    for _, f in ipairs(files) do
        if not platform.file_exists(f.src) then
            missing[#missing + 1] = f.src
        end
    end
    if #missing > 0 then
        platform.log("ERROR: required disk inputs are missing:")
        for _, m in ipairs(missing) do platform.log("  - " .. m) end
        platform.log("Run the appropriate build targets first.")
        return 1
    end

    -- ---- Build disk image ----
    local img = M.disk.new {
        size_mb      = opts.size_mb or 64,
        signature    = 0x4E544653,
        volume_label = "NT",
        now          = now,
    }
    for _, f in ipairs(files) do
        local sz = platform.file_size(f.src) or 0
        local basename = f.src:match("([^/]+)$") or f.src
        platform.log(string.format("  %-40s %8d  (%s)",
                                   f.dest, sz, basename))
        img:add_file(f.dest, f.src, platform)
    end
    -- Embed the SYSTEM hive at the path the kernel reads.
    img:add_bytes("System32/config/SYSTEM", hive_bytes)

    -- ---- Write outputs ----
    platform.mkdir_p(opts.output_dir)
    platform.write_file(opts.output_dir .. "/SYSTEM", hive_bytes)
    platform.log("SYSTEM hive: " .. #hive_bytes .. " bytes -> "
                 .. opts.output_dir .. "/SYSTEM")

    local esp_path = opts.output_dir .. "/esp.img"
    local stats    = img:write(platform.write_file, esp_path, platform)

    platform.log(string.format(
        "  Disk: %d MB  Signature: 0x%08X",
        stats.size_mb, stats.signature))
    platform.log(string.format(
        "  Partition: LBA %d..%d  (%d MB FAT16)",
        stats.partition_lba,
        stats.partition_lba + stats.partition_size - 1,
        math.floor(stats.partition_size * 512 / (1024 * 1024))))
    platform.log(string.format(
        "  Clusters: %d used / %d total  (%d KB free)",
        stats.used_clusters, stats.total_clusters, stats.free_kb))
    platform.log(string.format(
        "  MBR checksum for ARC_DISK_SIGNATURE.CheckSum: 0x%08X",
        stats.mbr_checksum))
    platform.log("ESP image: " .. esp_path)

    return 0
end

-- ----------------------------------------------------------------
-- main — command-line entry.  Parses --flag=value / --flag value, then
-- dispatches to build_image.  Currently a single command (the disk
-- builder); subcommands (e.g. "ntosbe hive ..." for hive-only output)
-- can land later if a caller actually needs them.
-- ----------------------------------------------------------------

local function parse_argv(argv)
    local opts = {}
    local i = 1
    while i <= #argv do
        local a = argv[i]
        local key, value = a:match("^%-%-([^=]+)=(.*)$")
        if not key and a:sub(1, 2) == "--" then
            key   = a:sub(3)
            value = argv[i + 1]
            i = i + 1
        end
        if key then
            -- Normalise --init-args to opts.init_args etc.
            opts[(key:gsub("%-", "_"))] = value
        end
        i = i + 1
    end
    return opts
end

function M.main(argv)
    local platform = M.platform
    local opts     = parse_argv(argv or {})

    if not opts.efi_binary then platform.die("--efi-binary required") end
    if not opts.output_dir then platform.die("--output-dir required") end
    if not opts.src_root   then platform.die("--src-root required")   end

    return M.build_image {
        profile    = opts.profile,
        init = {
            exe   = opts.init_exe,
            args  = opts.init_args,
            stdio = opts.init_stdio,
        },
        efi_binary = opts.efi_binary,
        output_dir = opts.output_dir,
        src_root   = opts.src_root,
        size_mb    = tonumber(opts.size_mb) or 64,
    }
end

return M
