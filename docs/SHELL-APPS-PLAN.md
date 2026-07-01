# Plan: Migrate the bare-minimum Windows shell apps

Goal: bring the classic NT 3.5 GUI applications — **Notepad, Task Manager,
File Manager (WinFile), Clock, and the Control Panel (launcher + Main applet)**
— from the leaked source disk into the MicroNT tree and wire them into
`build.sh` + the `gui` disk image.

Source disk: `/Users/raynorpat/Projects/NT782Source/SOURCE1B.782_disc1`
(everything below is under `PRIVATE/WINDOWS/SHELL` unless noted).

## Why this is mostly wiring, not porting

The whole Win32 window/drawing stack already builds: `USERLAND_GUI_TARGETS`
ends with `... shell32 comdlg32 winlogon userinit progman cmd`, and
`mkdisk.py::_GUI_FILES` already stages `progman.exe`/`cmd.exe`. Every app
below links only against libraries we already produce in
`PUBLIC/SDK/LIB/I386`:

> `kernel32 user32 user32p gdi32 advapi32 shell32 comdlg32 ntdll libc`
> + `userpri.lib`

All target apps are `TARGETTYPE=LIBRARY` + `UMAPPL=<name>` (or
`UMAPPL_NOLIB`), the exact pattern `build_progman` already handles via
`KEEP_UMAPPL=1 run_nmake ...`. Their include paths
(`WINDOWS/INC`, `PRIVATE/INC`, `SHELL/LIBRARY`, `SHELL/USERPRI`) already exist
in the tree.

## The per-app recipe (applies to every app)

1. **Copy source** `SOURCE1B/.../SHELL/<app>` → `src/NT/PRIVATE/WINDOWS/SHELL/<app>`.
2. **Add `build_<app>()`** in `build.sh`, modeled on `build_progman`:
   ```bash
   build_notepad(){ KEEP_UMAPPL=1 run_nmake "$NT_ROOT/PRIVATE/WINDOWS/SHELL/ACCESORY/NOTEPAD" "SHELL/NOTEPAD - notepad.exe"; }
   ```
   DYNLINK support libs (comctl32/version/t1instal/lz32/main.cpl) use
   `makedll=1` instead of `KEEP_UMAPPL=1`, like `build_comdlg32`.
3. **Wire** the target name into the `USERLAND_GUI_TARGETS` array, *after* its
   dependencies (and into `_dispatch_one`'s help text implicitly — it reads the
   array).
4. **Stage** in `mkdisk.py::_GUI_FILES` so it lands in the `gui` image, e.g.
   ```python
   ("System32/notepad.exe", OBJ("WINDOWS/SHELL/ACCESORY/NOTEPAD") / "notepad.exe"),
   ```

`OBJ(...)` resolves to `<dir>/obj/i386`. DYNLINK outputs (`comctl32.dll`,
`version.dll`, `lz32.dll`, `main.cpl`) land in `PUBLIC/SDK/LIB/I386`
(`SDK_LIB` in mkdisk), same as the other DLLs.

## Tier 1 — zero new libraries ✅

**Built and staged.** Notepad, Task Manager, Clock, and the Control Panel
launcher were copied under `SHELL/{ACCESORY/NOTEPAD,TASKMAN,ACCESORY/CLOCK,
CONTROL/CPANEL}`, wired via `build_{notepad,taskman,clock,control}` (all
`KEEP_UMAPPL=1`, appended to `USERLAND_GUI_TARGETS` after `progman cmd`), and
staged into `_GUI_FILES` as `System32/{notepad,taskman,clock,control}.exe`.
`./build.sh notepad taskman clock control` produces all four EXEs. Not yet
boot-tested. control.exe stays inert until Tier 3 supplies an applet.

Each is copy + 4 lines of wiring. No new `.lib` to build.

| App | Source dir | Output | Deps (all built) |
|-----|-----------|--------|------------------|
| Notepad | `ACCESORY/NOTEPAD` | `notepad.exe` | comdlg32, shell32 |
| Task Manager | `TASKMAN` | `taskman.exe` | user32, user32p, shell32, ntdll |
| Control Panel launcher | `CONTROL/CPANEL` | `control.exe` | shell32, userpri (`UMAPPL_NOLIB`) |
| Clock | `ACCESORY/CLOCK` | `clock.exe` | comdlg32, shell32 |

`control.exe` enumerates and launches `*.cpl` files — it is inert until
Tier 3 supplies `main.cpl`. Clock is the cheapest smoke-test of the whole
pipeline.

**Verify:** `./build.sh notepad taskman control clock` → EXEs appear in each
`obj/i386/`. Boot the `gui` disk, launch each via Progman → File → Run.

## Tier 2 — File Manager (+1 DLL) ✅

**Built and staged, but it was NOT "mostly wiring."** The `COMMCTRL` source on
the disk is a *newer* comctl32 (tab control, property sheets, full listview/
treeview) than the pre-tab-control public `commctrl.h` the tree was seeded
with, and it compiles against public headers that don't exist in usable form
on either leak disc. Making it build required real reconstruction:

- **Adopted the newer `commctrl.h`** — copied `SHELL/CHIPORT/MSCTLS/COMMCTRL.H`
  (a "daytona 612 + chicago b89" merge, purpose-built for this transition)
  over `PUBLIC/SDK/INC/commctrl.h`, then filled its gaps against this source:
  header hit-test (`HDM_HITTEST`/`HD_HITTESTINFO`/`HHT_*`), treeview
  (`TVE_ACTIONMASK`, `TVS_DISABLEDRAGDROP`, `TVIF_ALL`), listview
  (`LVM_GETITEMSPACING/GETSELECTEDCOUNT/SETITEMPOSITION32`, `LVFI_WRAP`,
  `LVSCW_*`, `NM_LISTVIEW.lParam`), tab (`TCM_GETCURFOCUS`, `TCS_FORCE*`),
  status (`SBARS_SIZEGRIP`, `SB_GETRECT`), toolbar (`TBNOTIFY`, `TBSAVEPARAMS`,
  `TBADDBITMAP` alias, `IDB_*`, `TBSTATE_WRAP`, `HINST_COMMCTRL`, `TB_*`),
  tooltips (`TTM_GETTOOLCOUNT/ENUMTOOLS`, `TTS_NOPREFIX`), updown
  (`UDM_DELTAPOS`), the whole animate control, `OVERLAYMASKTOINDEX`, and the
  `Animate_*` helper macros. The winuser-derived structs it bundles
  (`NMHDR`/`SCROLLINFO`/`STYLESTRUCT`/`NONCLIENTMETRICS`) are `#ifndef
  _WINUSERP_`-guarded so Unicode clients (winfile) that include `winuserp.h`
  don't get a redefinition.
- **Wrote `PUBLIC/SDK/INC/prsht.h` from scratch** — the property-sheet public
  header is absent from both discs (only the private `prshtp.h` ships).
  Reconstructed the `PROPSHEETPAGE`/`PROPSHEETHEADER` structs (incl. this
  version's `pfnRelease` + `PSP_IS16`), the `PSP_/PSH_/PSN_/PSM_/PSNRET_`
  constants, `ID_PSRESTART*`, and the three entry points.
- **Reconstructed missing private definitions in `COMMCTRL/{ctlspriv,daytona}.h`
  and a few `.c` fixes**: the retail debug NOPs (`DebugMsg`/`AssertMsg`/
  `Assert` + `DM_*`), the MRU API (`MRUINFO`/`MRU_*`/`MRUCMP*PROC` +
  prototypes), the `PHASHTABLE` forward decl, NT4 winuser bits used by the
  controls (`DS_3DLOOK/CONTROL/CONTEXTHELP`, `SS_SUNKEN`, `IDHELP`, `WS_EX_*`,
  `WM_SETTINGCHANGE/HELP/CONTEXTMENU/DEVICECHANGE/SETICON`, `DrawTextEx` +
  `DT_*`, `LoadImage`, `HELPINFO`), forward protos for `StrStrI`/
  `ImageList_LoadImage`, and `StrNCmpI`→`StrCmpNI`. A `CreateStatusWindowW`
  wrapper + `.def` fixups export the Unicode entry winfile imports.
- Changed `COMMCTRL/SOURCES` `TARGETPATH` to `public\sdk\lib` (like comdlg32)
  so `comctl32.dll`/`.lib` land in `SDK_LIB` for winfile to link + mkdisk to
  stage.

`build_comctl32`/`build_winfile` wired into `USERLAND_GUI_TARGETS`; both staged
in `_GUI_FILES`. Not yet boot-tested.

## Tier 2 — File Manager (+1 DLL): original notes

| Need | Source dir | Type | Flag |
|------|-----------|------|------|
| `comctl32.dll` | `COMMCTRL` | DYNLINK | `makedll=1` |
| **WinFile** | `WINFILE` | `winfile.exe` | `KEEP_UMAPPL=1` |

WinFile is the largest single app (~30 `.c` files) and the only Tier-1/2 app
needing common controls. Build `comctl32` first, then `winfile`. Stage both
(`comctl32.dll` + `winfile.exe`).

**Verify:** `./build.sh comctl32 winfile`; launch File Manager, browse the FAT
volume.

## Tier 3 — Control Panel applet (+4 libs)

The launcher is empty without an applet. `MAIN.CPL` (color, date/time, mouse,
keyboard, ports, fonts, international) pulls a small sub-chain. Build order:

| Need | Source dir | Type | Flag |
|------|-----------|------|------|
| `lz32.dll` | `LZ/LZEXPAND` | DYNLINK | `makedll=1` |
| `version.dll` | `VERSION` | DYNLINK | `makedll=1` |
| `prsinf.lib` | `WINDOWS/PRSINF` (not under SHELL) | LIBRARY | — |
| `t1instal.dll` | `CONTROL/T1INSTAL` | DYNLINK | `makedll=1` |
| **`main.cpl`** | `CONTROL/MAIN` | DYNLINK (`.cpl`) | `makedll=1` |

`main.cpl`'s `TARGETLIBS` references all four plus the already-built
user32/kernel32/advapi32/gdi32/comdlg32/shell32/libc + `userpri.lib`. Stage
`lz32.dll`, `version.dll`, `t1instal.dll`, and `main.cpl` (into
`System32/main.cpl`).

**Verify:** `./build.sh lz32 version prsinf t1instal main_cpl control`; launch
Control Panel, open the Color / Date-Time / Mouse applets.

## Suggested `USERLAND_GUI_TARGETS` insertion

Append after `progman cmd`, in dependency order:

```
# Tier 1 — no new libs
notepad taskman clock control
# Tier 2 — File Manager
comctl32 winfile
# Tier 3 — Control Panel applet
lz32 version prsinf t1instal main_cpl
```

## Phase 4 — Remaining Control Panel applets

Tier 3 builds `control.exe` + `main.cpl`. `control.exe` auto-discovers any
`*.cpl` in `System32` (plus those listed under the `MMCPL` registry/INI
keys), so adding an applet = build its `.cpl` + stage it into `System32`; no
launcher change needed. Each applet is `TARGETTYPE=DYNLINK` (mostly with
`TARGETEXT=cpl`) → build with `makedll=1`, same as `build_comdlg32`.

All applets live under `SHELL/CONTROL/<dir>`.

### Phase 4a — self-contained applets (no new subsystem)

| Applet | Source dir | Output | Notes |
|--------|-----------|--------|-------|
| Cursors | `CURSORS` | `cursors.cpl` | pointer scheme |
| Hardware Profiles | `PROFILE` | `profile.cpl` | |
| Display | `VIDEO` | `display.cpl` | resolution/color depth; reads video driver enumeration |
| UPS | `UPS` | `ups.cpl` | serial UPS monitor (in `OPTIONAL_DIRS`) |
| Screen Savers | `SCRNSAVE` (DIRS) | `*.scr` + framework | several savers under subdirs |

These pull only libs already built in Tiers 1–3 (user32/gdi32/shell32/
comdlg32/version/userpri). Stage each `.cpl` as `System32/<name>.cpl`,
screensavers as `System32/<name>.scr`.

### Phase 4b — multimedia-dependent applets (gated on Plan B)

These applets drive the audio/MCI stack, so they need `winmm.dll`/`msacm32`
from `MEDIA-PRINT-GL-PLAN.md` §2. **Do them only after multimedia builds.**

| Applet | Source dir | Output | Depends on |
|--------|-----------|--------|-----------|
| Sound | `SOUND` | `sound.dll` | winmm |
| MIDI Mapper | `MIDI` | `midimap.dll` | winmm |
| Multimedia | `MULTIMED` | `multimed.cpl` | winmm, msacm |
| Drivers | `DRIVERS` | `drivers.cpl` | winmm (installable-driver mgmt) |

Cross-reference: the Network applet (`ncpa.cpl`) is **not** part of this
plan — it comes with the networking work; see `NETWORKING-PLAN.md` §4.

## Disk staging vs. discoverability

`mkdisk.py` staging makes each `.exe` present on disk → immediately reachable
via **Progman → File → Run**. To get **program-group icons** instead, add
group/item entries in `mkhive.py` (or a shipped `.grp`). Recommended:
land binaries first (File→Run works at once), add icons as a follow-up.

## Execution order

1. Tier 1 (4 apps) — proves the pattern end to end.
2. Tier 2 (comctl32 → winfile).
3. Tier 3 (lz32/version/prsinf/t1instal → main.cpl → control panel).
4. Phase 4a (cursors/profile/display/ups/screensavers).
5. Phase 4b (sound/midi/multimed/drivers) — only after Plan B multimedia.
6. Optional follow-up: Program Manager group icons via `mkhive.py`.
