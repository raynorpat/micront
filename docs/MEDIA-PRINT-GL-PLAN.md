# Plan: Media, printing, OpenGL, and remaining Windows subsystems

Goal: bring the larger missing Windows subsystems into MicroNT after the
shell apps (see `SHELL-APPS-PLAN.md`). Unlike the shell apps, these are
multi-component subsystems, each its own effort. Ordered by value /
tractability.

Source: `SOURCE1B.782_disc1/PRIVATE/WINDOWS` (and `SOURCE1A` for OLE).
OpenGL lives under `WINDOWS/GDI/OPENGL` — see section 3.

## 1. Printing — `WINDOWS/SPOOLER` (recommended first)

Today we ship `WINSPOOL.DRV` as a **prebuilt blob** — `mkdisk.py:531` is
literally tagged `# XXX: pre-built`. Building it from source removes a binary
we don't control and is the most self-contained of these subsystems.

Components (build bottom-up):

- `SPOOLSS`  — spooler RPC service (`spoolss.dll`)
- `LOCALSPL` — local print provider (`localspl.dll`)
- `PRTPROCS` / `QPROC` — print processors
- `MONITORS` — port monitors (LPT/COM/local)
- `SPLEXTS` — spooler extensions
- `PRINTMAN` — Print Manager GUI (`printman.exe`) — also referenced by
  Control Panel's `main.cpl` (`ntspl.lib`), so it ties back to Plan A Tier 3
- `INC` — shared spooler headers

First milestone: build `winspool.drv` from source and drop the prebuilt blob
from `_GUI_FILES`. Then add `spoolss`/`localspl` and register the print
provider in the SOFTWARE hive (`mkhive.py`).

## 2. Multimedia — `WINDOWS/MEDIA`

Core API then drivers then apps.

- `WINMM`   — multimedia API (`winmm.dll`) — the keystone; build first
- `MMDRV`   — multimedia driver layer
- `MSACM`   — audio compression manager (`msacm32.dll`)
- MCI drivers: `MCIWAVE`, `MCISEQ`, `MCICDA`, `MCIHWND`, `MCIOLE`
- `SNDBLST` — Sound Blaster device driver
- `SYNTH`   — software synth
- Apps: `SNDREC32` (Sound Recorder), `MPLAYER2` (Media Player), `SNDVOL`
  (Volume), `CDPLAYER`

**Gating dependency:** `winmm.dll` builds without hardware, but to actually
play audio you need a sound device driver on the kernel side (a QEMU-backed
SB16/AC97 miniport). Decide whether audio output is in scope before the
driver work — `winmm.dll` + MCI is still useful for WAV file APIs without it.

**Do NOT build any 16-bit media code for now.** The MEDIA tree carries
16-bit / Win16-thunk pieces that need the (absent) 16-bit toolchain and WOW
thunk layer — skip them entirely. Known offenders: `AVI/MCIAVI32/VFW16`
(16-bit Video for Windows) and the 16-bit/thunk paths inside `AVI/AVICAP`,
`AVI/VIDEO`, and `MSACM/MSACM`. Stick to the pure Win32 components
(`WINMM`, 32-bit MCI drivers, `MSACM32`) and leave the `*16`/`VFW16`/thunk
subdirs unbuilt.

First milestone: `winmm.dll` builds and links; classic apps that import it
load. Add device driver + `sndblst` as a second phase.

## 3. OpenGL — `WINDOWS/GDI/OPENGL`

Fully present on the disc, and it plugs into the GDI engine we already build:
`GDI/GRE` already contains `WGLSUP.CXX` + `GLDEBUG.H` (the GDI-side WGL
support hooks), and `GDI/INC/WGLP.H` is the shared WGL header. So this is a
new client DLL + server rasterizer libs layered on the existing `gdisrvl`
engine — not a new subsystem.

Build bottom-up:

- **Server libs** (the generic software GL implementation):
  - `glgen`   — `SERVER/GENERIC` (per-arch under `SERVER/GENERIC/I386`)
  - `glsoft`  — `SERVER/SOFT` (software rasterizer)
  - `gldlist` — `SERVER/DLIST` (display lists)
  - `glpixel` — `SERVER/PIXEL` (pixel ops)
  - `glwgl`   — `SERVER/WGL` (WGL server support)
- **`opengl32.dll`** — `CLIENT` (DYNLINK; per-arch stubs under `CLIENT/I386`).
  Links the server libs + ties into the GRE WGL support. This is the keystone.
- **`glu32.dll`** — `GLU/GLU32` (DYNLINK). Utility library; needs
  `libutil` (`GLU/LIBUTIL`), `libtri` (`GLU/LIBTRI`), and the NURBS libs
  `GLU/NURBS/{CORE,CLIENTS,NT}`.
- **Optional proof-of-life** (visible demos / savers):
  - `glaux.lib` — `TOOLKITS/LIBAUX` (demo helper lib)
  - 3D screensavers — `SCRSAVE/SAVER` (`ss3dfo`), `SCRSAVE/PIPES`
    (`pipes`/`sspipes`)
  - Classic demos under `TEST/DEMOS` (atlantis, stonehenge, puzzle) — handy
    end-to-end smoke tests; build with `glaux`.

First milestone: `glgen`+`glsoft`+`gldlist`+`glpixel`+`glwgl` → `opengl32.dll`
links and loads against the existing GDI engine; then `glu32.dll`; then a
demo (atlantis) as a rendering smoke test. `TEST/*` is large — treat it as
opt-in, not part of the core build.

## 4. Other missing pieces (catalogue)

Smaller items, roughly in descending usefulness:

- **OLE / COM** — `WINDOWS/OLE` (here) + `CAIROLE` (in `SOURCE1A`, already
  partially building per recent commits). Completing OLE2 unblocks
  drag-drop / compound docs / many accessories.
- **WinHelp** — `WINDOWS/WINHELP` (`winhelp.exe`); most apps' Help menus.
- **Schedule service** — `WINDOWS/SCHED` (the `at` scheduler).
- **NetDDE** — `WINDOWS/NETDDE` (ClipBook sharing, DDE over net).
- **More accessories** — `SHELL/ACCESORY/*`: Calc, Cardfile, Calendar,
  Write/Terminal, Paintbrush (`PAINTBRS`), Char Map (`UCHARMAP`),
  Clipboard Viewer (`CLIPBRD`), Recorder.
- **Games** — `SHELL/GAMES`: Solitaire (`SOL`), Reversi.
- **Common controls / MSCTLS** — `SHELL/COMMCTRL` (done in Plan A Tier 2),
  `SHELL/MSCTLS` (additional custom controls).

## Suggested order

1. Printing from source (replace the prebuilt `winspool.drv`).
2. `winmm.dll` (+ optional sound driver/apps as phase 2).
3. OpenGL: server libs → `opengl32.dll` → `glu32.dll` → atlantis demo.
   It rides the existing GDI engine, so it's well-scoped and self-contained.
4. Complete OLE2/COM.
5. Accessories / games / WinHelp as filler, each following the Plan A
   per-app recipe.
