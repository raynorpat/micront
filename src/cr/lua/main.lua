-- main.lua — MicroNT's initial user-mode process.
-- Reached via: Control\InitExe = luajit.exe, Control\InitArgs = main.lua path.
local nt = require('nt')

print("MicroNT main: hello from Lua")

-- Don't return — kernel bugchecks if the initial user process exits.
while true do end
