-- ntosbe layer: drivers.storage.ramscsi
--
-- RAM-disk SCSI miniport (ramscsi.sys).  Presents the in-RAM MBR+FAT16
-- initrd (PVH boot) as a SCSI disk so scsidisk surfaces it as the boot
-- volume.  The boot loader fills the driver's RAMDCFG section with the
-- initrd's physical base+size at stage time; on non-ramdisk (EFI) boots
-- the section stays empty and the miniport reports no adapter — harmless.

local M = {}

M.name = "drivers.storage.ramscsi"
M.description = "RAM-disk SCSI miniport (ramscsi)"
M.requires = { "drivers.storage.scsi" }

function M.registry(h)
    local services = h:key("ControlSet001\\Services")
    services:key("ramscsi")
        :set_dword("Type", 1):set_dword("Start", 0):set_dword("ErrorControl", 1)
        :set_sz("Group", "SCSI miniport")
        :set_multi_sz("DependOnService", { "scsiport" })
end

-- Bucket 20 (miniport tier): after scsiport (10), before scsidisk (30).
function M.boot_drivers(paths)
    return {
        { name = "ramscsi.sys", bucket = 20, src = paths.sdk_lib .. "/ramscsi.sys" },
    }
end

return M
