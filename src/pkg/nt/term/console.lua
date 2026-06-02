-- nt.term.console — the serial console as an nt.term.stream.
--
-- This is the real-hardware terminal backend.  The serial port is assumed
-- to be attached to a VT-capable device (a host terminal emulator / qemu
-- serial), so we just exchange VT bytes with it — no emulation on our
-- side.  (The VGA console, when it lands, is the opposite: a dumb device
-- we must drive a cell grid for; it gets its own backend.)
--
-- Acquisition (ported from the old nt.tty pump): MicroNT has one inherited
-- \Device\Serial0 handle that init opened FILE_SYNCHRONOUS_IO_NONALERT for
-- all of stdio.  Serial is an EXCLUSIVE device, so opening it again BY NAME
-- is denied; a RELATIVE open (RootDirectory = the inherited handle, empty
-- name) is exempt from the exclusivity check and yields a SECOND,
-- OVERLAPPED handle to the same device.  We wrap that as a stream so reads
-- and writes can both be outstanding (the scheduler drives them async).
-- init's synchronous handle is left untouched; nothing is restored — the
-- caller just closes our overlapped handle when the session ends.

local bit    = require('bit')
local fs     = require('nt.dll.fs')
local oa     = require('nt.dll.oa')
local io     = require('io')
local stream = require('nt.term.stream')

-- read + write + (implicit) SYNCHRONIZE.  bit.bor, not +: FILE_GENERIC_READ
-- and _WRITE share SYNCHRONIZE/READ_CONTROL and + would carry.
local SERIAL_ACCESS = bit.bor(fs.FILE_GENERIC_READ, fs.FILE_GENERIC_WRITE)

-- First-byte-return mode: Interval & Multiplier = MAXULONG, Constant =
-- MAXULONG-1 (the ~49-day ceiling init uses).  An overlapped read pends
-- until a key arrives and completes on it — no timeout, no poll.
local SERIAL_TIMEOUTS = {
    ReadIntervalTimeout        = 0xFFFFFFFF,
    ReadTotalTimeoutMultiplier = 0xFFFFFFFF,
    ReadTotalTimeoutConstant   = 0xFFFFFFFE,
}

local M = {}

-- open() -> an overlapped nt.term.stream over the serial console.  Raises
-- if there's no inherited console handle (a process with no serial stdio).
function M.open()
    assert(io.stdout and io.stdout._h, "console.open: no inherited console handle")
    -- Relative open: empty name + RootDirectory = the inherited handle.
    -- `rel` stays referenced until NtCreateFile captures the name.
    local rel = oa.path("", 0, io.stdout._h)
    local h = fs.NtCreateFile(SERIAL_ACCESS, rel.oa, nil,
        fs.FILE_ATTRIBUTE_NORMAL,
        fs.FILE_SHARE_READ + fs.FILE_SHARE_WRITE,
        fs.FILE_OPEN, fs.FILE_NON_DIRECTORY_FILE, nil, 0)
    fs.serial_set_timeouts(h, SERIAL_TIMEOUTS)
    -- offset = true: async serial I/O REQUIRES a (zero) ByteOffset; the
    -- driver ignores the value but rejects a NULL one.
    return stream.wrap(h, { offset = true })
end

return M
