-- ntosbe layer: ddk351
--
-- Third-party Microsoft CLI binaries used as ABI-conformance signal
-- under \SystemRoot\pkg\ddk351\.  The point of the suite is to run
-- unmodified MS-shipped tools against our kernel + kernel32 + ntdll
-- and observe drift — either a binary runs and exits sanely or our
-- ABI has shifted.
--
-- Selection bar: each binary must exercise real NT-side surface
-- (native ntdll calls + NT struct layout + struct packing), not just
-- KERNEL32 CRT wrappers.  selftest already covers the CRT/kernel32
-- surface; this layer is for the NT-structural cross-check.
--
-- Active set:
--   DRIVERS — NtQuerySystemInformation(SystemModuleInformation) +
--             RTL_PROCESS_MODULES struct (DDK 3.51)
--   FLOATER — multi-thread FPU/NPX accuracy under context switches
--             (HCT NPX)
--   REGDMP  — CM (registry) walk via NtOpenKey / NtEnumerateKey /
--             NtEnumerateValueKey (DDK 3.51)
--
-- Tried-and-dropped — not ABI-exercising enough to keep, or blocked
-- on subsystems we don't ship:
--   OBJDIR.EXE  — needs ADVAPI32 + LSA; we don't run LSA by design
--   GETGEOM/GETMEDIA — argv parsing quirk we haven't disassembled
--   HAPISUM     — HAPI-specific test-artifact tool, not general
--   WC/SLEEP/NOW/EXETYPE — CRT/kernel32 surface; not NT-structural
--   PERL.EXE    — AVs in kernel32 NLS path (see main.lua note);
--                 worth re-trying once user32/advapi32 stubs land
--
-- Future direction (out of scope for this layer):
--   Build a Win32 layer = kernel32 (have) + imagehlp (have) +
--   stub user32 + cut-down advapi32 (registry/SD, no LSA/Net) +
--   wsock32 from source.  Unlocks NTSD/CDB scriptable debugger
--   surface and the wider RK/DDK tool ecosystem in one go.
--
-- Source binaries are tracked under src/pkg/ddk351/bin/.  The lua
-- layer's auto-stage rule whitelists `.lua` only, so these don't get
-- duplicated at \SystemRoot\lua\ddk351\bin\.
--
-- The runner is src/pkg/ddk351/main.lua, auto-staged by the lua
-- layer at \SystemRoot\lua\ddk351\main.lua and pointed at by the
-- ddk351 profile's init.args.

local M = {}

M.name = "ddk351"
M.description = "NT 3.51 DDK / HCT pre-compiled CLI utilities (ABI smoke)"

function M.files(paths)
    local bin = paths.pkg_root .. "/ddk351/bin"
    return {
        { dest = "pkg/ddk351/DRIVERS.EXE", src = bin .. "/DRIVERS.EXE" },
        { dest = "pkg/ddk351/FLOATER.EXE", src = bin .. "/FLOATER.EXE" },
        { dest = "pkg/ddk351/REGDMP.EXE",  src = bin .. "/REGDMP.EXE"  },
    }
end

return M
