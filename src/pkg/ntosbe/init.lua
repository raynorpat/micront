-- ntosbe — the NT OS Build Environment.
--
-- The MicroNT build system as a self-sufficient Lua package, with no
-- Python dependency and no host-only assumptions.  Host entry is
-- src/build.sh → ntosbe.build.main; the in-OS entry will route through
-- the same ntosbe.build module once the platform.spawn_wait NT
-- backend lands, closing the orobouros self-build loop.
--
-- pkg/ntosbe/ is staged at \SystemRoot\pkg\ntosbe\ on disk like every
-- other package, so a booted MicroNT image automatically carries its
-- own build environment.  No separate "now we copy tools into the OS"
-- step.
--
-- Subpackage layout:
--
--   platform.lua    host-vs-OS abstraction: file I/O, directory
--                   listing, timestamps, logging.
--   layers/         one .lua per capability slice.  Each layer owns
--                   its driver files, SYSTEM-hive service entries and
--                   boot-driver order.  See layers/core.lua.
--   profiles/       one .lua per disk flavour: a layer list + the
--                   init entry script.
--   compose.lua     resolves a profile's layers (globs + `requires`)
--                   and runs them into one hive + one file list.
--
-- Filesystem and disk-image format libraries (hive, mbr, fat16,
-- ntfs, drive) live under pkg/nt/fs/ — this orchestrator pulls
-- them through M.fs (= require('nt.fs')) and stays focused on
-- the build-driver job.

local M = {}

M.platform = require('ntosbe.platform')
M.fs       = require('nt.fs')

-- ----------------------------------------------------------------
-- build_image — builds SYSTEM hive + ESP boot disk for a given profile.
--
-- opts (table):
--   profile      = profile name (default "default")
--   init         = { exe, args, stdio }  partial overrides ok
--   efi_binary   = absolute path to BOOTX64.EFI    (required, non-ramdisk)
--   output_dir   = where SYSTEM + esp.img land                 (required)
--   src_root     = absolute path to repo's src/ directory      (required)
--   layout       = single | ramdisk | split-fat | split-ntfs (default split-fat)
--   size_mb      = total image size MB, fixed layouts, default 2000
--
-- Writes <output_dir>/SYSTEM (the hive — kept on disk for inspection)
-- and <output_dir>/esp.img (the boot image, with the same hive embedded
-- at \System32\config\SYSTEM).  Returns 0 on success.
-- ----------------------------------------------------------------

function M.build_image(opts)
    local platform = M.platform
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

    local fs = M.fs

    -- ---- Compose the disk from the profile's layers ----
    -- The profile names a layer set; compose resolves it (globs +
    -- `requires`) and runs each layer to yield the hive content and
    -- the disk file list.  Default profile = "default" (a lean
    -- interactive disk booting main.lua); the heavy self-host disk is
    -- the explicit `selfhost` profile.
    local composed = require('ntosbe.compose').compose {
        profile   = opts.profile or "default",
        init      = opts.init,
        paths     = paths,
        list_tree = platform.list_tree,
    }

    -- ---- Build hive ----
    local h = fs.hive.new("SYSTEM")
    composed.apply(h)
    local hive_bytes = h:build(now)

    -- ---- Layout selection (resolved before file routing so the
    -- firmware-less 'ramdisk' layout can skip the EFI binary).
    --   'single'     — one FAT16 partition (type 0xEF) hosts everything.
    --   'ramdisk'    — one FAT16 partition (type 0x06), no EFI binary,
    --                  size computed from content. This is the vmlinuz/PVH
    --                  + ramscsi initrd image: an MBR + single FAT16.
    --   'split-fat'  — partition 1: FAT16 ESP (0xEF, ~64 MB);
    --                  partition 2: FAT16 system (0x06, rest). CANONICAL.
    --   'split-ntfs' — like split-fat, but the system partition is NTFS.
    -- Files route by `where` ('esp'/'root'/'both') only in the split
    -- layouts; single/ramdisk place everything on the one volume.
    local layout = opts.layout or 'split-fat'
    if layout ~= 'single' and layout ~= 'ramdisk'
       and layout ~= 'split-fat' and layout ~= 'split-ntfs' then
        platform.die("Unknown layout '" .. tostring(layout)
                     .. "' (want 'single'|'ramdisk'|'split-fat'|'split-ntfs')")
    end

    -- ---- Resolve disk file list + check sources exist ----
    local files = composed.files
    -- BOOTX64.EFI lives on the ESP for UEFI to find it (where='esp').
    -- The ramdisk is firmware-less (loaded via -kernel/-initrd), so it
    -- carries no EFI binary even when one is supplied.
    if opts.efi_binary and layout ~= 'ramdisk' then
        table.insert(files, 1,
                     { dest = "EFI/BOOT/BOOTX64.EFI", where = 'esp',
                       src = opts.efi_binary })
    end

    -- A file entry sources its content either from a host file
    -- (f.src, copied in) or from in-memory bytes (f.bytes, written
    -- directly — used for content a layer generates at compose time,
    -- e.g. a package zip).  Only host-sourced entries need an
    -- existence check.
    local missing = {}
    for _, f in ipairs(files) do
        if f.src and not platform.file_exists(f.src) then
            missing[#missing + 1] = f.src
        end
    end
    if #missing > 0 then
        platform.log("ERROR: required disk inputs are missing:")
        for _, m in ipairs(missing) do platform.log("  - " .. m) end
        platform.log("Run the appropriate build targets first.")
        return 1
    end

    -- Emit a manifest so the verify harness can check every file
    -- read back from the built disk against its source bytes.  Format:
    -- one tab-separated line per file: `<where>\t<dest>\t<src_path>`.
    -- The verify script (tools/verify_disk.sh) computes sha256 of
    -- both sides and reports any mismatch.

    -- ---- Build disk image ----
    -- Default 2000 MiB total for the fixed-size layouts; 'ramdisk'
    -- computes its volume size from content (below).  Single owner of the
    -- size default — callers pass size_mb only to override.
    local total_mb = opts.size_mb or 2000
    local PRE_PARTITION_GAP_MB = 1
    local ESP_SIZE_MB          = 64

    local image_name = (layout == 'ramdisk') and "initrd.img" or "esp.img"
    local esp_path   = opts.output_dir .. "/" .. image_name
    local d = fs.drive.new {
        table     = 'mbr',
        signature = 0x4E544653,
    }

    if layout == 'single' or layout == 'ramdisk' then
        -- Both put everything on one FAT16 volume (the `where` tag is
        -- ignored). 'single' is a fixed-size bootable ESP-typed disk;
        -- 'ramdisk' is a content-sized, 0x06-typed initrd image.
        local vol_size_mb
        if layout == 'ramdisk' then
            -- Size from actual content — it's a RAM disk, so don't burn
            -- RAM on slack. Sum file sizes rounded up to a conservative
            -- cluster, plus FAT overhead and free headroom for NT's own
            -- runtime writes (hive growth, temp, last-known-good).
            local content = #hive_bytes
            for _, f in ipairs(files) do
                local sz = f.bytes and #f.bytes or (platform.file_size(f.src) or 0)
                content = content + math.floor((sz + 4095) / 4096) * 4096
            end
            local overhead = 512 * 1024
            local free_hdr = math.max(8 * 1024 * 1024, math.floor(content * 0.25))
            vol_size_mb = math.max(8,
                math.ceil((content + overhead + free_hdr) / (1024 * 1024)))
        else
            vol_size_mb = total_mb - PRE_PARTITION_GAP_MB
        end

        local vol = fs.fat16.new {
            size_mb      = vol_size_mb,
            volume_label = "NT",
            now          = now,
        }
        for _, f in ipairs(files) do
            local sz, basename
            if f.bytes then
                sz, basename = #f.bytes, "(generated)"
            else
                sz       = platform.file_size(f.src) or 0
                basename = f.src:match("([^/]+)$") or f.src
            end
            platform.log(string.format("  all  %-40s %8d  (%s)",
                                       f.dest, sz, basename))
            if f.bytes then vol:add_bytes(f.dest, f.bytes)
            else            vol:add_file(f.dest, f.src, platform) end
        end
        vol:mkdir("tmp")
        vol:add_bytes("System32/config/SYSTEM", hive_bytes)
        -- 'single' = ESP-typed (0xEF) bootable disk; 'ramdisk' = plain
        -- FAT16 system partition (0x06) served by ramscsi.
        local type_code = (layout == 'ramdisk') and 0x06 or 0xEF
        d:add(vol, { active = true, type_code = type_code })
    else
        -- split-fat / split-ntfs: ESP + system, routed by `where`.
        local sys_size_mb = total_mb - PRE_PARTITION_GAP_MB - ESP_SIZE_MB
        local sys_min     = (layout == 'split-ntfs') and 8 or 4
        if sys_size_mb < sys_min then
            platform.die(string.format(
                "size_mb=%d too small for ESP=%d + system partition "
                .. "(need ≥%d for layout=%s)",
                total_mb, ESP_SIZE_MB,
                ESP_SIZE_MB + PRE_PARTITION_GAP_MB + sys_min, layout))
        end

        local esp_vol = fs.fat16.new {
            size_mb      = ESP_SIZE_MB,
            volume_label = "ESP",
            now          = now,
        }
        local sys_vol
        if layout == 'split-fat' then
            sys_vol = fs.fat16.new {
                size_mb      = sys_size_mb,
                volume_label = "NT",
                now          = now,
            }
        else  -- split-ntfs
            local bit = require('bit')
            sys_vol = fs.ntfs.new {
                size_mb       = sys_size_mb,
                volume_label  = "NT",
                volume_serial = bit.band(now or 0, 0xFFFFFFFF),
                now           = now,
            }
        end

        -- Route each entry by f.where:
        --   'esp'  → ESP only
        --   'root' → system only (default if .where omitted)
        --   'both' → both partitions
        for _, f in ipairs(files) do
            -- Source: host file (f.src) or generated bytes (f.bytes).
            local sz, basename
            if f.bytes then
                sz, basename = #f.bytes, "(generated)"
            else
                sz       = platform.file_size(f.src) or 0
                basename = f.src:match("([^/]+)$") or f.src
            end
            local where = f.where or 'root'
            if where ~= 'esp' and where ~= 'root' and where ~= 'both' then
                platform.die(string.format(
                    "disk file %s: invalid where=%q (want 'esp'|'root'|'both')",
                    f.dest, tostring(where)))
            end
            local tag
            if     where == 'esp'  then tag = "esp "
            elseif where == 'root' then tag = "sys "
            else                        tag = "both"
            end
            platform.log(string.format("  %s %-40s %8d  (%s)",
                                       tag, f.dest, sz, basename))
            local function place(vol)
                if f.bytes then vol:add_bytes(f.dest, f.bytes)
                else            vol:add_file(f.dest, f.src, platform) end
            end
            if where == 'esp'  or where == 'both' then place(esp_vol) end
            if where == 'root' or where == 'both' then place(sys_vol) end
        end
        sys_vol:mkdir("tmp")
        -- SYSTEM hive lives on the ESP for boot-efi pre-handoff.
        -- Runtime hive flushes target \SystemRoot\System32\config\SYSTEM
        -- (system partition); they fail silently today.
        esp_vol:add_bytes("System32/config/SYSTEM", hive_bytes)

        d:add(esp_vol, { active = true, type_code = 0xEF })
        d:add(sys_vol, {})  -- type from volume:build() (0x06 fat / 0x07 ntfs)
    end

    -- ---- Write outputs ----
    platform.mkdir_p(opts.output_dir)
    platform.write_file(opts.output_dir .. "/SYSTEM", hive_bytes)
    platform.log("SYSTEM hive: " .. #hive_bytes .. " bytes -> "
                 .. opts.output_dir .. "/SYSTEM")

    -- Emit the manifest after we know files were all routed.
    do
        local lines = {}
        for _, f in ipairs(files) do
            lines[#lines + 1] = string.format("%s\t%s\t%s",
                f.where or 'root', f.dest, f.src or "(generated)")
        end
        platform.write_file(opts.output_dir .. "/manifest.tsv",
                             table.concat(lines, "\n") .. "\n")
    end

    local stats = d:build(platform, esp_path)

    platform.log(string.format(
        "  Disk: %d MB  Signature: 0x%08X  Layout: %s",
        stats.size_mb, stats.signature, layout))
    for i, p in ipairs(stats.partitions) do
        local fs_kind
        if     p.type_code == 0xEF then fs_kind = "FAT16/ESP"
        elseif p.type_code == 0x06 then fs_kind = "FAT16/system"
        elseif p.type_code == 0x07 then fs_kind = "NTFS/system"
        else                            fs_kind = string.format("type-0x%02X",
                                                                p.type_code)
        end
        platform.log(string.format(
            "  Partition %d (%s): LBA %d..%d  type 0x%02X  (%d MB %s)",
            i, p.label, p.lba, p.lba + p.sectors - 1, p.type_code,
            math.floor(p.sectors * 512 / (1024 * 1024)), fs_kind))
        if p.stats.used_clusters then
            platform.log(string.format(
                "             clusters: %d used / %d total  (%d KB free)",
                p.stats.used_clusters, p.stats.total_clusters,
                p.stats.free_kb))
        elseif p.stats.clusters_used then
            platform.log(string.format(
                "             clusters: %d used / %d total  (cluster=%d B)",
                p.stats.clusters_used, p.stats.total_clusters,
                p.stats.cluster_size))
        end
    end
    platform.log(string.format(
        "  MBR checksum for ARC_DISK_SIGNATURE.CheckSum: 0x%08X",
        stats.mbr_checksum))
    platform.log("Disk image: " .. esp_path)

    return 0
end

return M
