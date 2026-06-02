-- nt.term.vt — the input half of the VT codec: a byte → key-event
-- decoder.  This is where the VT/ANSI vocabulary lives, decoded ONCE
-- (per the Windows Console "Cursor Keys / Numpad" tables and xterm),
-- so nothing above it ever touches an escape byte.
--
-- decoder():feed(byte) returns (kind, arg) when a key completes, or nil
-- while mid-sequence or for an ignored byte.  Both returns are numbers —
-- the decode loop allocates nothing.  The output renderer (the other
-- half of the codec) lives in nt.term.render.
--
-- Recognized input (both CSI "ESC [" and SS3 "ESC O" introducers):
--   printable           -> TEXT(byte)
--   CR / LF             -> ENTER          BS / DEL  -> BACKSPACE
--   TAB                 -> TAB            ^C -> INTERRUPT   ^D -> EOF
--   ESC [ A / ESC O A   -> UP   (B DOWN, C RIGHT, D LEFT)
--   ESC [ H / F         -> HOME / END
--   ESC [ 1~ 7~         -> HOME           ESC [ 4~ 8~ -> END
--   ESC [ 3~            -> DELETE
--   modifier params (ESC [ 1;5D) are accepted and the modifier ignored;
--   anything unrecognized (F-keys, PgUp/Dn, lone ESC) is swallowed.

local K = require('nt.term.keys').K

local M = {}

local Dec = {}
Dec.__index = Dec

-- esc: 0 normal, 1 saw ESC (expect CSI '[' or SS3 'O'), 2 inside a
-- sequence (digits accumulate into param until a ';' or a final byte).
function M.decoder()
    return setmetatable({ esc = 0, param = 0, semi = false }, Dec)
end

function Dec:_csi(final)
    if     final == 0x41 then return K.UP,    0    -- 'A'
    elseif final == 0x42 then return K.DOWN,  0    -- 'B'
    elseif final == 0x43 then return K.RIGHT, 0    -- 'C'
    elseif final == 0x44 then return K.LEFT,  0    -- 'D'
    elseif final == 0x48 then return K.HOME,  0    -- 'H'
    elseif final == 0x46 then return K.END,   0    -- 'F'
    elseif final == 0x7E then                      -- '~' family
        local p = self.param
        if p == 1 or p == 7 then return K.HOME,   0 end
        if p == 4 or p == 8 then return K.END,    0 end
        if p == 3            then return K.DELETE, 0 end
    end
    return nil                                     -- unknown: swallow
end

function Dec:feed(c)
    local esc = self.esc
    if esc == 1 then
        if c == 0x5B or c == 0x4F then             -- CSI '[' or SS3 'O'
            self.esc, self.param, self.semi = 2, 0, false
        else
            self.esc = 0                           -- lone ESC: dropped
        end
        return nil
    elseif esc == 2 then
        if c >= 0x30 and c <= 0x39 then            -- digit: first param only
            if not self.semi then self.param = self.param * 10 + (c - 0x30) end
            return nil
        elseif c == 0x3B then                      -- ';' — ignore the modifier
            self.semi = true
            return nil
        elseif c >= 0x40 and c <= 0x7E then        -- final byte: dispatch
            self.esc = 0
            return self:_csi(c)
        end
        return nil                                 -- intermediate byte
    end

    if c == 0x1B then self.esc = 1; return nil     -- ESC
    elseif c == 0x0D or c == 0x0A then return K.ENTER,     0   -- CR / LF
    elseif c == 0x7F or c == 0x08 then return K.BACKSPACE, 0   -- DEL / BS
    elseif c == 0x09 then              return K.TAB,       0   -- TAB
    elseif c == 0x03 then              return K.INTERRUPT, 0   -- ^C
    elseif c == 0x04 then              return K.EOF,       0   -- ^D
    elseif c >= 0x20 and c <= 0x7E then return K.TEXT,     c   -- printable
    end
    return nil                                     -- other control: ignored
end

return M
