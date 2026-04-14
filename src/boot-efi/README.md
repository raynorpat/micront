# MicroNT UEFI Loader

A from-scratch gnu-efi PE32 loader that brings up NT 3.5 (x86) under OVMF-ia32 + QEMU. Follows the OSLOADER pattern: write KSEG0 pointers directly into NT structures — no post-paging fixup pass.

Targets: QEMU `-machine q35` with `OVMF32_CODE_4M.secboot.fd` firmware. No effort spent on bare-metal portability; behavior of real UEFI implementations is not in scope.

## Build + run

```sh
make            # builds BOOTIA32.EFI + esp.img
./boot.sh       # runs under QEMU, serial to stdio
GDB=1 ./boot.sh # same, but freezes CPU and listens on :1234 for gdb
./debug.sh      # one-shot: starts QEMU paused, runs gdb.script, captures
```

**Never run qemu directly** — use `boot.sh`. It sets the OVMF pflash vars, muxes COM1 + COM2 to stdio, handles `GDB=1` toggling, and keeps the logs in sensible places. Running QEMU by hand will diverge from what CI + GDB expect.

## High-level flow

`efi_main` (`main.c`) orchestrates:

1. **`com1_init`** — serial alive before anything else; every log line goes to COM1 so we can see what the loader did even after `ExitBootServices`.
2. **`fs_init`** — locate the ESP via `EFI_LOADED_IMAGE_PROTOCOL` on our own handle, then open the simple-file-system on that device.
3. **File reads** — `fs_read` pulls the kernel + HAL + boot drivers + SYSTEM hive into `AllocatePages`'d buffers, each tagged with a `PageKind`.
4. **NLS concat** — `fs_read_into` reads the three code-page files
   (`c_1252`, `c_437`, `l_intl`) into **one contiguous PK_NLS allocation**.
   This is not cosmetic: NT's `Phase1Initialization` computes
   `UnicodeCaseTableDataOffset = UnicodeCaseTableData - AnsiCodePageData` and indexes from the base (`NTOS/INIT/INIT.C:392`). If the three pointers aren't into the same contiguous block, Phase 1 will dereference a bogus VA computed via offset arithmetic.
5. **`pe_stage`** — parse each PE, alloc at `ImageBase & ~KSEG0_BASE` (via `mmu_alloc_at` — required for `/FIXED` images like `ntoskrnl.exe` with no `.reloc`), copy headers + sections, apply base relocations.
6. **`pe_resolve_imports`** — two-pass so `ntoskrnl <-> hal` circular imports resolve.
7. **`mmu_alloc_reserved`** — PD, per-alias PT pools, PCR, SUD, TSS, idle stack, GDT, IDT. Each tagged `PK_MEMORY_DATA` / `PK_PCR`.
8. **`loaderblock_build` + `loaderblock_wire_modules`** — arena-allocated `LOADER_PARAMETER_BLOCK` with KSEG0 pointers written in place.
9. **`memmap_capture`** — last UEFI allocation. MapKey is valid until the next `AllocatePages`/`AllocatePool`, so this MUST be the last UEFI service call before `ExitBootServices`.
10. **`loaderblock_link_memmap`** — pure arena writes, no UEFI calls.
11. **`ExitBootServices`** — point of no return. UEFI services are gone.
12. **`mmu_build_and_activate`** — populate the PD/PTs + GDT/IDT, `lgdt`, `lidt`, `mov cr3`, far-jmp into our segments.
13. **`handoff`** (asm) — switch to a KSEG0 stack alias, push the loader block, `call KiSystemStartup`.

## Memory layout at handoff

```
Virtual                      Physical (QEMU default 128 MB)
┌─────────────────────────┐
│ 0x00000000..0xFFFFFFFF  │  32-bit address space
│                         │
│ 0x00000000..0x0FFFFFFF  │  Identity map (low 256 MB)  — torn down by
│                         │  MiInitMachineDependent early in MM init.
│                         │
│ 0x80000000..0x8FFFFFFF  │  KSEG0 mirror of phys. **Only REGISTERED pages
│                         │  are mapped.** Blanket-mapping causes
│                         │  PFN_LIST_CORRUPT — see "The KSEG0 trap" below.
│                         │
│ 0xC0000000..0xC03FFFFF  │  Self-map (PDE[768] = PD). PTE_BASE + PDE_BASE.
│ 0xFFC00000..0xFFFFFFFF  │  HAL PT (PDE[1023]). PCR at 0xFFDFF000, SUD at
│                         │  0xFFDF0000.
└─────────────────────────┘
```

All NT structures the kernel reads go into a single arena
(`loaderblock.c`) whose phys base we register as `PK_MEMORY_DATA`. Pointers
are KSEG0-relative at write time — `kseg0_of(phys_ptr)` returns
`phys | KSEG0_BASE`. No post-paging fixup pass.

## The `mmu_alloc` registry

Every `AllocatePages` we make funnels through `mmu_alloc(pages, kind, &phys)`
and gets recorded in a fixed-size registry of `(phys, pages, kind)`. Two
downstream consumers need it:

1. **`memmap_to_nt`** — UEFI's memory map describes generic
   `EfiLoaderData` / `EfiBootServicesCode` regions. NT wants finer
   classification (`LoaderSystemCode`, `LoaderHalCode`, `LoaderBootDriver`,
   `LoaderNlsData`, etc.). The registry overlays `PageKind` onto the UEFI
   map so we emit correct NT memory types.
2. **`build_page_tables`** — KSEG0 maps exactly the registered pages.
   Anything not in the registry is invisible in KSEG0, which is what keeps
   free pages at `ReferenceCount == 0` during the kernel's PDE walk.

`mmu_alloc_at` (vs `AllocateAnyPages`) is used for `/FIXED` images. NT's
`ntoskrnl.exe` is built without relocations; it MUST land at physical
`ImageBase & ~KSEG0_BASE` (= `0x00100000`).

## The KSEG0 trap

**Blanket-mapping all physical RAM into KSEG0 breaks MM init.**

`NTOS/MM/I386/INIT386.C:457-498` walks every valid PDE, then every valid
PTE within each PT, and for each PTE that points at a page `<=
MmHighestPhysicalPage` does:

```c
Pfn2 = MI_PFN_ELEMENT(PointerPte->u.Hard.PageFrameNumber);
...
Pfn2->ReferenceCount = 1;
```

Then a **second** descriptor walk (`:572-594`) adds `LoaderFree` /
`LoaderFirmwareTemporary` pages to the free list — but only if
`Pfn->ReferenceCount == 0`:

```c
case LoaderFree:
case LoaderLoadedProgram:
case LoaderFirmwareTemporary:
case LoaderOsloaderStack:
    Pfn1 = MI_PFN_ELEMENT(NextPhysicalPage);
    while (i != 0) {
        if (Pfn1->ReferenceCount == 0) {
            MiInsertPageInList(MmPageLocationList[FreePageList], ...);
        }
        ...
    }
```

Map all of RAM in KSEG0 → every page has RefCount=1 after the walk → zero
pages reach the free list → `MiRemoveAnyPage` hits an empty list head →
`STOP 0x4E (PFN_LIST_CORRUPT)` with `arg3 = MmAvailablePages = 0`.

The fix is in `build_page_tables`: iterate the allocation registry and map
**only** those phys ranges in KSEG0. Free RAM stays unmapped, its PFN
entries stay at RefCount=0, and the descriptor walk can add them. The
identity mapping is still a blanket 0..256 MB — it only needs to survive
the CR3 swap + `jmp` into KSEG0, and the kernel unmaps PDE[0..511] early.

## The NLS-contiguity trap

NT's `Phase1Initialization` assumes the three NLS blobs are contiguous:

```c
// NTOS/INIT/INIT.C:389-397
InitNlsTableBase = LoaderBlock->NlsData->AnsiCodePageData;
InitOemCodePageDataOffset = OemCodePageData - AnsiCodePageData;
InitUnicodeCaseTableDataOffset = UnicodeCaseTableData - AnsiCodePageData;

RtlInitNlsTables(
    AnsiCodePageData,                                      // base
    (PUCHAR)AnsiCodePageData + InitOemCodePageDataOffset,  // = OEM if contig
    (PUCHAR)AnsiCodePageData + InitUnicodeCaseTableDataOffset, // = Unicode
    &InitTableInfo);
```

Three separate `AllocatePages` calls give you three arbitrary, non-adjacent
phys ranges → `UnicodeCaseTableDataOffset` is a bogus delta → 3rd arg to
`RtlInitNlsTables` lands on unmapped system-PTE space →
`STOP 0x50 (PAGE_FAULT_IN_NONPAGED_AREA)`.

`main.c` probes the three NLS file sizes, page-aligns each slab, allocates
**one** block, reads each file into its slot, and hands
`(base, ansi_off, oem_off, uni_off)` to `loaderblock_set_nls`.

## The contiguous-NLS + single-arena discipline

Both traps above have the same root cause: the kernel assumes adjacency wherever we gave it pointers computed via offset arithmetic. Two rules:

- If the kernel does `base + offset`, the data must be in one allocation.
- If the kernel walks a struct and follows a pointer, that pointer must be
  in a range we've mapped into KSEG0 (= in the registry).

## Debugging

### Reading NT bugcheck output

The bugcheck banner (`*** STOP: 0xNN ...`) from `KeBugCheckEx` + the module list is emitted on COM2 by the HAL. Both COM1 and COM2 are muxed to stdio in `boot.sh`, so scrollback has everything.

Common codes:

| Code | Meaning                               | Hints                                |
|------|---------------------------------------|--------------------------------------|
| 0x1E | `KMODE_EXCEPTION_NOT_HANDLED`         | arg1=exc_code, arg2=EIP, arg4=fault VA. Often flagged as `MM_NONPAGED_POOL_END` in some NT docs — it just means the kernel faulted and no handler caught it. |
| 0x4E | `PFN_LIST_CORRUPT`                    | arg3=`MmAvailablePages` — 0 means no pages reached free list. See "KSEG0 trap". |
| 0x50 | `PAGE_FAULT_IN_NONPAGED_AREA`         | arg1=VA. Often NLS-offset bug. See "NLS-contiguity trap". |
| 0xC0000005 | (as arg1 of 0x1E) Access violation | arg2 has the EIP of the faulting instruction. |

### gdb stub workflow

`./debug.sh` launches QEMU paused (`-s -S`) and drives gdb in batch mode via `gdb.script`. Typical uses:

- Break at a known code point (`break *0x80112ff6` = PE entry thunk) to
  verify you got there.
- Break at `$KeBugCheckEx` (from `ntoskrnl.gdb` generated by `pe2gdb.py`)
  to catch every bugcheck. Inspect `[esp+0..20]` for the call site + five
  params.
- Break just before a faulting instruction and inspect registers to see
  which data was wrong. For the STOP 0x1E at `0x801b3b29` example, we
  broke at `0x801b3b20` in a loop, dumped `eax` (DllBase) + `edi` (LDR
  entry) on each iteration to identify which module had the bad headers.

### Symbol lookup

`pe2gdb.py` produces `ntoskrnl.gdb` and `hal.gdb` from each PE's export table. Only exported symbols are there; internal static functions (KiTrap, MiReserveSystemPtes, many MM helpers) are not. For those, disassemble around the address and identify the function by its call pattern:

- `mov eax, fs:0x0` / `mov fs:0x0, esp` prologue → SEH-guarded routine.
- `cmp WORD [x], 0x5a4d` + `cmp DWORD [x+e_lfanew], 0x4550` →
  `RtlImageNtHeader`.
- `mov edi, DWORD PTR ds:0xXXXXXXXX` where the constant is a list head →
  walking `PsLoadedModuleList` or similar.

The nearest-exported-symbol gap tells you roughly where you are but won't name the static. Don't fight it; use the code shape.

### Layout assumptions

Check these when a bugcheck points at LPB dereference:

- `LDR_DATA_TABLE_ENTRY` offsets must match NT 3.5 (`NT/PUBLIC/SDK/INC/NTLDR.H`).
- `LOADER_PARAMETER_BLOCK` must match `NTOS/INC/ARC.H:1596`. The `union
  { I386_LOADER_BLOCK I386; ... }` at the end is the same offset for all
  arches; we just define the I386 variant directly.
- `MEMORY_ALLOCATION_DESCRIPTOR` is 20 bytes (LIST_ENTRY + enum + 2×ULONG).
- `NT_MEMORY_TYPE` enum values are load-bearing: `LoaderSystemCode=9`,
  `LoaderHalCode=10`, `LoaderBootDriver=11`, `LoaderStartupPcrPage=17`,
  `LoaderRegistryData=19`, `LoaderMemoryData=20`, `LoaderNlsData=21`.

## Files

| File               | Role                                                |
|--------------------|-----------------------------------------------------|
| `main.c`           | `efi_main` orchestrator                             |
| `com1.[ch]`        | Raw COM1 serial (post-ExitBootServices survival)    |
| `fs.[ch]`          | ESP reads: `fs_read`, `fs_read_into`, `fs_file_size` |
| `mmu.[ch]`         | Page alloc registry, PD/PT/GDT/IDT build            |
| `pe.[ch]`          | PE32 staging + import resolution                    |
| `memmap.[ch]`      | UEFI → NT memory descriptor translation             |
| `loaderblock.[ch]` | LPB arena + LDR entries                             |
| `nt.h`             | NT kernel structure layouts (no NT headers dragged in) |
| `handoff.S`        | Final asm: disable ints, switch stack, FPU init, call KiSystemStartup |
| `boot.sh`          | QEMU launcher, COM1+COM2 muxed, optional `GDB=1`    |
| `debug.sh`         | One-shot gdb session                                |
| `gdb.script`       | Scripted gdb commands for `debug.sh`                |
