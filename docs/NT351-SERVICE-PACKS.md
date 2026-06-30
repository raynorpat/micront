# Windows NT 3.51 — Service Pack History

Windows NT 3.51 shipped to manufacturing on **30 May 1995** (build **3.51.1057**).
It was the longest-lived NT 3.x release and received **five service packs**, which
delivered not only bug fixes but, unusually for the era, several genuinely new
**Win32 APIs** and hardware-support additions. NT 3.51 was also the first NT to
add **PowerPC** to the supported-architecture list alongside x86, MIPS, and Alpha.

Service packs are **cumulative**: SP5 contains every fix from SP1–SP4, so a clean
install only needs the latest pack. A separate **post-SP5 Year 2000 fix** was
issued later for sites that stayed on 3.51 past its mainstream life.

> **A note on sources.** As with NT 3.5, the complete per-pack `README.TXT`
> changelogs are only partially preserved. The SP5 README survives in full and
> documents the cumulative feature/fix set; the SP1–SP4 standalone changelogs are
> sparser in public archives. Entries below are reconstructed from the SP5 README,
> Microsoft KB references, and the Wikipedia/BetaWiki release record, and are
> marked where the precise per-pack attribution is uncertain.

---

## Release timeline

| Pack | Build | Released | Notes |
|------|-------|----------|-------|
| RTM  | 3.51.1057 | 30 May 1995 | Original release; first NT with NTFS file compression and PowerPC support |
| SP1  | 3.51.1057 | mid 1995 | First cumulative rollup (x86/Alpha/MIPS/PPC) |
| SP2  | 3.51.1057 | 11 Oct 1995 | Floppy and CD media |
| SP3  | 3.51.1057 | 14 Dec 1995 | Boot-disk media |
| SP4  | 3.51.1057 | 14 Mar 1996 | Boot-disk media |
| SP5  | 3.51.1057.6 | 23 Sep 1996 (some sources 19 Sep 1996) | Final pack; added new APIs; Y2K fixes |
| Post-SP5 Y2K | — | 03 Nov 1998 | Standalone Year 2000 update for sites still on 3.51 |

Architectures: **x86, MIPS, DEC Alpha, and PowerPC**. SP5 is the only pack archived
for all four; earlier packs survive most completely for x86.

---

## Service Pack 1

First cumulative rollup after the May 1995 release. Concentrated on the issues
that surfaced once 3.51 reached broad deployment:

- Early **networking** corrections (TCP/IP, WINS, NetBIOS, RAS).
- **NTFS** and **FAT** robustness fixes.
- **Printing** subsystem fixes.

The standalone SP1 README is not fully preserved; its content is carried forward
into SP2 and beyond.

---

## Service Pack 2

Cumulative rollup (released 11 October 1995) adding to SP1:

- Further **TCP/IP / NetBIOS / redirector** reliability fixes.
- **Printing** fixes for PostScript and HP LaserJet.
- **Services for Macintosh / AppleTalk** corrections.
- Driver fixes (SCSI, video, NIC).

A notable theme through SP2–SP4 was improving **PCMCIA / mobile hardware** support,
which mattered as NT 3.51 saw more use on laptops.

---

## Service Pack 3

Cumulative rollup (released 14 December 1995). Continued the networking, printing,
and file-system fix streams. Known specific fixes from this era include
font-rendering corrections (e.g. KB Q142696, the `GARAM4.TTF` TrueType display
fix) and additional Services-for-Macintosh printing fixes.

---

## Service Pack 4

Cumulative rollup (released 14 March 1996). More of the same: networking, printing,
file-system, and hardware-driver corrections, plus security and domain
trust-relationship fixes folded forward into SP5.

---

## Service Pack 5 — the definitive NT 3.51 pack

SP5 (build **3.51.1057.6**, September 1996) is the final and most significant
NT 3.51 service pack, and the recommended baseline. Beyond cumulating ~350+ fixes
from SP1–SP4, it is notable for **adding new functionality**, not just fixing bugs.

### New Win32 APIs introduced

> For full signatures, semantics, footguns, and rebuild notes on each of these,
> see the companion deep-dive: **[`docs/NT351-NEW-APIS.md`](./NT351-NEW-APIS.md)**.

- **Fibers** — lightweight, manually-scheduled units of execution within a thread:
  `ConvertThreadToFiber()`, `CreateFiber()`, `DeleteFiber()`,
  `GetCurrentFiber()`, `GetFiberData()`, `SwitchToFiber()`. This is the original
  introduction of the fiber primitive into Win32.
- **Winsock `AcceptEx()` / `GetAcceptExSockaddrs()`** — asynchronous connection
  acceptance that simultaneously retrieves the local/remote addresses and can
  receive the first block of data on accept. A key building block for
  high-performance server I/O.
- **`ReadDirectoryChangesW()`** — directory-change notification that returns the
  *full name* of each affected file (additions, modifications, renames, deletes),
  a significant improvement over `FindFirstChangeNotification()`, which only
  signalled that *something* changed.

### Other additions

- **`ROUTE.EXE`** gained a `METRIC` parameter, allowing a cost/hop-count to be
  associated with a route entry.

### Bug-fix categories (cumulative through SP5)

- **Networking:** TCP/IP, NetBIOS, WINS, DHCP, RAS, and NetWare connectivity.
- **Printing:** PostScript, HP LaserJet, and Macintosh printing.
- **File systems:** NTFS directory corruption (notably with 100,000+ files in a
  directory), partition corruption in Disk Administrator, FAT access violations,
  and disk-space detection failures.
- **Services:** FTP, DHCP, Netlogon, and Exchange compatibility.
- **Security:** authentication and domain trust-relationship fixes.
- **Hardware:** video drivers, SCSI adapters, network interface cards, and
  PCMCIA support.
- **Services for Macintosh / AppleTalk** compatibility.
- **Internet Information Server (IIS):** SSL, CGI, and performance fixes.
- **Year 2000:** initial Y2K date-handling corrections (extended further by the
  later standalone post-SP5 Y2K update).

---

## Post-SP5 Year 2000 update

Released **3 November 1998** as a standalone fix for organisations that remained on
NT 3.51 past its mainstream support. It addressed remaining Y2K date-rollover
issues not covered by SP5 itself.

---

## Practical guidance (for a from-source rebuild)

- Treat **3.51 + SP5** as the reference target — it is the most complete, the only
  one archived across all four CPU architectures, and the only pack that adds the
  fibers / `AcceptEx` / `ReadDirectoryChangesW` APIs.
- If the goal is to match a *specific* historical configuration, remember the
  build string stays `3.51.1057` through SP4 and only moves to `3.51.1057.6` at
  SP5 — earlier packs are distinguished by the service-pack registry marker and
  patched binaries, not the kernel build number.
- The new SP5 APIs are relevant if any rebuilt component or test relies on
  fibers or `ReadDirectoryChangesW`; on an RTM-through-SP4 base those entry
  points do not exist.

---

## Appendix — Fixed issues (official KB references), grouped by service pack

The lists below are transcribed from the official Microsoft README that shipped with
**SP5** — **KB Q128531** ("README.TXT: Windows NT Version 3.51 U.S. Service Pack").
Because SP5 is cumulative, its README enumerates every fix back to SP1 and, unlike
the NT 3.5 README, **groups them by the service pack that introduced each fix**. That
grouping is preserved here. Each entry is a Microsoft Knowledge Base "Q number"
that can be looked up in KB archives such as `jeffpar.github.io/kbarchive`.

(A handful of Q numbers appear under more than one pack in the original README —
e.g. a fix first shipped, then revised — and are listed under each as Microsoft did.)

### Service Pack 1

| Q number | Issue |
| --- | --- |
| Q128453 | Windows NT 3.51 hangs (memory access violation) running Exchange |
| Q128454 | Windows NT 3.51 hangs with Office 95 (Word) Help File Wizard |
| Q130093 | Err Msg: Incorrect response from the network |
| Q130292 | Windows NT Win16 subsystem crashes printing from Quicken 4.0 |
| Q130677 | TCP/IP generates frames with loopback address as source address |
| Q131343 | "Invalid Page Fault" running Office 95 Help Wizard |
| Q131427 | Windows NT 3.51 TCP/IP system network interface hang |
| Q131683 | Help file opens very slowly with Office 95 applications |
| Q131779 | Help fails for VB modules in Excel |
| Q131865 | SMC Elite Ultra NIC causes UNIX computers to disconnect TCP/IP |
| Q132198 | Middle mouse button does not work under Windows NT 3.51 |
| Q132466 | Problems printing from DCA IRMA Workstation for NT 1.1 |
| Q132470 | STOP 0x0000000A or 0x0000001E when using PING |
| Q132858 | PowerStack with Cirrus video adapter hangs during startup |

### Service Pack 2

| Q number | Issue |
| --- | --- |
| Q112665 | UPDATE.EXE starts Setup Help if space exists in directory path |
| Q128567 | Landscape orientation reversed with PostScript driver |
| Q129670 | GSNW not releasing session to NetWare server |
| Q129724 | Macintosh client has slow access to Windows NT 3.5x SFM volume |
| Q130226 | Banner always printed when using GSNW print gateway |
| Q130783 | STOP 0x0000003F NO_MORE_SYSTEM_PTES repetitive I/O on MIPS |
| Q130932 | Desktop remains active at logoff |
| Q130979 | User environment variables set before default home directory |
| Q131073 | Datagram sends fail if route is not in IPX cache |
| Q131241 | FTPSVC orphans connections, uses up virtual memory |
| Q131428 | DHCPADMN reports Error 14 after you select local machine |
| Q131689 | PostScript jobs do not print correctly over SFM and AppleTalk |
| Q132085 | Applications hang when opening files when CSNW is installed |
| Q132394 | Streaming-mode NPMCA.SYS NIC sleeps on transmit |
| Q132511 | Windows NT 3.51 hangs on shutdown with some S3-based video cards |
| Q132722 | Server instability after reboot caused by NDIS driver problem |
| Q132896 | FTP client scripts terminate without completing |
| Q132903 | Err Msg using NetBIOS over TCP/IP (NETBT.SYS): STOP 0x0000000A |
| Q133112 | NetWkstaSetUid2 API returns Access Denied |
| Q133128 | Printing from Windows NT 3.51 to an HP4 at 600 DPI is slow |
| Q133252 | Windows NT 3.51 GSNW Help reports the file is corrupted |
| Q133280 | FTPSVC: delay receiving FTP directory annotation and prompt |
| Q133303 | WINFILE.EXE application error when associating a searched file |
| Q133306 | Maximum disk space of 1.99 GB displayed for NetWare volume |
| Q133384 | Event ID 2019: nonpaged memory pool empty |
| Q133410 | The breakpoint "{,<filename>,} .<line>" cannot be set |
| Q133488 | LPR printing fails after setting up security |
| Q133701 | Forward slash may be ignored as a path delimiter in 3.51 |
| Q133757 | Performance Monitor SQLServer-Log object corrupted |
| Q134250 | No Compaq Netflex drivers in Windows NT 3.51 for RISC platforms |
| Q134285 | STOP 0x0000007B or "0x4,0,0,0 Error" in WinNT 3.51 Setup |
| Q134286 | Windows NT 3.51 LsarLookupSids errors from big-endian servers |
| Q134386 | Computers using QVision display driver lock up |
| Q134427 | Dr. Watson access violation occurs sending mail attachments |
| Q134701 | Uninitialized pointers in DHCPSSVC.DLL cause access violation |
| Q134765 | Unknown software exception when application calls OpenGL |
| Q134959 | Cannot copy icons from a common group to a personal group |
| Q134968 | NetWare connections remain connected after you log off |
| Q134969 | Faxing from 16-bit program using separate memory space fails |
| Q134985 | Browsing & other traffic incur high costs over ISDN routers |
| Q134988 | Access violation in glsbCreateAndDuplicateSection API on PowerPC |
| Q135065 | Windows NT 3.51 hangs on shutdown |
| Q135275 | Windows NT Backup: incorrect date in "Tape Name" text |
| Q135277 | WINS records of multi-homed computers do not replicate |
| Q135291 | Print Manager: owner appears as System printing from Macintosh |
| Q135308 | Disk Administrator corrupts partitions |
| Q135471 | Cannot reconnect to OS/2 name space resources on NetWare server |
| Q135548 | PIF Editor reserve shortcut keys settings may be ineffective |
| Q135553 | IOCTL_NDIS_QUERY_ALL_STATS causes STOP msg in Windows NT 3.51 |
| Q135621 | NetWare Transaction Tracking System (TTS) not detected |
| Q135667 | STOP 1E when using File Manager and Services for Macintosh (SFM) |
| Q135692 | "List Names From" list box shows only 20 trusted domains |
| Q135724 | Deleted disk space not released on converted NTFS volume |
| Q135774 | Performance Monitor counters produce unlikely results |
| Q135777 | Unable to connect using Cabletron EISA F70XX FDDI NIC |
| Q135856 | RIP table does not update when new RIPX response is received |
| Q136023 | Batch files stop executing with Windows NT version 3.51 |
| Q136024 | Tape hardware data compression disabled after running NTBackup |
| Q136334 | Access violation in LSASS.EXE during user password change |
| Q136336 | Windows NT fails because of an access violation in WINLOGON |
| Q136375 | NTFS directory corruption with more than 100,000 files |
| Q136402 | IniFileMapping for 16-bit Windows apps fail in Windows NT 3.51 |
| Q136472 | NE3200 NIC driver can lose locally administered address |
| Q136627 | Layered drivers never see WINSOCK IRPs for the TCP/IP device |
| Q136780 | WinFax Pro software causes 16-bit applications to hang |
| Q136782 | Unable to connect to AT&T Advanced Server for UNIX printer share |

### Service Pack 3

| Q number | Issue |
| --- | --- |
| Q126688 | Stack overflow with Windows NT 3.51 RAS |
| Q126689 | STOP c000021a logging on a second time to WinNT 3.51 w/ SP2 |
| Q126967 | New TCP/IP registry parameter ignores Push bit on receives |
| Q139281 | STOP 0x0000004E or 0x0000000A under heavy computer usage |
| Q139535 | Some TrueType fonts do not produce glyphs on Windows NT 3.51 |
| Q139635 | RAS authentication of third-party PPP SPAP clients fail |
| Q139714 | RAS STOP 0x0000000A 6194ea98 00000002 00000001 80115534 |

### Service Pack 4

| Q number | Issue |
| --- | --- |
| Q134959 | Cannot copy icons from a common group to a personal group |
| Q137857 | Errorlevel paradigm behaves differently in Windows NT 3.51 |
| Q137968 | Perfmon and Network Monitor counters show incorrect values |
| Q138415 | Windows NT fails to check for low disk space (no admin alerts) |
| Q138700 | ARP -s fails after applying SP2 to Windows NT 3.51 |
| Q138737 | Directory synchronization may fail with Windows NT 3.51 Mail |
| Q138794 | Out of memory error installing Windows NT 3.51 Service Pack 2 |
| Q138854 | Connecting using NBT.SYS causes Windows NT session to hang |
| Q138987 | Novell clients are denied access logging on to FPNW servers |
| Q138995 | Updating to WinNT 3.51 SP2 causes loss of persistent IP routes |
| Q139015 | Trap 0xA in ExFreePool of NTOSKRNL.EXE |
| Q139057 | NET STOP WINS fails to stop WINS service |
| Q139058 | Battery shutdown signal delayed using Windows NT UPS service |
| Q139065 | Services for Macintosh on Windows NT 3.51 Service Pack 2 hangs |
| Q139171 | Compaq system hangs with incomplete IRP in Cpqarray |
| Q139207 | S3 driver doesn't correctly support 72Hz on some IBM PS/2 models |
| Q139208 | Instability in RAS using TAPI X25 Ndiswan driver |
| Q139274 | Updated system environment variables result in STOP 0x0000021a |
| Q139338 | WINS counters disappear from Performance Monitor |
| Q139350 | WinNT GP fault exiting 16-bit Access version 2.0 |
| Q139351 | STOP c000021a — using mandatory profile w/o access rights |
| Q139380 | Multi-homed WINS server replication partner failures |
| Q139415 | New TCP/IP ArpCacheLife parameter in Windows NT 3.51 |
| Q139494 | Multiple CRC errors and hardware overruns using RAS |
| Q139619 | Printing from a service to a network printer fails |
| Q139649 | Windows NT service can't connect to network printer on 3.51 |
| Q139691 | International characters in user names not handled properly |
| Q139929 | SNMP queries of very long OIDs may cause SNMP service to hang |
| Q139956 | RPC from a big-endian computer causes GP fault |
| Q139985 | WINS client fails to reach a multi-homed server |
| Q140008 | Seed routing network range options grayed out with DEC FDDI |
| Q140258 | Incomplete server list in File Manager's connection dialog box |
| Q140329 | Trust relationships fail with large number of trusted domains |
| Q140364 | Registry size limit change results in PagedPoolSize change |
| Q140400 | GSNW/CSNW creates 8.3-format directory names in uppercase only |
| Q140408 | Access Denied attempting to rename file across the network |
| Q140463 | SNMP agent hangs on very long queries |
| Q140506 | Print jobs sent to SFM printer hang in spooler after printing |
| Q140603 | SNMP trap frames appear to be dropped |
| Q140639 | Daylight saving time not advancing |
| Q140675 | Windows NT doesn't show all files on OS/2 server |
| Q140685 | Mac clients get Access Denied on newly created folders |
| Q140783 | Access violation on RAS client dialing into Windows 95 |
| Q140784 | Call to NetUserGetLocalGroups results in NERR_UserNotFound |
| Q140818 | STOP message after "DIR ..\" is issued from a Samba client |
| Q140973 | Inaccessible floppy disk drive on Toshiba Portege 610CT |
| Q140978 | WINS does not replicate <1c> names properly |
| Q141019 | SNMP debug messages are written to event log |
| Q141156 | STOP 0x0000000A in SFMATALK.SYS after receiving ATP packet |
| Q141344 | Network connections refused over NetBT |
| Q141371 | STOP 0x0000000A from DLC.SYS |
| Q141467 | Macintosh RPC client fails across AppleTalk zone |
| Q141520 | Generic Text driver prints control characters and blank lines |
| Q141732 | Adaptec AHA154x driver fails to install second adapter |
| Q141753 | Memory violation running Attachmate Extra! for Windows in WOW |
| Q142060 | BackupExec 6.0 not backing up WfW in Windows NT 3.51 SP3 |
| Q142204 | CSNW drive mappings incorrect |
| Q142371 | Perfmon counter DISK QUEUE LENGTH gives incorrect report |
| Q142695 | SP3 localized SERVER.HLP (online books) causes Dr. Watson error |
| Q142696 | WinNT 3.51 SP3 GARAM4.TTF font not displayed properly |
| Q142697 | Unlocked workstation not returned to full-screen application |
| Q142698 | Service pack overwrites localized version of Windows NT |
| Q142699 | WinNT 3.51 w/ CPU maxed prints very slowly to banding printers |
| Q142700 | WinNT 3.51 SP2 SFM share can only be created on NTFS |
| Q142701 | SAM does not replicate members of the Administrators alias |
| Q142704 | Windows NT Mail client does not handle long filenames correctly |
| Q142708 | WinNT 3.51 SP2 w/ UK keyboard gives wrong accented characters |
| Q142709 | Big files copy slowly from Mac to SFM over AppleTalk router |
| Q142710 | Lock violation opening NetWare server file w/ shareable bit set |
| Q142711 | Windows NT hangs on Alpha with > 1 GB system memory |
| Q142714 | RAS does not hang up immediately if usernames are different |
| Q142866 | Alpha computer w/ Proteon P139x-Plus Revision J NIC doesn't work |

### Service Pack 5

| Q number | Issue |
| --- | --- |
| Q126967 | New TCP/IP registry parameter ignores Push bit on receives |
| Q129129 | Windows NT SNMP agent allows only read access |
| Q130876 | Printing through HPMON(DLC) may cause print subsystem to hang |
| Q135609 | WINS fails on RAS server with multiport adapter installed |
| Q135692 | "List Names From" list box shows only 20 trusted domains |
| Q135700 | Modifications to NETBT.SYS to support layered drivers |
| Q137155 | Users without System32 permissions cannot log on |
| Q137522 | FPNW keeps directory handles open, preventing deletion |
| Q138222 | DHCP server delays release of client-rejected IP addresses |
| Q138244 | Printing fails with "RPC procedure call failed" |
| Q138257 | Inconsistent print results using HP LaserJet 5L |
| Q138713 | Err Msg: Driver entry point not found after service pack upgrade |
| Q138792 | TCARC.SYS causes Trap 0xA or hangs Windows NT |
| Q140641 | Updated SAMSRV.DLL supports AppleTalk and Banyan Vines clients |
| Q140891 | Remote shutdown may fail |
| Q141118 | No FPNW "NetWare Compatible Password Expired" check box |
| Q142608 | Windows for Workgroups fails to print to Apple IIG through NTS |
| Q142610 | Err Msg: OS Loader V3.51 TRAP 0000000E PAGE FAULT |
| Q142611 | WOW: GP fault in DDEML.DLL using Visual Basic application |
| Q142612 | TrueImage errors 4041 when printing from a Macintosh |
| Q142613 | System Control application shows Insufficient Memory dialog box |
| Q142615 | Event Log service fails to check access to security log file |
| Q142617 | Server rejects TreeConnectAndX and DirectorySearch SMB |
| Q142620 | Access violation in Nwsvc.exe |
| Q142621 | OS/2 application does not return DOSREADQUEUE properly |
| Q142622 | Repeated automatic logons in Windows NT may fail |
| Q142623 | Encryption keys of 768 & 1024 bits unavailable in int'l WinNT |
| Q142624 | Err Msg: "Unable to connect to target machine" |
| Q142625 | NetBIOS defaults to 16 sessions on Windows NT |
| Q142626 | LogonUser API now has support for network logons |
| Q142627 | NTDETECT.COM incorrectly detects some S3 video controllers |
| Q142628 | STOP 0x23 errors in FASTFAT.SYS |
| Q142630 | NTFS with full logfile condition may cause trap |
| Q142631 | Internet Information Server directory access issue resolved |
| Q142645 | FPNW stops w/ Win3.x client directory search: "\*\*\*\*..." |
| Q142646 | Upgrading to SP4 can overwrite newer versions of OLEAUT32.DLL |
| Q142647 | Callback field for RAS may not be viewable from Rasadmin.exe |
| Q142648 | STOP 0x00000024 in NTFS.SYS |
| Q142649 | STOP 0x0000000A on ALR Revolution |
| Q142650 | Netlogon stops when mailslot message is larger than specified |
| Q142651 | Third-party cursor hangs Cirrus driver |
| Q142680 | Modification to support Direct Host IPX acceleration drivers |
| Q142874 | Services for Macintosh reports incorrect free volume space |
| Q142880 | NetBT fails to bind to a large number of IP addresses |
| Q143143 | Error printing from Macintosh to LPT port of Windows NT Server |
| Q143329 | Serial mouse does not work on a DEC Alpha computer |
| Q145623 | Access violation in LSASS.EXE on primary domain controller |
| Q145796 | Print Manager displays Macintosh EPS document as file name |
| Q146114 | Heavy load of FTP service results in access violation |
| Q146880 | Logon/logoff events logged out of order in security log |
| Q146905 | Remote pipe DosWaitNmPipe to OS/2 subsystem gives Error 123 |
| Q147204 | STOP 0x0000000A in NDIS.SYS on a multi-processor computer |
| Q147246 | Using Direct Hosting over IPX causes STOP 0x0000000A |
| Q147349 | No sound on some PCMCIA modems in Windows NT 3.51 |
| Q147372 | Problem using full tape backup requiring more than one tape |
| Q147458 | End of media crossing during Windows NT tape backup |
| Q147601 | Problem switching from Office 95 to 16-bit application window |
| Q147642 | NetWare files overwritten when updating to Windows NT 3.51 SP4 |
| Q147661 | MSMail32 message with hyphens results in access violation |
| Q147695 | MEMBER OF in FPNW login script returns incorrect results |
| Q147697 | Turning off auditing of security policy changes not audited |
| Q148174 | NWCONV.EXE does not give correct permissions |
| Q148188 | Internet Information Server security .CMD / .BAT patch |
| Q148353 | Access Denied using CHGPASS with DSMN |
| Q148485 | Service Pack 4 causes some installation programs to fail |
| Q148487 | MS-DOS "For" command fails when run against an FPNW server |
| Q148501 | Preventing PCI resource conflicts on Intel-based computers |
| Q148646 | STOP 0x0000000A when referencing empty Sent queue |
| Q148845 | Access violation in RASMAN.EXE under Windows NT 3.51 |
| Q148846 | RAS port instance names in Performance Monitor are corrupted |
| Q148929 | Security Event ID 642 logged incorrectly for audits |
| Q148939 | DHCP server creates unnecessary lease |
| Q148957 | NTBACKUP fails with application error during verify process |
| Q149112 | Some image maps do not work with IIS |
| Q149167 | Unable to allocate resources from the NDIS wrapper |
| Q149214 | Windows NT Server stops responding to Macintosh clients |
| Q149293 | File Manager cannot view permissions after NWCONV.EXE is run |
| Q149344 | NWCONV.EXE does not correctly apply permissions |
| Q149393 | CrashOnAuditFail activates on shutdown with ProcessTracking |
| Q149394 | CTRL+BREAK does not work for 16-bit applications |
| Q149395 | STOP 0x0000001E in RDR.SYS caused by corrupted SMBs |
| Q149468 | CSNW clients may cause Clipper index corruption |
| Q149525 | Poor performance may occur during FTP file transfers |
| Q149528 | FTP client uses only one IP address on multihomed workstations |
| Q149532 | Windows NT clients run out of ports |
| Q149534 | Windows NT socket apps run out of ports |
| Q149559 | FPNW LOGIN.EXE doesn't handle password expiration |
| Q149643 | Printing to NetWare deallocates directory handle |
| Q149722 | Windows NT registry has a limit of 300 interfaces |
| Q149819 | RPC causes Exchange Server to hang all connected clients |
| Q149857 | MoveFileEx API does not work after applying SP4 |
| Q149891 | Programmatic system shutdown fails |
| Q149949 | Some browsers may fail to connect when IIS uses SSL |
| Q149955 | Random users do not appear in SYSCON viewed w/ FPNW server |
| Q150008 | DOS applications receive wrong error code in FPNW |
| Q150009 | WinNT system shutdown/power off causes boot-sector corruption |
| Q150047 | NetWare drives inaccessible to CIM and MMTA |
| Q150048 | SYSCON changes maximum password age on FPNW server |
| Q150059 | Cannot perform a NET VIEW across RAS to Windows 95 client |
| Q150060 | Cannot delete directory structure on FPNW volume |
| Q150097 | cc:Mail clients lock up through FPNW |
| Q150124 | Cannot access CD-ROM after installing SP4 |
| Q150140 | STOP 0xC000021A as application terminates |
| Q150152 | Printing from Mac to HP 3x with 52.2 HP PostScript cartridge |
| Q150158 | NTFS: directory changes reported to LMREPL erroneously |
| Q150172 | FPNW will not create file larger than 2.14 GB |
| Q150275 | Redirector doesn't close the session after user logs off |
| Q150302 | Overlapped I/O to tape results in data corruption |
| Q150305 | DEC FDDI adapters fail to respond to broadcasts |
| Q150337 | Simultaneous Dr. Watsons stop Windows NT |
| Q150350 | NetLogon maximum value of Pulse should exceed 3600 |
| Q150355 | Windows NT nonresponsive during NTFS directory traversal |
| Q150410 | Having 300+ print queues causes access violation in Localmon |
| Q150508 | Netscape clients hang while posting data to SSL forms on IIS |
| Q150559 | New Windows NT TCP/IP registry parameter: ArpTRSingleRoute |
| Q150729 | Err Msg: "Access Denied" when using Account Operator |
| Q150736 | Stopping SNA Server service leads to perpetual stopping state |
| Q150823 | Trap 0xA when Token Ring source routing data exceeds 18 bytes |
| Q150831 | STOP 0x0000000A in NBF.SYS when running under stress |
| Q150833 | Memory deallocation failure in SRV.SYS directory notification |
| Q150838 | NWLNKSPX may reset connection with out-of-sequence packet |
| Q150847 | File Manager truncates long file names containing spaces |
| Q150904 | DDE link stops updating after closing another link |
| Q150918 | FPNW Event ID 2630 unable to access PDC for write |
| Q150938 | Printer-resident fonts not available w/ "Print Text as Graphics" |
| Q150996 | Session canceled error using IBM 16/4 adapter II |
| Q151007 | IBM ThinkPad drives have problem w/ read/write and media change |
| Q151008 | Sony 7000 and DEC TZ09 4mm DAT not supported under 3.51 |
| Q151010 | IIS IDC: Err Msg: Error performing query |
| Q151183 | WWW clients using Basic authentication may fail with IIS 1.0 |
| Q151216 | NTVDM may leak memory when opening/closing COMM ports |
| Q151222 | STOP 0xA in FLNK.SYS while copying from FPNW server |
| Q151226 | FPNW grace logins are not reset when password is changed |
| Q151235 | FPNW does not search trusted domains for object names |
| Q151259 | New Netlogon registry entry for dialup routers |
| Q151306 | WINS partner registry settings may be deleted |
| Q151432 | Invalid file handle with SP4 Nwrdr.sys |
| Q151448 | Trap 0x50 and Trap 0xA under heavy stress |
| Q151453 | Netscape 2.01 clients hang while getting SSL pages w/ graphics |
| Q151471 | Processes do not respond when NTFS encounters an error |
| Q151714 | WinNT RPC client may fail against DCE server |
| Q151824 | FoxPro query may return inaccurate results with FPNW |
| Q151962 | System appears to stop when adding users to large global groups |
| Q151977 | FPNW not responding correctly to record locking and logging |
| Q151989 | Novell 32-bit client for Win95/WinNT doesn't see FPNW volume |
| Q151991 | FPNW writes incorrect last-modified date on files from OS/2 |
| Q151997 | DECMON can cause Spoolss to generate an access violation |
| Q152051 | IBM Gothic Box font appears garbled |
| Q152121 | Windows NT logon to NetWare is slow & causes Event 8007 errors |
| Q152156 | Access violation in client process during authenticated RPC |
| Q152270 | CreateProcessAsUser() fails after applying Service Pack 3 |
| Q152271 | EnumServicesStatus() results in Services.exe memory leak |
| Q152272 | GetSecurityDescriptorGroup() returns incorrect primary group |
| Q152273 | DHCP server may give out duplicate IP addresses |
| Q152304 | Random blue screens caused by bad packet and DLC.SYS |
| Q152348 | Block writes across net may cause performance hit |
| Q152398 | Login.exe now sets primary server after successful login |
| Q152428 | Initialization failure in Rasman.dll when shutting down |
| Q152448 | Mouse cursor freezes intermittently in Windows NT |
| Q152450 | Change Password dialog text changed for NetWare |
| Q152474 | Windows Socket application failure with Connection Reset event |
| Q152547 | GP fault in Windows NT VDM when using SCROLL_LOCK/UNLOCK key |
| Q152589 | Netscape 2.01 clients hang while getting SSL pages w/ graphics |
| Q152625 | Ibmtok.sys generates event message ID:5002 error |
| Q152705 | Multihomed WINS servers send name query responses |
| Q152719 | WAN and trust: traffic on the wire |
| Q152837 | ControlService() results in Services.exe memory leak |
| Q152986 | CSNW does not report directory restrictions |
| Q152992 | Netlogon service does not start after applying SP4 |
| Q153157 | WNetGetUser returns ERROR_NOT_CONNECTED |
| Q153202 | Duplex printing causes problems after applying SP4 |
| Q153237 | File Manager unable to copy long file names to write-only volume |
| Q153332 | Echo command in a batch file does not echo /Q |
| Q153462 | Err Msg: Event 4010: unable to get the local computer name |
| Q153504 | PCL5EMS does not support all memory available on HP LJ 5Si MX |
| Q153596 | TCP/IP performance degrades when resuming large data transfer |
| Q153665 | SPX data stream type header may reset unexpectedly |
| Q153666 | Updated TCP/IP printing components for Windows NT 3.51 |
| Q153706 | WINS service terminates during replication |
| Q153949 | CSNW does not support MS-DOS name space correctly |
| Q153953 | Log On Locally permission not required for client access |
| Q153993 | Windows NT may cache data even if write-through flag is set |
| Q154067 | System Error: the Win16 subsystem was unable to allocate memory |
| Q154090 | Installing too many OLE applications may cause system to lock |
| Q154117 | No drive letter when using PC-Card Type III slot |
| Q154145 | SSL: ISAPI secure transmissions limited to 32K of data |
| Q154175 | Users may lose designated default printer after multiple logins |
| Q154183 | CreateFile API with delete-on-close option may fail |
| Q154355 | How to tune trusts for dialup routers in a WAN |
| Q154444 | EPS files larger than page fail to print |
| Q154485 | Disabling keep-alive connections in IIS 1.0 |
| Q154563 | FPNW search drive vector not set |
| Q154564 | Access Denied using CHNGPASS when logged on to FPNW |
| Q154688 | DPT PCI-SCSI fails on PPC if IRQ greater than 15 |
| Q154700 | HALMCA does not check for PCI |
| Q154783 | Msg sent from MSMail Windows NT client undeliverable |
| Q154784 | Windows NT operating system SNMP OID incorrect |
| Q154785 | WinNT 3.51 service packs incorrectly update newer SPs |
| Q154790 | Weitek PCI video fails to load on PowerPC secondary PCI bus |
| Q154797 | SP5 adds code pages for Central European language support |
| Q154799 | Update.exe in 3.51 service packs may use wrong Patchdll.dll |
| Q154832 | Disabling thread creation for CGI I/O in IIS 1.0 |
| Q154833 | Automatic logoff after screen saver fails |
| Q154841 | Problem connecting to Xylogics Annex-3 terminal server |
| Q154845 | Bugcheck in Fastfat.sys |
| Q154846 | AP error running Gdsset.exe in Japanese IIS |
| Q154847 | WINMSD may not report correct service pack version |
| Q154854 | Trap 0xA in AtalkBPFreeBlock |
| Q154862 | Web browsers may fail when accessing SSL secure pages |
| Q154865 | Datatype misalignment in inetsloc |
| Q154933 | Err Msg: The LsaCreateSecret call failed |
| Q154938 | Bugcheck 0xA — saving 64K file to NetWare in Notepad |
| Q154939 | CreateQueueJobAndFile fails w/ queues other than print queue |
| Q154942 | IIS virtual root cannot be browsed on a SAMBA or Win95 share |
| Q154944 | PowerPC (PPC) only: OldIrql is stored before spinlock |
| Q154945 | FlushFileBuffers not committing filesize properly in NT3.51 SP4 |
| Q154946 | Bugcheck 93 in the RDR |
| Q154948 | S3.sys driver does not work with Dell Optiplex |
| Q154950 | SPX header not available for a terminate packet |
| Q154951 | Blue screen w/ S3 video driver upgrading from 3.51 to SP3 or SP |
| Q154952 | Remote admin can access a file for which Everyone has no access |
| Q154953 | Setup unable to create IUSR_computername account |
| Q154963 | DosSetSigHandler API not behaving as expected in OS/2 subsystem |
| Q154982 | ATDISK reports huge disk size on IDE greater than 2 GB |
| Q154983 | Dual screens at high resolutions don't display correctly |
| Q154990 | SETPASS may change password of wrong user |
| Q155026 | STOP 0xC000021A in Windows subsystem with status c0000005 |
| Q155052 | IIS server handling of URLs using "\", "<", and ">" |
| Q155056 | IIS security concern using batch files for CGI |
| Q155057 | ScanLogicalLocksByName supported in FPNW with Service Pack 5 |
| Q155058 | IIS server may hang after processing several client queries |
| Q155138 | STOP 0x00000077 in FPNWSRV.SYS during burst-mode read |
| Q155330 | FPNW utility to setup subauthentication on domain controller |

---

## Sources

- [Q128531 — README.TXT: Windows NT 3.51 U.S. Service Pack (KB archive)](https://jeffpar.github.io/kbarchive/kb/128/Q128531/)
- [Windows NT 3.51 — Wikipedia](https://en.wikipedia.org/wiki/Windows_NT_3.51)
- [Windows NT 3.51 U.S. Service Pack 5 README — zx.net.nz](https://ftp.zx.net.nz/pub/Patches/Microsoft/WinNT-patches/3.51/fixes/ussp5/README.HTM)
- [Windows NT Service Packs index — sdfox7.com](http://sdfox7.com/winntsp.htm)
- [Windows NT 3.51 Workstation Patches & Updates Guide — hpcfactor.com](https://www.hpcfactor.com/support/cesd/200239/windows_nt_351_workstation_patches_updates_guide/)
- [WinWorld: Windows NT 3.x Patches](https://winworldpc.com/product/windows-nt-3x/patches)
- [Windows NT updates archive — zx.net.nz](https://www.zx.net.nz/vc/updates/opsys/nt.shtml)
