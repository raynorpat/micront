# Plan: Migrate the NT 4.0 Task Manager into the 3.5 tree

Goal: bring the modern tabbed **Task Manager** (Applications / Processes /
Performance) from the NT 4.0 source into MicroNT, replacing — or sitting
alongside — the minimal NT 3.5 `taskman.exe`.

Source: `windows_nt_4_source_code_IK/nt4/private/windows/shell/sysmon`
(this is Dave Plummer's `taskmgr`, authored Dec 1995). C++ with precompiled
headers, `TARGETTYPE=PROGRAM`, UNICODE.

Source files: `main.cpp`, `procpage.cpp`, `perfpage.cpp`, `taskpage.cpp`,
`trayicon.cpp`, `ptrarray.cpp` (+ `precomp.h`, `taskmgr.rc`, icons/bitmaps).

## Why this is a *port*, not a copy

Unlike the 3.5 shell apps (which are same-era and link cleanly), this is a
later-era app dropped onto a 3.5 toolchain and API surface. Four real gaps,
established by inspection:

### 1. Library dependencies (`UMLIBS`)

| Lib | In 3.5 tree? | Source |
|-----|--------------|--------|
| kernel32, gdi32, user32, advapi32, ntdll | ✅ | built |
| mpr, user32p, uuid | ✅ | built |
| **comctl32** | ❌ | from `SHELL-APPS-PLAN.md` Tier 2 |
| **version** | ❌ | from `SHELL-APPS-PLAN.md` Tier 3 |
| **vdmdbg** | ❌ | WOW/16-bit task enum — see gap #4 |

So this plan **depends on the apps plan** delivering `comctl32` and `version`
first.

### 2. APIs missing in 3.5

- **`Shell_NotifyIcon`** is **not in the 3.5 `shell32`** (NT 3.5 has no
  system tray — Progman is the shell). `trayicon.cpp` cannot link.
  → **Drop `trayicon.cpp`** and the minimize-to-tray behavior (or stub
  `Shell_NotifyIcon` as a no-op).
- **`NtQuerySystemInformation`** info classes exist in 3.5 (`NTEXAPI.H` has
  `SystemProcessInformation`), **but the struct layouts differ between 3.5
  and 4.0** — `SYSTEM_PROCESS_INFORMATION` gained fields in 4.0. `procpage`/
  `perfpage` parse these directly. → **Reconcile the structs to the 3.5
  layout** — the core correctness work of this port.

### 3. comctl32 feature gap

The NT4 taskmgr uses property sheets (tab control), report-mode ListView with
extended styles, header, status bar, and toolbar. The 3.5 `SHELL/COMMCTRL` is
an **early** comctl32 and may lack some controls/messages/`LVS_EX_*` styles
the NT4 code calls. → **Audit comctl32 coverage** against what taskmgr uses;
backport the missing control bits or simplify the UI where a control is
absent.

### 4. Toolchain / build-system mismatch

- The `sources` file uses NT4 directives the 3.5 `MAKEFILE.DEF` may not
  understand: `NTLEANANDMEAN`, `INDENTED_DIRECTIVES`, `EXPECTED_WINVER=4.0`,
  `UMENTRYABS=ModuleEntry`, `USE_LIBCMT`, `PRECOMPILED_CXX`/`PRECOMPILED_PCH`.
- It expects a **VC4-era C++ compiler**; our tree uses MSVC 2.x `cl386`.
  `ptrarray.cpp` is a hand-rolled pointer array (no STL — good), but later C++
  idioms could still trip the older compiler.
- `INCLUDES` references `\nt\private\windows\inc16` (16-bit interop), which
  the 3.5 tree lacks. Only needed for the WOW path — **dropping gap #4's
  vdmdbg/WOW work also removes the inc16 dependency.**

→ Either rewrite `sources` in 3.5 style, or (safer) drive the build with a
manual `cl386`/`link` helper in `build.sh` (the pattern `build_mc` already
uses), so we control PCH and flags directly.

## Recommended strategy: trimmed MVP first

Port the three tabs that need no missing subsystem, **drop tray + WOW**:

- **Keep:** `main.cpp`, `taskpage.cpp` (Applications — top-level windows via
  `EnumWindows`/`GetWindowThreadProcessId`, all in 3.5), `procpage.cpp`
  (Processes), `perfpage.cpp` (Performance), `ptrarray.cpp`.
- **Drop:** `trayicon.cpp` (no `Shell_NotifyIcon`), the vdmdbg/16-bit WOW task
  enumeration inside `taskpage.cpp` (no `vdmdbg.lib`, no `inc16`).

This yields a working modern Task Manager with the three tabs, depending only
on libs the apps plan already builds.

## Steps

1. **Prereqs:** land `comctl32` (apps Tier 2) and `version` (apps Tier 3).
2. **Copy** `sysmon` → `src/NT/PRIVATE/WINDOWS/SHELL/TASKMGR`.
3. **Trim** per the MVP: remove `trayicon.cpp` from the build, `#ifdef`-out
   tray calls in `main.cpp`, and gate the WOW enumeration in `taskpage.cpp`.
4. **Reconcile `SYSTEM_PROCESS_INFORMATION`** (and any other queried info
   classes) to the 3.5 `NTEXAPI.H` layout so the Processes/Performance tabs
   read correct fields.
5. **Build wiring:** add `build_taskmgr()` to `build.sh`. Given the PCH +
   NT4-directive risk, prefer a manual `cl386 -c` (with `-Yu precomp.h`) +
   `link` helper modeled on `build_mc`, rather than the stock SOURCES path.
   Wire into `USERLAND_GUI_TARGETS` after `comctl32`/`version`.
6. **comctl32 audit:** build, fix link/runtime errors from any control or
   message the 3.5 comctl32 lacks (backport or simplify).
7. **Stage** `taskmgr.exe` into `mkdisk.py::_GUI_FILES`
   (`System32/taskmgr.exe`). Reachable via Progman → File → Run. Optionally
   replace the 3.5 `taskman.exe` staging.
8. **Verify:** launch; Applications lists windows; Processes lists processes
   with CPU/memory; Performance graphs update; End Task works.

## Open questions to confirm during the port

- Exact delta in `SYSTEM_PROCESS_INFORMATION` / `SYSTEM_PERFORMANCE_INFORMATION`
  between the 3.5 headers and what the NT4 code assumes.
- Whether the 3.5 comctl32 property-sheet + ListView API is rich enough, or
  needs backporting from the NT4 comctl32 (in the same NT4 source tree).
- Whether `cl386` (MSVC 2.x) compiles the `.cpp` as-is, or needs minor
  source massaging for the older compiler.

## Relationship to the other plans

- **Hard dependency** on `SHELL-APPS-PLAN.md` Tiers 2–3 (`comctl32`,
  `version`).
- Independent of the networking/DHCP plans.
- If full fidelity is later wanted: port `vdmdbg.lib` + `inc16` for the WOW
  "16-bit Tasks" view, and backport `Shell_NotifyIcon` into shell32 for the
  tray icon.
