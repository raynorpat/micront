# Windows NT 3.5 — Service Pack History

Windows NT 3.5 ("Daytona") shipped to manufacturing on **21 September 1994**
(build **3.5.807**). Over its supported life it received **three service packs**,
all of which kept the same major build number (3.5.807) — service packs of this
era patched binaries in place rather than bumping the kernel build string.

Service packs are **cumulative**: SP3 contains every fix from SP1 and SP2, so a
clean install only needs the latest pack applied.

> **A note on sources.** The original `README.TXT` changelogs Microsoft shipped
> inside each NT 3.5 pack are only partially preserved in public archives (SP1
> and SP2 binaries themselves are largely lost; SP3 survives for x86). The entries
> below are reconstructed from Microsoft KB references, the Wikipedia release
> record, and surviving service-pack archives. Where the precise per-pack fix
> list is not recoverable it is marked as such rather than invented.

---

## Release timeline

| Pack | Build | Released | Notes |
|------|-------|----------|-------|
| RTM  | 3.5.807 | 21 Sep 1994 | Original "Daytona" release |
| SP1  | 3.5.807 | early 1995 | First rollup of post-RTM hotfixes |
| SP2  | 3.5.807 | mid 1995 | Second cumulative rollup |
| SP3  | 3.5.807 | ~June 1995 (CD media dated 13 Sep 1995) | Final pack; basis of the C2 security evaluation |

Architectures: NT 3.5 ran on **x86, MIPS, and DEC Alpha**. Service packs were
produced per-architecture; in surviving archives the x86 packs are most complete,
with MIPS and Alpha variants frequently missing.

---

## Service Pack 1

The first cumulative rollup of hotfixes issued after the September 1994 release.
Focus areas of the early NT 3.5 hotfix stream were:

- **TCP/IP and networking** stability — the NT 3.5 TCP/IP stack was substantially
  rewritten versus 3.1, and early fixes addressed connection handling and
  WINS/DHCP client behaviour.
- **RAS (Remote Access Service)** dial-up reliability.
- **File system and SCSI** driver corrections.

The detailed SP1 README is not preserved in public archives; the above reflects
the categories of fixes folded forward into SP2/SP3.

---

## Service Pack 2

A second cumulative rollup carrying SP1 forward plus additional corrections in:

- Networking (TCP/IP, NetBIOS, redirector) reliability.
- Printing subsystem fixes.
- Assorted kernel and driver stability fixes.

As with SP1, the standalone SP2 changelog is not fully recoverable from surviving
media; SP2's content is wholly contained within SP3.

---

## Service Pack 3 — the definitive NT 3.5 pack

SP3 is the most important and best-preserved NT 3.5 service pack. It is the
recommended baseline for any NT 3.5 installation.

**Security — C2 / TCSEC evaluation.** In **July 1995**, Windows NT 3.5 *with
Service Pack 3* was rated by the U.S. National Security Agency as meeting the
**Trusted Computer System Evaluation Criteria (TCSEC) C2** requirements
(the "Orange Book" rating for controlled access protection). This was a marquee
milestone for NT in the government/enterprise market and the specific reason SP3
became the canonical NT 3.5 configuration — the evaluated configuration *was*
3.5 + SP3.

**Fix categories rolled up in SP3:**

- **Networking:** TCP/IP, WINS, DHCP, NetBIOS, and RAS corrections.
- **File systems:** NTFS and FAT robustness fixes.
- **Printing:** PostScript and LaserJet driver fixes.
- **Security:** the hardening and audit corrections required to satisfy the C2
  evaluation.
- **Drivers:** SCSI, video, and network adapter fixes.

---

## Practical guidance (for a from-source rebuild)

- Treat **3.5 + SP3** as the reference target — it is the evaluated, best-documented,
  and best-archived configuration.
- All three packs report the same `3.5.807` build string; do not rely on the build
  number to tell which pack is applied. The presence of patched binaries / the
  service-pack registry marker is the real indicator.
- SP1 and SP2 are historically interesting but functionally superseded; there is
  no reason to target them other than archival accuracy.

---

## Appendix — Fixed issues (official KB references)

The list below is transcribed from the official Microsoft README that shipped with
the NT 3.5 service pack — **KB Q123863** ("README.TXT: Windows NT Version 3.5 U.S.
Service Pack"). Because the packs are cumulative, this is effectively the full set
of issues resolved by **SP3**. Each entry is a Microsoft Knowledge Base article
number (the "Q number"); the original KB articles can be looked up by that number
in KB archives such as `jeffpar.github.io/kbarchive`.

The README presents the fixes in two blocks (an earlier-pack block followed by the
newest block); that ordering is preserved here. Microsoft did not tag each Q number
with the specific SP that introduced it, so no per-SP attribution is claimed.

| Q number | Issue |
| --- | --- |
| Q122182 | CALC.EXE display error in floating-point number calculation |
| Q122323 | NT 3.5 software update for the Pentium floating-point error |
| Q110882 | GP fault in WINLOGON.EXE |
| Q110932 | Mail fails with memory or network errors |
| Q110947 | Diamond Viper VLB video adapter driver fails to load |
| Q111026 | Backup creates many REGXXXX files, can't copy .EVT files |
| Q111027 | File write to network share using MS-DOS 21h function fails |
| Q111325 | Can't choose paper tray with PostScript printer driver |
| Q111420 | MIPS four-processor computer halts for long time |
| Q111429 | SET batch file command resets error levels |
| Q111450 | Two Token Ring adapters forces source routing on both adapters |
| Q111736 | Printing PostScript from Project, task bars shaded or darkened |
| Q112547 | Error and warning events not described in system log |
| Q112637 | STOP message on MIPS computer caused by NET command |
| Q112874 | Fonts look different when printed and on screen |
| Q113916 | Copy from one Novell server to another fails |
| Q114304 | ACLs not translated when user names have extended characters |
| Q114577 | Watermark software HP 1300T removable disk stuck or corrupted |
| Q114892 | Err Msg: "Out of Memory" browsing network files as administrator |
| Q115431 | Turkish characters in directory name hangs Windows NT |
| Q115602 | Cannot input Unicode characters >256 into dialog edit field |
| Q116341 | Characters change when pasted into 16-bit applications |
| Q117359 | SFM: copying files between volumes freezes other Mac clients |
| Q119277 | Err Msg: "Access denied" running MS-Mail SMTP gateway in VDM |
| Q119568 | Kyocera FS-3500A PCL driver will not print from lower paper tray |
| Q119574 | NT 3.1 to 3.5 upgrade does not copy OEM SCSI drivers to disk |
| Q120693 | Dual-processor MIPS computer with Proteon NIC hangs at startup |
| Q120770 | STOP 0x0000000A when CadexNet on LM clients stress SRV.SYS |
| Q121645 | STOP 0x0000001E in SRV.SYS |
| Q121725 | Alert for "<" condition fails to run batch file |
| Q121726 | STOP message caused by NTFS with long filenames |
| Q121822 | Deadlocks when using asynchronous named pipes |
| Q122043 | Err Msg: Access Denied connecting to NetWare resource |
| Q122224 | Format limits stripe sets to 4 GB |
| Q122248 | Event ID 2000 errors in system log |
| Q122329 | Err Msg: System Error 59 has occurred, an unexpected… |
| Q122368 | "Insufficient Memory" messages appear when you use Word 6 |
| Q122385 | Err Msg: Mail could not read the entire message… |
| Q122445 | Unexpected network error when changing WfWG password |
| Q122781 | LMHOSTS #INCLUDE of local files may fail on Windows NT 3.5 |
| Q122793 | Err Msg: OS Loader V3.5 Windows NT could not start… |
| Q122838 | Memory leak in LMREPL service |
| Q122903 | Error message with Compaq Smart SCSI |
| Q122961 | Print job stalls printing to NEC NPDL2 |
| Q122986 | Justified words printed with PostScript driver contain spaces |
| Q123058 | Closing timed-out applications without choosing End Task |
| Q123062 | Windows NT 3.5 fails to unlock a record area after locking it |
| Q123083 | Client hangs accessing remote downlevel LAN Manager server |
| Q123155 | Err Msg: The remote computer is not available |
| Q123159 | Windows NT 3.5 computer with Intel Neptune PCI chip hangs |
| Q123166 | Time and date stamp of Word 6.0 document updated |
| Q123215 | Backup incorrectly sets archive bit on WfWG 3.11 files |
| Q123275 | Extra keys on Brazilian keyboard do not work at command prompt |
| Q123338 | SFM performance degrades due to memory problem |
| Q123447 | Err Msg: STOP message in DLC.SYS |
| Q123478 | Multiple ISDN adapters cannot be installed |
| Q123500 | Administrators permissions for a printer change to Read |
| Q123607 | Graphics and TrueType fonts print garbage on Okidata ML320 |
| Q123678 | Changing registry does not prevent user from changing delay |
| Q123716 | CACLS.EXE Err Msg: No more internal IDs available |
| Q123717 | Windows NT Backup writes incorrect times to log |
| Q123738 | STOP 0x0000001E with NetBEUI client/server applications |
| Q123740 | Unexpected error accessing MS Mail postoffice through GSNW |
| Q123741 | Cannot run RAS programs when a service references RASAPI32.DLL |
| Q123744 | Secure Erase on Exabyte 2501 Err Msg: The computer has rebooted |
| Q123745 | Windows NT Err Msg: No more connections to the remote… |
| Q123862 | Opening a file causes the application to close |
| Q123942 | Invalid user names causes memory leak |
| Q123957 | Error updating PowerPoint 4.0 file using CSNW/GSNW |
| Q123964 | Server service hangs when using GSNW |
| Q123965 | Can't get zone information with Compaq Netflex II TR NIC |
| Q123976 | Sequential file reads of 4K instead of 64K blocks |
| Q124021 | CD-ROM file system does not de-allocate non-paged pool memory |
| Q124037 | Windows NT Setup Err Msg on Compaq: STOP 0x0000008B |
| Q124084 | FTP OnNet 1.1 PPP client hangs Windows NT 3.5 RAS service |
| Q124120 | Event Log service fails to start due to event log corruption |
| Q124121 | Memory loss during application process creation |
| Q124142 | Registry Editor hangs when you select a key |
| Q124157 | Cannot build VC++ projects (.PDB & .PCH files) on NetWare server |
| Q124242 | Forced disconnect for Macintosh users not working |
| Q124284 | STOP 0x00000026 when accessing a CD using an indirect path |
| Q124360 | Non-critical error with IR32_32.DLL and Mitsumi IDE CD-ROM |
| Q124374 | Windows NT 3.1 computer cannot log on to Windows NT 3.5 domain |
| Q124375 | SFM: file permissions problem when volume is shared at root |
| Q124484 | Error 33: DOSRead and DOSWrite APIs from OS/2 application |
| Q124542 | Service logged on w/ user account able to interact with desktop |
| Q124549 | Unable to disable print event logging in Windows NT 3.5 |
| Q124582 | VBApp & OLE do not work if network components are not installed |
| Q124648 | DC21040 causes Windows NT 3.5 to stop responding (hang) |
| Q124747 | SFM Err Msg: The item…is missing and was probably deleted… |
| Q124796 | DHCP client does not support Domain Name option |
| Q124816 | Very large or very small transfers to SCSI printers fail |
| Q124853 | STOP message with SFMATALK.SYS |
| Q124874 | STOP 0x0A running Performance Monitor on NEC 3360 |
| Q124909 | Problems accessing drive formatted with Ontrack Disk Manager |
| Q124910 | Using Ontrack Disk Manager to support large IDE drives |
| Q124912 | Slow processing with Windows NT PDC and LAN Manager BDC |
| Q124936 | Application in VDM may receive overrun error |
| Q124940 | STOP 0x0000000A when accessing NetWare server |
| Q124958 | NTFS integrity problems with large stripe sets |
| Q125573 | Event Viewer does not report system log errors correctly |
| Q125625 | Software compression compatibility in Windows NT 3.5 RAS |
| Q125646 | Computer with Intel Neptune PCI chip hangs on warm reboot |
| Q125759 | Windows NT 3.5 improves performance with Intel Neptune PCI chip |
| Q126020 | Setup Err Msg on Intel Xpress Deskside: Inaccessible Boot… |
| Q126277 | 16-bit process creation can result in memory loss |
| Q126429 | Equinox serial driver causes the Win16 subsystem to fail |
| Q126752 | DCs fail to synchronize or validate users over NWLINK |
| Q127818 | Clients fail to connect to Windows NT Server |
| Q128565 | LMHOSTS file generates STOP 0x00000050 |
| Q129045 | Date and time stamp of files change when copied to NetWare |
| Q130117 | Running PKZIP hangs WfW or Windows NT MS-DOS command prompt |
| Q130120 | Event Error 2000 logged repeatedly due to illegal command |
| Q130480 | GSNW share names displayed as DELETED with RAS server running |
| Q125385 | File size and date reported incorrectly on NTFS drive |
| Q126142 | Windows NT Mail Err Msg: The network path you entered could… |
| Q126383 | RAS callback via ISDN uses only one channel |
| Q126451 | SNA Server: Windows NT client loses session to server |
| Q126560 | Cannot create NetBIOS session over TCP/IP |
| Q126652 | FDDI MAC address issue with Windows NT 3.5 |
| Q126724 | NPMCA.SYS causes STOP 0x0A in TCPIP.SYS |
| Q126974 | STOP 0x24 generated with NTFS |
| Q126978 | IBM Token Ring /A adapter fails to start in Windows NT 3.5 |
| Q127775 | STOP 0x0A in STREAMS.SYS with DEC Pathworks loaded |
| Q127789 | LAN Manager clients cannot see Windows NT computers |
| Q127814 | Printing to NT queue attached to NetWare queue hangs NetWare |
| Q127821 | Problems using Event Viewer from Windows for Workgroups |
| Q127908 | Granularity value changes after installing Service Pack 2 |
| Q127909 | Seed routing not working with C.O.P.S. LocalTalk NIC |
| Q127922 | Setting BDC to be WINS proxy agent may cause broadcast storms |
| Q128254 | STOP C0000218 "Unknown Hard Error" when registry is overrun |
| Q128335 | IPX subnet clients unable to connect to Windows NT |
| Q128415 | NT to LAN Manager UAS replication problem after using PORTUAS |
| Q128447 | Enumeration of large NTFS directory takes a long time |
| Q128448 | RAS Event ID 20013: The user connected to port… |
| Q128550 | Memory leak: MS-DOS-based apps starting non-MS-DOS-based apps |
| Q129054 | Periods not displayed in CD-ROM disc volume label |
| Q129111 | PCI adapter incorrectly identified on dual-bus computers |
| Q129482 | Systems Management Server inventory via RAS causes STOP screen |
| Q129600 | Large zeroing operations cause systems to appear hung |
| Q130661 | Windows NT 3.5: STOP 0x0000000A in NETBT.SYS when memory is low |
| Q130901 | Frame corruption in retransmitted IPX packet |
| Q131339 | STOP 0x0000000A or 0x0000001E dis/reconnecting to WfWG server |
| Q131479 | Unable to change printer settings from Windows applications |

---

## Sources

- [Q123863 — README.TXT: Windows NT 3.5 U.S. Service Pack (KB archive)](https://jeffpar.github.io/kbarchive/kb/123/Q123863/)
- [Q121693 — How to Obtain Windows NT 3.5 U.S. Service Pack (KB archive)](https://jeffpar.github.io/kbarchive/kb/121/Q121693/)
- [Windows NT 3.5 — Wikipedia](https://en.wikipedia.org/wiki/Windows_NT_3.5)
- [Windows NT Service Packs index — sdfox7.com](http://sdfox7.com/winntsp.htm)
- [WinWorld: Windows NT 3.x Patches](https://winworldpc.com/product/windows-nt-3x/patches)
- [Windows NT updates archive — zx.net.nz](https://www.zx.net.nz/vc/updates/opsys/nt.shtml)
- [Old OS — OS Updates Downloads](https://oldos.org/downloads/osupdates/)
