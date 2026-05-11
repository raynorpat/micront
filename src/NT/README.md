# Windows NT 3.50 — Project-Level Design Notes

Cross-cutting documents from the Microsoft Portable Systems Group covering the
overall NT OS/2 project: product manifest, implementation plan, design-workbook
introduction, and subsystem design rationale. Transcribed from
`stuff/docs/*.doc` via soffice + pandoc + cleanup-md.py.

---

## `basecont.doc` — NT OS Base Product Contents

*Author: Lou Perazzoli*  
*Revision 0.6, November 27, 1990*

Portable Systems Group

NT OS Base Product Contents

**Author:** Lou Perazzoli

Original Draft 0.0, September 19, 1990

Revision 0.1, September 25, 1990

Revision 0.2, October 2, 1990

Revision 0.3, October 15, 1990

Revision 0.4, October 18, 1990

Revision 0.5, October 30, 1990

Revision 0.6, November 27, 1990

# 1. Introduction

This document describes the NT Base group deliverables for the **NT OS**
for four product releases:

- beta testing SDK kit for RISC and 486

- retail product for MIPS and 486 workstation (includes retail SDK kit).

- retail product for RISC, uniprocessor 486, and 486 mutliprocessor
servers

- retail product for 486 workstation which includes MVDM and Win-16
support.

Note that 386 workstations will be supported (B6 stepping and above),
but they will not have kernel support for correcting the deficiencies in
i386 memory management. This deficiency manifests itself by allowing one
thread to change the page protection on a page to read-only and having
another thread (which is executing a kernel service) write to that page.
The 486 has hardware support to honor page protections in kernel mode.

The Base group is responsible for those portions of **NT OS** which do
not include networking or windowing, for example, device drivers, files
systems, scheduler, loader.

# 2. Internal development workstation

Allows self-hosting of NT on an NT workstation. This includes CMD.EXE,
compiler, assembler, linker, SLM, editor (MEP), redirector, and other
tools.

As the windowing environment will still be under development, a stopgap
character mode window driver will be developed which will allow the VGA
on the 386/486 and frame buffer on JAZZ to appear as an ANSI terminal
device. This allows character based applications to operate using the
graphics device as an output device. The ANSI terminal emulation will be
incorporated into the Windows environment for the SDK release. This
support is described in the document titled ***NT
Console Interface Specification***.

# 3. Beta testing SDK kit (includes DDK)

The beta testing SDK kit contains the basic features of **NT OS** to
allow ISVs and OEMs to begin developing applications and device drivers
targeted specifically at Win-32 and/or NT.

## 3.1 API Sets

The following API sets are provided (including necessary header files
for C language):

Win-32 Base API - provides the 32-bit interface for integrating with the
base operating system. These APIs are described in the document titled
*Win32 Base APIs* and are designed as a logical extension to the Windows
3.0 Base APIs thereby allowing a straightforward conversion of software
developed for Windows 3.0. This same API set is offered on the 32-bit
version of Windows.

NT Native API - this is the underlying API set for NT. It is currently
undecided if this API set is formally documented, though certain
features may be provided through an "NT Extension" API set. One such
feature which would improve server based applications is asynchronous
I/O. *Issue: if the NT API set is provided, documentation must exist.*

Device Drivers - this is the "public executive" (device helper) API set
exposed by NT kernel mode components. The User Ed group is developing
documentation for device driver developers. The **NT Design Workbook**
specifies the device driver model and interface in documents titled
***NT OS Driver Model Specification*** and
***NT OS I/O System Specification***.

## 3.2 Subsystems

The **NT OS** base provides a number of subsystems which act as servers
for various applications. Subsystems operate as user mode processes but
may have amplified privileges beyond the client application. This allows
subsystems to manage global state, open key files, and manage critical
resources on behalf of its clients.

The following subsystems exist in the **NT OS** base:

- Session Manager - provides a mechanism to start processes executing
images which were developed for a different API environment then the
current process. For example, a POSIX application can "exec" an image
which was developed with the OS/2 API set. The session manager is
describes in a document titled ***NT OS Session
Management and Control***.

- Security

- Local Security Authority - maintains security policy information,
including list of privileged users, audit control, and security domain
membership. This is described in a document titled
***NT OS Local Security Specification***.

- Security Account Manager - maintains user and group account
information as described in the document ***NT OS
Security Account Manager Protected Server (SAM)***.

- Loader - provides mechanism for locating DLLs, translating symbol
names to executable images, and other DLL related functions.

- Windows Base - provide mechanism for maintaining shared state between
window processes and groups. The functionality provided by this
subsystem may be moved to the subsystem which provides windows graphic
support.

- Debug - provides dispatching of debug events. This subsystem is
described in the document titled ***NT OS Debug
Architecture***.

*Issue: Is DOS emulation required on the RISC/PC? How about Win-16
emulation?*

## 3.3 File Systems

- FAT - supports the FAT file format. This allows floppy disks to be
exchanged between NT and DOS. The overall file system design is
described in the document titled ***NT File System
Design Note***.

- HPFS - supports the HPFS file format as defined by OS/2 v1.21.

- NTFS - supports the NT native fully recoverable file system. This file
system provides enhanced data integrity features to provide basic
support for transactions. The NTFS is described in the document titled
***NT Recoverable File System
Specification.***

- CD-ROM - supports the ISO CD-ROM file format.

- NPFS - supports named pipes. The named pipe file system is described
in the document titled ***NT Named Pipe File
Specification***.

- BOOT - supports multiple boot partitions and allows new file formats
to be bootable as described in the ***NT Boot
Architecture***.

## 3.4 Device Drivers

Device drivers provide the necessary logic to bind the I/O functions to
a physical device. **NT OS** supplies the proper mechanisms to allow
drivers to be loaded either at system initialization or later once the
system is operational.

### 3.4.1 MIPS R4000 PC drivers:

- floppy as described in the document ***NT Floppy
Driver Specification***.

- SCSI driver with support for disk, CD-rom and tape as described in
***NT SCSI Design Note***.

- serial - western digital part (2 serial, 1 parallel port), supports
modems, printers, basic serial devices as described in the
***NT Serial Driver Specification.***

- parallel - western digital part, supports printers and basic parallel
devices as described in the ***NT Parallel Driver
Specification***.

- video - frame buffer as described in ***NT
Screen Device Driver Design Note.***

- keyboard as described in ***NT Keyboard Device
Driver Design Note.***

- mouse - in port as described in ***NT Mouse
Device Driver Design Note.***

- sound

- EISA support - verification driver to show that EISA functions
properly.

### 3.4.2 Intel 486/MP and uni-processor drivers:

- floppy as described in the document ***NT Floppy
Driver Specification***.

- SCSI driver with support for disk, CD-rom and tape as described in
***NT SCSI Design Note***.

- disk - ST506 EDSI driver as described in the
***NT EDSI Driver Specification.***

- serial - Intel 8250 part supports modems, printers, basic serial
devices as described in the ***NT Serial Driver
Specification.***

- parallel supports printers and basic parallel devices as described in
the ***NT Parallel Driver Specification.***.

- video - frame buffer as described in ***NT
Screen Device Driver Design Note.***

- keyboard as described in ***NT Keyboard Device
Driver Design Note.***

- mouse - in port and serial variants as described in
***NT Mouse Device Driver Design Note.***

- EISA support - verification driver to show that EISA functions
properly

- MCA support - verification driver to show that MCA functions properly

## 3.5 Fault tolerance

For systems with battery backed up memory, power fail recovery is
supported. This support involves saving volatile hardware registers and
caches into RAM during loss of power and restoring the system state when
power is regained. At restoration time, all drivers requesting powerfail
notification are notified and any I/O operations in progress are
restarted by the drivers.

## 3.6 Language support

## 3.7 MIPS support

- C compiler for MIPS (from either MS or MIPS)

- MIPS assembler for R4000 (only runs on RISC/PC)

- Linker for R4000 (provided by NT/Base group)

- Debugger similar to symdeb

- Kernel debugger for device driver ISV's (requires separate host
machine, currently running OS/2)

- C Run time libraries for Win-32 applications

- Cross development tools for 486 development:

- C6.0 compiler

- MASM Assembler

- Linker for 486 modules. Current plan is for the NT native linker to
support both MIPS and 486 OMFs (Object Module Formats).

## 3.8 Intel 486 support

- C6.0 compiler

- MASM Assembler

- Linker for 486 modules.

- Debugger similar to symdeb

- Kernel debugger for device driver ISV's (requires host machine,
currently OS/2).

*Issue: the kernel debugger should be ported to the Win-32 environment
at a minimum and possibly to the Win-16 environment. Porting to the
Win-16 environment provides the least disruption to the target
audience.*

- C Run time libraries for Win-32 applications

## 3.9 Hardware booting support

The following platforms are being utilized for development and/or
testing and as such hardware booting support and configuration will be
provided.

- Power PC/RISC (Jazz)

- Compaq Deskpro-486 (EISA)

For 386 environments, Intel 387 floating point emulation is provided for
system without 387 coprocessors.

## 3.10 Installation / Setup

The beta SDK release will have minimal installation / setup support.
This includes support for building a bootable system from a floppy disk
kit and copying the appropriate SDK header files and utilities to the
hard disk.

## 3.11 Performance utilities

The beta SDK will have basic performance utilities.

- profiler - provides mechanism to obtain a time sampled PC histogram.
The profiler is implemented like a debugger; no changes are required to
the application to enable profiling. The profiler operates in its own
address space and creates profiling objects on behalf of the process
being profiled. When the process completes, the profiler closes the
profile objects and analyzes the collected data. The beta SDK version of
the profiler will not be GUI based. The profiler fucntionality is not
currently documented.

- show system information - shows the current resource usage, active
processes, active threads, etc. within the system. The show system
functionality is not currently documented.

## 3.12 Development utilities

> CMD.EXE - command interpreter (ported from OS/2) provides basic
> commands (dir, ren, del, etc) and batch script capability.
>
> format - format disks, supports FAT format for floppy, HPFS, FAT, and
> NTFS for hard disks.
>
> chkdsk - check disk, checks disk for consistent file structure and bad
> blocks
>
> chmode - allows protection on file to be changed
>
> diskcopy - sector based floppy disk copy
>
> diskcomp - sector based disk comparison
>
> du - disk usage by directory
>
> ech - echo string
>
> fcom - compare files (both text and binary)
>
> fcopy - general purpose file/directory copy
>
> fdel - general purpose file/directory deletion
>
> fview - extensible file viewer, views text files, objects, images,
> etc.
>
> ls - list directory contents
>
> nmake - program maintenance utility
>
> ppr - remote print
>
> qgrep - search for strings in files
>
> sort - sort file contents base on keys
>
> timer - simple execution timer
>
> touch - change file time stamps
>
> walk - walk a directory tree applying command to files and directories
>
> where - locate files in a directory tree
>
> ync - single character batch file prompts (yes, no, continue)
>
> editor (MEP) which utilizes WinHelp

## 3.13 Internal Development Utilities (not shipped with SDK)

> cp - copy file to file or files to directory
>
> delnode - delete directory tree
>
> exp - remove deleted files
>
> mv - rename files and directories
>
> rm - make files deleted
>
> slm - source control maintenance facility
>
> t - terminal emulator
>
> undel - undelete deleted files
>
> upd - timestamp based file copy
>
> updrn - timestamp base file copy for directories
>
> xcopy - copy file and directory tree

# 4. Retail Product for RISC/PC (includes an SDK)

The retail product for RISC/PC includes the final version of the
components provided in the beta SDK release plus installation/setup
features, POSIX compliance and security at the C2 level.

## 4.1 API Sets

Same as beta SDK with addition of POSIX support.

POSIX 1003.1 API - provides the POSIX compliant APIs. These APIs are
defined by the *IEEE 1003.1 POSIX specification*. The APIs supported are
the minimum set required for to obtain POSIX certification, i.e., none
of the optional APIs will be supported.

## 4.2 Subsystems

Same as Beta SDK with the addition of POSIX.

- POSIX - provides support for all processes executing the POSIX API
set.

## 4.3 Device Drivers

Same as beta SDK.

## 4.4 File Systems

Same as beta SDK.

## 4.5 Fault tolerance

Same as beta SDK.

## 4.6 Language support

Same as beta SDK plus the addition of C run time libraries for POSIX
applications.

## 4.7 Hardware booting support

Same as beta SDK.

## 4.8 Installation / Setup

Complete installation / setup support including configuration
management. The documentation for installation and system management is
currently under development.

- Architecture dependent kernel routines

- System configuration / configuration management

- System management

- Error log reporting mechanism. This is a character mode application
that allows error log reports to be generated based on error type, time,
and device type. For example, list all Fatal errors on device Harddisk0
between Jan 1 1990 12:00 and Jan 1 1990 18:00.

- System crash dump and analysis utility. This provides a mechanism to
dump the contents of physical memory to a file on the disk in the case
of a system crash. When the system is rebooted, the analysis utility
allows the cause of the crash to be analyzed. In severe cases, crash
dump contents may be copied to floppy or tape and sent to product
support specialists for analysis.

- File backup on SCSI tape. This utility provides the ability to backup
and restore complete volumes or selected files onto tape.

> *Issue*: *does this need to be SYTRON compatible to provide the
> ability to read files written on an OS/2 system? How about just
> supporting TAR format??*

- Application installation - provides a mechanism to install application
software on an NT system.

- National Language Support (NLS) - provides a mechanism for tailoring
an NT system to a specific language environment.

- Shutdown - allow orderly shutdown of the system as a reasonable
alternative to Ctrl-Alt-Del. The shutdown mechanism flushes file caches,
terminates network connects, and does an orderly shutdown of the system.

## 4.9 Security

**NT OS** provides security features to allow the base operating system
to be certified at the C2 level (discretionary access control) for the
first product release, and eventually at the B1 level. In order to gain
certifications certain features and utilities must be present in the
system to allow the detection and analysis of break-in attempts and
suspected attempts. In addition, a mechanism must be provided to allow
users to display and manipulate security information on objects, most
notably files.

The following components are provided to support security:

**User Interface:**

User Account Manager - This utility is based upon the LAN Manager 3.0
User Account Manager utility. It includes minor extensions to support
administration of Security Account Manager concepts that don't exist in
LAN Manager.

Local Security Manager - This utility allows the security parameters of
each NT system to be administered. This is a new utility with no
corresponding LAN Manager functionality. This utility will utilize the
Local Security Manager DLL described below.

Win32 Logon User Interface - This is the user interface presented at
logon time. It collects the user name and password and prevents password
stealing by unauthorized processes. This UI is projected by the Win32
logon process described below.

Win32 File Browser extensions - The Win32 File Browser will be extended
to support security by:

- Displaying security of files and directories upon request.

- Allow modification of file and directory protection and auditing
requirements (using the Object Security editor DLL described below).

- Allow modification of file and directory owner values.

The Win32 Shell will allow a user to establish security *personas* and
to modify the user's active security persona. This will allow the user
to perform actions such as changing default protection or enabling and
disabling privileges.

Some aspects of installation will deal with establishing the customer's
mode of operation (secure or non-secure) and collecting security
parameters, if running securely. A secure system may also have to
convert a LAN Manager UAS database to a Security Account Manager
database.

Some aspects of configuration control will deal with the security
attributes associated with components of the configured system. For
example, protected subsystems, such as the NT Session Manager, may be
assigned privileges to be run with.

**Runtime Library & Client Stubs:**

Runtime Library routines will be included for the manipulation of
security data structures, such as access control lists.

Client RPC stubs will be included for Security Account Manager services,
making the security Account Manager a network-wide service. This allows
administration of security accounts from remote nodes.

Client RPC stubs will be included for Local Security Authority services,
making the Local Security Authority a network-wide service. This allows
administration of individual system security from remote nodes.

**Executable Images And DLLs:**

Security Account Manager protected subsystem image (sam.exe). This image
is run as a native NT protected subsystem. It services user/group
account administration requests, as well as user authentication
requests. This image will only be run on Domain Controller nodes.

Local Security Authority protected subsystem (lsa.exe). This image is
run as a native NT protected subsystem. This image is responsible or
maintaining and enforcing all security policy for an individual system,
such as what audit messages to generate. This protected subsystem will
be active on each NT system.

Win32 Logon Process (w32logon.exe). This image is responsible for
monitoring Win32 for logon requests, and processing them when received.
It prevents Trojan programs from stealing user passwords. This is a
customer modifiable or replaceable module and we will ship the source
code for this module. This image will be active on each NT system.

Local Security Manager DLL (lsm.dll). This DLL provides Win32 user
Interface screens for administering the local system security. This is
implemented as a DLL to allow this functionality to be activated from a
number of related UI utilities (such as the security account
administrator).

Object Security Editor DLL (objsec.dll). This DLL provides object
protection viewing and modification capabilities. It is implemented as a
DLL to allow a standard view of object security to be used anyplace it
is needed. For example, the file browser will use this DLL for file and
directory protection modification and the Security Account Manager will
use this DLL for user and group account protection modification.

## 4.10 Performance utilities

Same as beta SDK with a GUI interface to show system information
utility.

## 4.11 Development utilities

Same as beta SDK with the addition of UI enhancements to some utilities
and the user debugger.

# 5. Retail Product for Servers (RISC, 486 and 486MP)

The retail product for servers includes the retail product components
provided in the above product in addition to a more robust networking
environment.

## 5.1 API Sets

Same as RISC workstation product.

## 5.2 Subsystems

Same as RISC workstation product.

## 5.3 File Systems

Same as RISC workstation product.

## 5.4 Device Drivers

Same as retail product (both MIPS and 486).

## 5.5 Fault tolerance

- Disk Mirror - allows files mirroring of disk image on another disk(s)
block for block. While this is implemented as a layered driver, it is
listed under file systems.

- UPS - uninterruptable power systems support

- Dual controller support ??

## 5.6 Language support

Same as RISC workstation product with the addition of C++ support.

## 5.7 Hardware booting support

The following platforms are being utilized for development and/or
testing and as such hardware booting support and configuration will be
provided.

- Power PC/RISC (Jazz)

- Power PC/486 with EISA bus

- Power PC/486 with MCA bus

- Compaq Deskpro 486

- IBM PS/2 Model 90

- Power MP/486 - to be determined.

## 5.8 Installation / Setup

Same installation / setup features provided in the RISC workstation
product plus the addition of:

- Disk mirroring management

- Logical volume management - allows multiple disks to be configured
such that they appear as a single drive.

## 5.9 Security

More network based security? remote admin?

## 5.10 Performance utilities

network performance things?

## 5.11 Development utilities

Same as RISC workstation product.

# 6. Retail Product for 486 workstations

The retail product for 486 workstations provides the support for running
Windows 16-bit applications and DOS applications as well as support for
32-bit OS/2 non PM base (i.e., server) applications.

## 6.1 API Sets

Same as server product.

## 6.2 Subsystems

Same as server product plus the addition of:

- MVDM subsystem

- Windows 16-bit subsystem

- OS/2 subsystem

## 6.3 File Systems

Same as server product.

## 6.4 Device Drivers

Same as server product.

## 6.5 Fault tolerance

Same as server product.

## 6.6 Language support

Same as server product.

## 6.7 Intel 486 support

Same as server product.

**5.8 Hardware booting support**

Same as server product.

## 6.8 Installation / Setup

Same installation / setup features provided in the server product plus
the addition of:

- MVDM installation

- Windows 16-bit installation

- OS/2 Subsystem installation

## 6.9 Security

Same as server product.

## 6.10 Performance utilities

Same as server product.

## 6.11 Development utilities

Same as server product.

---

## `implan.doc` — NT OS/2 Product Description and Implementation Plan

*Author: David N. Cutler*  
*Revision 0.1, October 24, 1990*

Portable Systems Group

NT OS/2 Product Description and Implementation Plan

**Author:** David N. Cutler

Revision 0.1, October 24, 1990

# 1. Executive Summary

**NT OS/2** , here referred to simply as **NT**, is a new operating
system product being developed by **Microsoft** which is portable and
supports the Windows 32-bit base system APIs, graphical user interface,
and window management software.

This document describes implementation plans for the **NT** operating
system and contains product descriptions, projected release dates, an
overall schedule, a summary of the work items to be performed, and a
list of external dependencies.

Development on **NT** actually began approximately two years ago and has
progressed to the point where significant system functionality is
operational on both 386/486 and MIPS RISC platforms.

In addition to the development of the **NT** operating system,
**Microsoft** is also developing a reference implementation for RISC PCs
based on the MIPS R4000 microprocessor chip. This hardware architecture
will be the main target for the first **NT** product release.

The development and product releases of **NT** will be phased such that
new markets are addressed first, followed by high end server markets,
and finally the general workstation market.

**NT** is aimed at the high end of **Microsoft's** systems business and,
when running on an 386/486 platform, will share a binary compatible
32-bit programming interface with the low end implementation of the
Windows 32-bit operating system environment based on DOS and an
extension of Windows 3.0.

On RISC systems, **NT** will provide source level compatiblity with the
386/486 versions of the Windows 32-bit operating system environment, and
binary compatibility with other RISC systems of the same architecture.

Typically **NT** will service markets requiring larger memories and
higher performance (e.g., greater than 4mb and RISC performance levels),
whereas the low end system will service markets requiring smaller
memories, lower performance, and x86 binary compatibility (.e.g, less
than 4mb of memory and up to 486 performance).

Currently four major product releases are planned, although it is likely
that one of more of these releases will be combined.

The first release of **NT** is planned as a workstation product that
will provide a strong competitor to UN*X based workstations. It will
provide the Windows 32-bit operating system environment, a POSIX
compliant execution environment, high integrity, robustnesss, security,
and be network enabled as both a client and a server. The primary target
for this release is a MIPS based RISC PC, although a 386/486 system will
also be developed in parallel and be ready for deployment.

\A major issue that needs to get resolved is whether DOS and/or Windows
16-bit emulation needs to be provided on the RISC platform. Another
issue relates to whether the 1003.2 tools need to be delivered with the
POSIX environment./

The second release of **NT** is planned as a scalable performance server
product and adds multiprocessor support for 486 systems, LanMan 3.0
functionality, an extensive set of network device drivers, and the full
services needed to replace OS/2 1.x as the primary **Microsoft** server
platform. Its main marketing goal is to provide strong competitor with
Novell for server based systems.

The third release of **NT** adds full support for 386/486 workstations
and includes DOS emulation, Windows 16-bit emulation, OS/2 32-bit Base
APIs, and certified C2 security. It will provide a full PC workstation
environment.

The fourth release of **NT** adds support for multiprocessor RISC
servers. This release will most lilely be combined with the second
release if hardware is available for testing and evaluation.

In addition to the planned product releases, an OAK, DDK, SDK, and
source porting kit will be available at the appropriate times.

# 2. Overall Goals

The overall long term goals for the **NT** project are to:

- Provide **Microsoft** with a high end Windows 32-bit operating system
that is portable, secure, and provides the base technology to compete
with UN*X on the desktop, Novell in the network, and provides the
advanced features necessary to implement "information at your finger
tips".

- Provide **Microsoft** with a reference implementation of a RISC
platform based on the MIPS R4000 microporcessor chip that can be used to
facilitate the establishment of standards for the implementation of RISC
PCs and servers.

- Deliver on the above two goals by providing a series of product
releases that build functionality, let **Microsoft** address new
markets, and provide strong compatibility ties to existing and future
low end products.

The specific development goals for **NT** are:

- Portability - **NT** will be written in C and will be portable to
RISC, the 386/486, and other architectures. A typical port to a new
architecture should take no longer than six calender months.

- Security - **NT** will be designed to have pervasive security and will
be capable of attaining the "B" levels of security as defined by the
U.S. government. Initially it will be certified at the C2 level.

- Compatibility - **NT** will provide a high degree of compatiblity with
other **Microsoft** systems.

- Window 32-bit Environment - Binary compatibility with the low end
implementation of 32-bit Windows environment will be provided when
running on a 386/486 system. On RISC platforms, source level
compatibility with 386/486 systems will be provided and binary
compatibiity with other RISC platforms of the same architecture.

- OS/2 32-bit Base APIs - Binary compatibility will be provided with
the OS/2 2.0 32-bit Base APIs when running on a 386/486 platform. On
RISC platforms source level compatiblity will be provided.

\OS/2 32-bit Base API binary compatibility is predicated on IBM
accepting and implementing all of the NT OS/2 DCRs that were implemented
in Cruiser. This includes the image format, structured exception
handling, alignment of arguments, and changes to the semantics of
muxwait.\

- DOS and Windows 16-bit Environment - Binary compatibility with DOS
and 16-bit Windows will be provided when running on a 386/486 system. On
RISC platforms, these capabilities will be provided via software
emulation of the 8086 instruction set.

\It is not clear how extensive these capabilites will be. The simplest
and most straight forward approach is to only run "clean" APPs that do
not make arcane use of hardware resources. If all APPS have to be
executed without change, then this goal becomes more difficult to
achieve. Another question is whether network services need to be
available to 16-bit environments.\

- File Systems - Binary compatible on-disk structures will be provided
for the FAT, HPFS, and CD-ROM file systems on both 386/486 and RISC
platforms.

- Network - LanMan compatible protocols, redirector, server, and
network services will be provided.

- Multiprocessors - **NT** will support symmetric multiprocessing and
provide scalable performance on 486 and RISC based platforms.

- POSIX - **NT** will provide a POSIX compliant IEEE 1003.1 (FIPS 151-1)
POSIX execution environment for deployment in the government
marketplace.

- Virtual Memory - **NT** will provide support for a 32-bit flat
addressed virtual environment with demand paging, mapped files, and
asynchronous I/O.

The 486 and RISC PC platforms will be fully supported by **NT** and will
provide a robust and high integrity system. The deficiencies in the 386
memory management architecture, however, will not be fully masked and
will result in a 386 based system that is less secure and does not
exhibit the same level of integrity and robustness as the 486 and RISC
systems. In actual practice this should not be a concern and only
represents an exposure in a system under malicious attack.

\386 platforms must contain an i386 B6 stepping or above to be
supported. Earlier steppings will not be supported and an attempt to
boot on such a platform will be rejected by the NT system with an
appropriate error message.\

# 3. Major Milestones, Implementation Strategy, and Overall Schedule

Several major milestones are planned on the road to a the first release
of an **NT** product. These milestones lead through a progression of
functionality and will increase confidence that the implementation is
proceeding according to plan.

Currently **NT** boots and executes user programs on both 386/486 and
MIPS R3000 based DECstation 5000s. However, the network software is not
complete, the complete set of development tools are not in place, the
implementation of the Windows 32-bit base system APIs, graphical user
interface, and window management environment are just beginning, and the
system is not capable of supporting its own development. In addition,
the Jazz hardware is not yet available for software development.

The first major milestone is the finalization of the implemenation plan,
product descriptions, and development schedule. This is expected to
occur before the end of the year with the first draft completed by
**November 30, 1990**.

The main implementation strategy for **NT** is to provide a self hosted
development environment on **NT** as quickly as possible. This will
provide more testing, force the focus to a stable system that supports
its own development, and provide a viable system for ISV and hardware
OEM development.

Self hosting will first occur on the 386/486 and be followed shortly
thereafter on the Jazz MIPS hardware. The initial self hosted
development environment will support network connections to the source
code server, character mode development tools, and will require an
additional machine for mail and producing word documents.

The target date for self hosting on 386/486 systems is **March 26,
1991** and the target date for the Jazz MIPS system is **April 25,
1991**.

Self hosting with character mode tools will be followed by a windows
environment that supports an ANSI terminal window. This will allow the
windowing and graphical user interface software to be combined into the
system that is running on each developer's desktop.

The target date for a self hosted system on both the 386/486 and Jazz
MIPS platforms using the windowing environment is **????**.

The next major milestone is a Beta Test SDK that contains a full Windows
32-bit environment on both 386/486 and Jazz platforms. The target date
for the Beta Test SDK is **????**.

It is envisioned that two major updates to the beta-test SDK will be
required before the first real product release. These updates will occur
at approximately 3 month intervals.

The target for the first product release is **????**.

# 4. Self Hosted Development Environment

The self hosted development system provides for the development of
**NT** on **NT**. There are three self hosted system milestones
described below.

## 4.1. ANSI Terminal Based 386/486 Self Hosted System

The 386/486 self hosted system will occur first and will contain
following tools and components:

1. A completely functional **NT** base system with virtual memory,
multithreading, process management, image/DLL loader, file system
support (FAT and HPFS), and disk driver (ST506).

2. Support for the Windows 32-bit base system API minus the named pipe,
sound, and registration APIs.

3. ANSI terminal support for character mode APPs in the keyboard,
mouse, and display drivers.

4. A complete C runtime library that uses the Windows 32-bit base
system APIs.

5. A command interpreter (CMD.EXE) and the Z-Tools.

6. The source language maintenance utility (SLM).

7. A full screen editor (MEP).

8. The make utility (NMAKE).

9. A native profile utility.

10. A linker that produces executable images and DLLs.

11. An object module conversion utility to convert from the
**Microsoft** x86 object format to the COFF format(CVTOMF).

12. The **NT** system build utility (BUILD.EXE).

13. A LanMan redirector that is capable of communicating with and
accessing files and printing on a LanMan 2.0 server.

14. A NetBeui transport.

15. The CFRONT C++ preprocessor.

16. An Etherlink II NDIS driver.

17. A 386/486 C compiler with structured exception handling.

18. A 386/486 assembler.

19. A 386/486 user mode debugger.

20. An OS/2 hosted 386/486 kernel debugger.

The **NT** group will deliver all of these components except the last
four items which will be delivered by the **Microsoft** Languages group.

\A schedule commmitment is required from the languages group for
support of an NT OS/2 hosted 386/486 C compiler, 386/486 assembler, and
386/486 user mode debugger.\

Four people from the **NT** group will be responsible for pulling
together the actual system and verifying its operation over a 6-8 week
period. These people are tentatively identified as Bryanwi, Stever,
Garyki, and Davidtr. Kylesh from the testing group will be the offical
build resource and will be responsible for maintaining the build and
maintenance trees.

People developing the MIPS self hosted system will not be able to switch
their development environment to the 386/486 **NT** system since they
will have to be able to continue to compile on the DECstation 5000
systems which are accessed using TCP/IP.

The target data for the self hosted 386/486 system is **March 26,
1991**.

\A complete set of Windows 32-bit base system API tests should be
operatioinal to check out this system. What other tests should be
available?\

\A complete set of network aware file tests should be available.\

\File system and file server stress tests should be available.\

\Are there any doucmentation requirements?\

Documentation will be required for installation and a description of the
features that are, and are not, available in the various utilities.

## 4.2. ANSI Terminal Based MIPS Self Hosted System

The MIPS self hosted system implementation will proceed in parallel with
the 386/486 self hosted system support but will not occur until after
the 386/486 version. It will contain the following additional tools and
components:

1. A port of the **NT** base system from the DECstation 5000 to the
R3000 based Jazz system. This requires a new set of device drivers for
the SCSI and floopy disks and an update to the original i860 bootstrap
code.

2. A port of the **NT** base system from the R3000 based Jazz system to
the R4000 base Jazz system. This requires a rewrite of the trap handling
code, an update to the memory management code, and an update to the
interlocked operations.

3. ANSI terminal support for character mode APPs in the keyboard,
mouse, and display drivers.

4. A port and verification of all the above development utilities and
tools to the MIPS environment. This includes the 386/486 C compiler and
386/486 assembler.

5. The MIPS C compiler with structured exception handling.

6. The MIPS assembler.

7. A MIPS user mode debugger.

8. An OS/2 hosted MIPS kernel debugger.

9. A Sonic chip NDIS driver.

10. A port and verification of the redirector and NetBeui transport.

The **NT** group will deliver all of these components except the 386/486
C compiler, 386/486 assembler, the MIPS user mode debugger, and the OS/2
hosted MIPS kernel debugger which are being delivered by the
**Microsoft** Languages Group.

\A schedule commmitment is required from the languages group for
support of an NT OS/2 hosted 386/486 C compiler, 386/486 assembler, and
a MIPS user mode debugger.\

Four people from the **NT** group will be responsible for pulling
together the actual system and verifying its operation over a 6-8 week
period. These people are tentatively identified as Markl, Davegi, Tomm,
and Larryo. Kylesh from the testing group will be the offical build
resource and will be responsible for maintaining the build and
maintenance trees.

The target data for the self hosted MIPS system is **April 25, 1991**.

Meeting the target date assumes that a MIPS compiler will be available
on the DECstation 5000 by **December 1, 1990** that fully supports
structured exception handling and a Microsoft C compatible packed
pragma.

Meeting the target date also assumes that the R3000 based Jazz hardware
will be available for use by the **NT** software group by **December 1,
1990** and that the R4000 based Jazz system will be available by
**February 1, 1991**.

\We will have to decide how to split the source tree for multiple
targets within one architecture. Currently this is done via conditional
compilation, but the differences between the R3000 and R4000 based Jazz
system will be too great to use this methodology.\

\A ported set of Windows 32-bit base system API tests should be
available for testing this system. What other tests should be
available?\

\A complete set of network aware file tests should be available.\

\File system and file server stress tests should be available.\

## 4.3. Windows Based Self Hosted 386/486 and MIPS System

The windows based self hosted system adds Windows support for an ANSI
terminal window and allows the phase over from the interim ANSI terminal
capabilites to a fully windowed system. This system will be supported on
both 386/486 and MIPS platforms and will form the development
environment for the components and capabilities needed for the Beta Test
SDK system.

The Windows based self hosted system will contain the following
additional capabilities and components:

1. ANSI terminal support in a window.

2. The GDI subset required for window support.

3. The user window manager.

4. The program manager in the shell.

5. Kernel and DDI level device drivers for the Jazz and 386/486
display, keyboard, and mouse that have the interim ANSI terminal support
removed.

6. The resource compiler.

\What other tools and capabilities are needed?\

\What is the debugging environment for windows apps? Is it 3.1
compatible? Does it require a separate terminal?\

\The 32-bit thunks kit would help the development of Windows 32-bit
APPs before the full windowing environment is available.\

The target date for the self hosted windows system is **May 1, 1991**.

# 5. Beta Test SDK

The Beta Test SDK will be a formally packaged system that is distributed
to a selected set of ISVs and hardware OEMs wishing to develop device
drivers. It will be supported on a selected 486 platform and the Jazz
MIPS platform.

It will contain preliminary installation and configuration management
software.

Windows based version of user debugger.

DDK and device driver writers guide.

NDIS driver writers guide.

# 6. Product Descriptions

This following sections contain a detailed description of the various
product releases and schedules.

## 6.1. Power PC Workstation Release

### 6.1.1 Deliverables

This section contains a description of the deliverables.

### 6.1.2 Base System

### 6.1.3 Windows

### 6.1.4 Network

### 6.1.5 Schedule

This section section contains the schedule for major milestones.

### 6.1.6 Dependencies

This section contains the dependencies on other groups.

User-Ed, Testing, Languages, Lan, Windows-32.

### 6.1.7 Issues

This section contains any issues that need to be called out.

## 6.2. Multiprocessor Server Release

### 6.2.1 Deliverables

This section contains a description of the deliverables.

### 6.2.2 Base System

### 6.2.3 Windows

### 6.2.4 Network

### 6.2.5 Schedule

This section section contains the schedule for major milestones.

### 6.2.6 Dependencies

This section contains the dependencies on other groups.

User-Ed, Testing, Languages, Lan, Windows-32.

### 6.2.7 Issues

This section contains any issues that need to be called out.

## 6.3. Full Workstation Release

### 6.3.1 Deliverables

This section contains a description of the deliverables.

### 6.3.2 Base System

### 6.3.3 Windows

### 6.3.4 Network

### 6.3.5 Schedule

This section section contains the schedule for major milestones.

### 6.3.6 Dependencies

This section contains the dependencies on other groups.

User-Ed, Testing, Languages, Lan, Windows-32.

### 6.3.7 Issues

This section contains any issues that need to be called out.

# 7. Product/Major Milestone Descriptions and Schedules

The development strategy that is being followed is to

The next major milestone in the development of **NT OS/2** will be the
ability of the operating system to host its own development. This is
planned to be operational on both the x86 and the MIPS RISC PC in Q1'91.

This milestone will be followed by a beta quality field test SDK that
will be available on the MIPS RISC PC and Compaq 486 systems in Q3'91.

The first retail product will be a MIPS RISC PC that supports the
Windows 32-bit APIs, is network enabled, provides a robust and secure
operating environment, and is capable of competing with UN*X systems. A
secondary goal for this product is the support for Compaq 486 systems.
The target date for this product is Q1'92.

The second retail product is aimed at providing a robust and secure
platform for scalable performance LanMan servers. This release will
support multi-processor 486 systems (possibly also MIPS RISC
multi-processor systems as well) and will support all the network
services and NDIS drivers necessary to compete with Novell on 386 and
486 systems. The target date for this product is H2'92.

The third retail product is aimed at providing a full workstation
capability for 368 and 486 systems that is certifiably secure, contains
support for DOS and Windows 16-bit applications, and also supports the
OS/2 32-bit base system APIs. The target date for this product is
somtime in 93.

What products have an OAK? DDK?

# 8. Project Goals

# 9. Dependencies

The **NT** operating system products are dependent on several groups to
provide necessary components for the various product releases.

## 9.1. Languages Group

The **NT** effort is dependent on the languages group to deliver the
necessary programming tools for the 386, 486, and MIPS platforms to
support self hosted development.

Programming tools to be supplied by the languages group are split into
two groups; those required for 386 and 486 development, and those
required for MIPS development. All tools must be ported to the **NT**
environment and run under the **NT** operating system.

The following is a list of the 386 and 486 tools to be delivered by the
languages group:

76. C compiler with structured exception handling.

77. x86 Assembler.

78. Linker capable of producing **NT** format images.

79. User debugger capable of supporting multi-thread debugging.

80. Kernel debugger capable of supporting multi-processor debugging.

The following is a list of the MIPS tools to be delivered by the
languages group:

81. User debugger capable of supporting multi-thread debugging.

82. Kernel debugger capable of supporting multi-processor debugging.

The languages group is also planning to deliver a C compiler for MIPS
that supports structured exception handling. However, this compiler will
not be available for use in time to support the self hosting of **NT**
development. Therefore, the MIPS C compiler, which also supports
structured exception handling, is being ported to the **NT** environment
as a backup.

A linker capable of linking MIPS object modules into an executable image
will be provided by the NT Base System group.

The MIPS assembler is being ported to o the NT OS/2 environment to
support self hosting and product develoment in assembly language.

C++?? C++ seh??

## 9.2. LanMan Group

Lan group for UI components, RPC stub compiler and runtime, TCP/IP
transport and utiltiies.

## 9.3. Testing Group

Testing group for ??

## 9.4. User Ed Group

NT system services manual - who does?

Driver writers course?

NDIS driver writers course.

Where will the documentation for the MIPS compiler and assembler come
from? Who will do?

# 10. Hardware Plans

---

## `dwintro.doc` — NT OS/2 Design Workbook Introduction

*Author: Lou Perazzoli*  
*Revision 6.0, July 25, 1990*

Portable Systems Group

NT OS/2 Design Workbook Introduction

**Author:** Lou Perazzoli

Original Draft 1.0, March 31, 1989

Revision 2.0, May 5, 1989

Revision 3.0, August 17, 1989

Revision 4.0, October 15, 1989

Revision 5.0, January 15, 1990

Revision 6.0, July 25, 1990

Keep this hidden text for spacing.

***Hardcopy released to The Smithsonian Institute.***

***Digital copy released to Universities for non-commercial academic use
under the Windows Research Kernel License.Keep this hidden text for
spacing.***

# 1. Introduction

The **NT OS/2** system is a portable implementation of OS/2 developed in
a high-level language. The initial release of **NT OS/2** is targeted
for Intel 860-based hardware, which includes both personal computers
(*Frazzle*) and servers (*Dazzle*).

The first systems based on a RISC microprocessor will be available for
testing in the fall of 1990.

# 2. Project Goals

The ultimate goal of the **NT OS/2** project is to develop a portable
implementation of OS/2 executing on the Intel 860 and to establish this
combination of hardware and software as the standard for
high-performance personal computers and server systems.

**NT OS/2** has the following overall project goals (though not all
these goals will be attained by the first implementation of **NT
OS/2**):

- Portability to a variety of hardware architectures. Though the first
implementation is targeted to the Intel 860, the overall system design
isolates the machine-dependent portions for portability to other
architectures.

- Support for multiple processors with shared memory via symmetric
multiprocessing. This provides performance improvements for
multiprocessor workstations and servers.

- Compatibility with the OS/2 V2.0 32-bit application programming
interface (API). Because the initial target system is not an Intel x86
architecture, all applications will have to be recompiled and relinked.
In addition, any assembly language code will have to be rewritten or
converted to a higher level language such as C.

- Security at the C2 level with future versions achieving higher levels
of security. This includes login/logout options on the personal computer
and the server system, and declaration and enforcement of protection
attributes for shareable resources (files, IPC, memory objects, etc.).

- Support for a POSIX-compliant API interface that passes the POSIX
validation suites.

- Support for internationalization.

- Support for LANMAN networking and management of personal computers and
servers.

- Support for the current Presentation Manager API running in both the
OS/2 environment and the POSIX environment.

- Support for distributed applications. The network is integrated into
the system to allow transparent distribution of applications and
services within a network.

- Support for object-oriented file systems and object-oriented
presentation manager.

- Easy extensibility by layering new features on the existing system
without modifying the underlying system.

- Simultaneous execution by multiple users, each with a unique security
profile.

- Interoperability and data interchange between OS/2 and POSIX
applications.

- High reliability that prevents errant user programs from causing a
system crash or exhausting system-wide resources. Resource quotas, a
protected kernel, and protected objects are used to improve reliability.

# 3. NT OS/2 Components

**NT OS/2** consists of a highly integrated kernel / executive that
executes in kernel mode. It provides the necessary services to allow the
emulation of OS/2 and POSIX APIs via protected subsystems executing in
user mode. Both the OS/2 and POSIX subsystems provide these services
through remote procedure calls from a client to the server subsystem.
The server subsystem, in turn, emulates the desired operation locally or
by calling the executive, and returns the results to the caller. The
following diagram illustrates the structure of **NT OS/2**.

```
Ö‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ì Ö‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ì

° OS/2 ° ° POSIX °

° Processes ° ° Processes °

Û‑‑‑‑‑‑‑‑‑‑‑‑‑‑ì Û‑‑‑‑‑‑‑‑‑‑‑‑‑‑ì

° ° ° °

V ° ° V

Ö‑‑‑‑‑‑‑‑‑Ì ° ° Ö‑‑‑‑‑‑‑‑‑Ì

°OS/2 ° ° ° °POSIX °

°Subsystem° ° ° °Subsystem°

Û‑‑‑‑‑‑‑‑‑ì ° ° Û‑‑‑‑‑‑‑‑‑ì

° ° ° ° ° °

° V V V V °

Ö‑‑‑‑‑‑‑‑‑Ì ° Ö‑‑‑‑‑‑‑‑‑‑‑‑‑Ì ° Ö‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ì

° Session ° ° °Presentation ° ° ° Security °

° Manager °‑> ° °Manager ° ° <‑ ° Authenticator °

Û‑‑‑‑‑‑‑‑‑ì ° Û‑‑‑‑‑‑‑‑‑‑‑‑‑ì ° Û‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑ì

° ° ° ° °
```

V V V V V

User Mode

\====================================================================

Kernel Mode

**NT OS/2 Executive**

```
Ö‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ì

° NT OS/2 APIs °

û‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ú‑‑‑‑‑‑‑‑‑‑‑‑Ú‑‑‑‑‑‑‑‑‑‑‑‑Ú‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ú‑‑‑‑‑‑‑‑‑‑À

° I/O ° Object ° Memory °Interprocess ° Process °

° System ° Management ° Management °Communication ° Structure°

û‑‑‑‑‑‑‑‑‑Ì ° ° ° ° °

° File ° ° ° ° ° °

° System ° û‑‑‑‑‑‑‑‑‑‑‑‑Ù‑‑‑‑‑‑‑‑‑‑‑‑Ù‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ù‑‑‑‑‑‑‑‑‑‑À

° Devices ° ° Executive Support Routines °

û‑‑‑‑‑‑‑‑‑Ù‑‑‑‑‑Ù‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ú‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑À

° Device Drivers ° °

° Ö‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑ì °

° ° Kernel °

Û‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑Ù‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑‑ì
```

**Block Diagram of NT OS/2**:

# 4. Functional Specifications

The following specifications are contained within this design workbook.
Each specification contains an abstract of the component it describes,
how that component fits into the system, the various APIs that are used
to access the functionality, and enough detail to ensure the defined
capability can be implemented.

The goal of the specifications is to allow someone to understand the
functionality provided by a particular piece of the system. It is NOT a
goal to describe the actual implementation.

Each specification addresses Cruiser and POSIX compatibility, if
appropriate. The following is a list of design specifications included
in this version of the workbook:

1. Kernel - Describes the function of the kernel, the objects
implemented, and the various interfaces provided to manipulate these
objects. This specification contains implementation details, where
necessary, to reveal how multiprocessing and processor dispatching take
place. This specification also describes synchronization,
scheduling/dispatching, and Asynchronous Procedure Calls (APCs).

2. Object Management - Describes how the executive deals with objects,
what they are for, how they are protected, how they are named, how they
are allocated, how they are accounted for, and how they are deleted.
This specification also addresses object directories and how to access
them using the file system directory operations.

3. Process Structure - Describes the process and thread objects and the
operations that can be performed on them. This specification also
explains signals and how OS/2 compatibility and POSIX compliance are
addressed.

4. Virtual Memory - Describes the virtual memory objects and the
operations that can be performed on these objects.

5. I/O Management - Describes the APIs and objects available for I/O
operations.

6. Security - Describes how security is provided in the system, the ACL
format, ACL access checking rules, login/logout, the authorization file,
and the partial closure of covert channels. This specification also
describes audit and alarm logging.

7. Local Process Communication - Describes the client/server protected
subsystem model, client impersonation, port objects, and
connection/disconnection operations.

8. Remote Procedure Call - Describes a transport-independent interface
to remote procedure calls.

9. Session Manager - Describes how the subsystems for OS/2 and POSIX
are created, and how they interact with each other.

10. File System - Describes the file systems, how they are put
together, the functions they perform, and how they accomplish the tasks
that they are given.

11. Semaphores and Events - Describes the APIs and objects available
for synchronization.

12. Argument Validation - Describes the argument probing and capture
requirements for system services.

13. Timers - Describes the timer object, which is used to mark time,
and the functions available to manipulate it.

14. Coding Guidelines - Describes the naming and structure of **NT
OS/2** code.

15. LAN Manager Software - Describes the network capabilities of the
system, how network drivers fit together, and how the protocol stacks
are managed.

16. Exceptions - Describes the dispatching of hardware exceptions to
the condition dispatcher and the arguments that accompany each
exception. It also explains guard page handling, automatic stack
expansion, and access violations on the user stack, as well as how
signals are handled at the user level.

17. OS/2 Emulation Subsystem - Describes the requirements and methods
used to design and build the OS/2 emulation subsystem.

18. Status values - Describes the format for status values return by
**NT OS/2** APIs.

19. Subsystem Design Rational - Describes the rationale for designing
OS/2 and POSIX emulation as subsystems as opposed to supporting the APIs
directly in the executive.

20. Shared Resource Specification - Describes the routines that
implement multiple-readers, single-writer access to a share resource.

21. Executive Support Routines - Describes executive support routines
which are available in kernel mode and not documented in other chapters.

22. Driver Model - Describes the device driver model, how I/O is
managed throughout the system, how the file system and network
capabilities fit into the system, and the objects and operations that
are available to help manage the I/O system. It also presents I/O
validation, queueing, page lockdown, double mapping, I/O completion, and
error logging.

23. POSIX Emulation Subsystem - Describes the requirements and methods
used to design and build the POSIX emulation subsystem.

24. Time Conversion Specification - Describes the APIs available for
viewing time and converting to and from different formats.

25. Mutant Specification - Describes the mutant object and services
which operate upon the object.

26. Transport Driver Interface - Describes the interface for the
network transport layer.

27. Network Driver Interface Specification - Describes the interface
for the network physical layer.

28. Lan Manager Server - Describes the design of the Lan Manager server
and the operations supported.

29. C Structured Exception Handling - Describes the extensions to C in
the MS 860 compiler to support structured exception handling.

30. NT C User's Guide - Describes the command syntax and language
issues for the MS 860 C compiler.

31. Prefix Table - Describes the prefix table package.

32. System Startup Design Note - Describes system startup after phase
one initialization.

33. Debug Architecture - Describes the debug architecture for NT OS/2.

34. Linker/Librarian - Describes the NT OS/2 linker, librarian, and
image format.

35. Caching Design Note - Describes the system-wide file caching
implementation.

36. Utility Design Specification - Describes the basic support routines
for NT OS/2 utilities.

37. OS/2 Environment Subsection Security - Describes the security
features of the OS/2 environment subsystem.

38. Security Account Manager Protected Server - Describes the security
account manager which maintains user and group account information.

**Revision History:**

Original Draft 1.0, March 31, 1989

Revision 2.0, May 5, 1989

1. The following specifications were added to the design workbook:

- Local Process Communication

- File Systems

- Session Manager

- Semaphores and Events

- Argument Validation

- Timers

- Coding Guidelines

2. The in-progress specification list was changed to add the OS
Emulation Environment specification.

3. The block diagram was modified.

Revision 3.0, August 17, 1989

1. The following specifications were added to the design workbook:

- Subsystem Design Rationale

- Status Codes

- Shared Resources

- Executive Support Routines

- User-mode Interlocked and Fast Lock Routines

- OS/2 Subsystem Emulation

Revision 4.0, October 15, 1989

1. The following specifications were added to the design workbook:

- POSIX Subsystem Emulation

- Time Conversion Specification

2. The User-mode Interlocked and Fast Lock Routines Specification was
dropped because the APIs were non-portable.

3. The specification list was revised to match the actual
specifications in the workbook.

4. The File System Specification was replaced by the File System Design
Note.

5. The I/O System Specification was broken into two separate
specifications:

- I/O System Specification - Documents I/O system API

- Driver Model Specification - Documents drivers and I/O system
internals

Revision 5.0, January 15, 1990.

1. The following specifications were added to the design workbook:

- Mutant Specification

- Transport Driver Interface

- Physical Driver Interface

- Lan Manager Server

- C Structured Exception Handling

- NT C User's Guide

Revision 6.0, July 25, 1990.

1. The following specifications were added to the design workbook:

- System Startup Design Note

- Debug Architecture

- OS/2 Linker/Librarian/Image Format Specification

- Caching Design Note

- Utility Design Specification

- OS/2 Environment Subsystem Security

- Security Account Manager Protected Server

---

## `ntdesrtl.doc` — NT OS/2 Subsystem Design Rationale

*Author: Mark H. Lucovsky*  
*Revision 1.3, June 1, 1989*

Portable Systems Group

NT OS/2 Subsystem Design Rationale

**Author:** Mark H. Lucovsky

Revision 1.3, June 1, 1989

Original Draft, May 26, 1989

# 1. The NT OS/2 Mission

The **NT OS/2** group was formed with a clear mission:

- To design and implement an OS/2-compatible operating system for
non-x86 hardware platforms

- To support the APIs required by POSIX (IEEE Std 1003.1-1988) at a
level required to pass government validation

- To support symmetric multiprocessing

- To provide C2 security features with a path to B1 and beyond

- To provide easy portability to other 32-bit architectures

- To design and implement the first functional system by the 3rd quarter
of 1990

- To target the system for a **Microsoft**-designed i860 PC hardware
platform, followed shortly thereafter by an i860mp or N11
multi-processor server system

Conclusions from the January 1989 System Retreat indicated that
**NT OS/2** is critical to the long-term growth of **Microsoft**. The
design of the system must accommodate current and future needs of
**Microsoft**. The design must be maintainable, and easily extensible.

# 2. Design Goals

In order to achieve our mission, the following set of prioritized goals
was established:

1. Robustness. The highest priority for **NT OS/2** is robustness. The
inner workings of the system should be straightforward and well defined.
A complete and formal design on all components of the system must be
produced and interfaces and behavior must be well specified. The system
must be designed without "magic".

2. Extensibility and maintainability. **NT OS/2** must be designed with
the future in mind. It should be easily extensible to meet the needs of
our OEM customers and our own needs over time. The system should also be
designed for maintainability.

> Given the state of the API sets that **NT OS/2** must support, its
> design must accommodate changes and future additions to those sets.

3. Portability. **NT OS/2** must be designed for portability. The
system architecture must be portable across a number of platforms. There
are portions of the actual implementation that will require a port when
moving from platform to platform. The effort required to port **NT
OS/2** from one platform to another must be less than, or equal to, an
equivalent port of a UNIX or Mach system.

4. Performance. Superior performance in **NT OS/2** is important.
Algorithms and data structures that will lead to a high level of
performance and that will provide us with the flexibility needed to
achieve our other goals must be incorporated into the design. The
granularity of locking, the various types of locks used in the system,
the amount of time spent at an elevated interrupt level or with
interrupts completely disabled must be carefully designed so that **NT
OS/2** is a responsive system which can compete in a number of markets.

In addition to these goals, compatibility with OS/2 APIs and POSIX
compliance are system constraints in **NT OS/2**.

# 3. Design Alternatives Investigated

Several design alternatives for **NT OS/2** were considered during the
design phase.

The first design layered the POSIX API set on top of a slightly extended
OS/2 API set. As the design progressed, it became apparent that this
design would lead to a system that could not achieve the goals of
robustness, maintainability, or extensibility. Problems encountered with
a similar attempt in OS/2 led to considerable change in the base system
capabilities, which further strengthened the belief that this was a poor
alternative.

The next design implemented both OS/2 and POSIX API sets directly in the
**NT OS/2** executive. This was an improvement on the previous design,
but the large number of "chicken wire" and "voodoo" interfaces required
by this design threatened the goals of extensibility and
maintainability.

The third design implemented OS/2 and POSIX as protected subsystems
outside the **NT OS/2** executive. Success with this type of
client/server architecture in the academic community and at other
research sites provides strong evidence that this design will allow **NT
OS/2** to meet its goals of robustness, extensibility, maintainability,
portability, and performance, and thus, achieve its mission. Therefore,
this design was chosen for **NT OS/2**.

(The final section of this document examines the three **NT OS/2**
design alternatives in greater detail.)

# 4. The NT OS/2 Design

The **NT OS/2** system design consists of a highly functional executive,
which executes in kernel mode, and exports a native API (a set of system
services). Operating system environments such as OS/2 and POSIX are
implemented as protected subsystems outside the executive.

A protected subsystem executes in user mode as a regular (native)
process. The subsystem may have amplified privileges, but it is not
considered a part of the executive and, therefore, cannot bypass the
system security architecture, or in any other way corrupt the system.
Subsystems communicate with their clients and each other using a
high-performance local (cross-process) procedure call, or LPC,
mechanism. (A round-trip LPC completes in approximately 100usec on the
i860.)

This **NT OS/2** design satisfies each of the goals for the system. The
following attributes of the design ensure the primary goal of
robustness:

- The kernel mode portion of the system exports well-defined APIs that,
in general, do not have mode parameters or other "magical flags".
Therefore, the APIs are simple to implement, easy to test, and easy to
document.

- A formal design is being produced for all portions of the **NT OS/2**
system prior to coding. This effort has led to well-documented
interfaces for native services and internal functions.

- The partitioning of major components, such as PM, OS/2, and POSIX,
into separate subsystems is resulting in simple, elegant designs in the
subsystems. Each subsystem is optimized to implement only those features
needed to provide its API set.

- With the prevalent use of frame-based exception handlers, **NT OS/2**
and its subsystems are able to catch programming errors and filter bad
or inaccessible parameters in an efficient and reliable manner.

The **NT OS/2** design also meets its goals of maintainability and
extensibility through the following features:

- The **NT OS/2** design is simple and well documented. This, coupled
with a common coding standard used throughout the system, should enable
a programmer to work on any piece of the system without having to
consult the "gurus" to learn about hidden rules, side effects, or
"magical" programming tricks.

- By using subsystems to implement major portions of the system, **NT
OS/2** isolates and controls dependencies. For example, the only piece
of the **NT OS/2** system affected by the changing Cruiser design is the
OS/2 subsystem. The design of the process structure, memory management,
synchronization primitives, and so on, does not have to be put on hold.
The same holds true for the evolving POSIX standards.

- As the needs of **Microsoft** grow, the **NT OS/2** system is prepared
to accommodate those needs. Subsystems that provide additional
functionality can be added to the system without impacting the base
system. New subsystems can be added without having to modify the **NT
OS/2** executive or release a new version of the system.

> Subsystems such as DOS, Windows, or Xenix can be added to the system
> if necessary. OEMs could continue to provide limited support for
> operating system environments other than the **Microsoft**-provided
> OS/2 and POSIX environments.

- Using the subsystem or "building block" approach, it is possible to
envision a configuration that includes only the OS/2 subsystem. POSIX
could be a revenue-producing, licensable option. If the option were not
used, no system resources would be sacrificed.

- Subsystems need not bypass the security features present in
**NT OS/2**. Rather, they can use the security features to their
fullest extent.

**NT OS/2** portability is ensured by the following:

- Except for small, well-isolated sections of code, **NT OS/2** is
written in C. The system is being developed on prototype compilers with
limited functionality, and still, the design has yielded portable code.

- Using the UNIX and Mach porting experience of engineers on the
project, the group has established that the **NT OS/2** will port to
other platforms at least as easily as the UNIX or Mach operating
systems. The effort involved in porting **NT OS/2** to another 32-bit,
paged architecture, using readily available compilers, is small.

**NT OS/2** is a high-performance system designed to run on
high-performance hardware. We believe that the system will perform
better than any system providing equivalent functionality on equivalent
hardware. The following attributes of the system promote high
performance:

- Algorithms and execution paths through the system have been carefully
optimized to increase performance. Also, the modular nature of the
system allows performance optimization by replacing entire components.

- System calls, exceptions (page faults), LPC, thread creation, and I/O
have undergone scrutiny to ensure their speed. The round-trip time for a
null system call is currently on the order of 3usec (on a 40Mhz i860).
Given this number, **NT OS/2** performs better than most systems even
after equalizing processor speeds.

- Ensuring high performance is an ongoing activity in the implementation
of **NT OS/2**.

# 5. Performance in the Subsystem Model

Before committing the **NT OS/2** design to a subsystem, or
client/server model, time was spent analyzing the Presentation Manager.
One of the deficiencies in the current implementation of PM is that it
must manage global state without having any way to protect the state. We
worked with one of the designers and implementors of PM to develop a
solution to this problem by making PM a protected subsystem (which
executes in its own process context rather than in the context of the
thread that called a PM entry point).

Before proceeding with the PM design, the **NT OS/2** LPC mechanism was
designed. We felt that if the LPC design were solid, it could be
modeled, and we could determine whether or not PM performance would be
acceptable using a subsystem design model.

Ideas present in several high-performance LPC mechanisms were
incorporated into the **NT OS/2** design:

- The ability to efficiently pass small amounts of data, as was done in
Stanford's V system, is included.

- The idea of mapping large messages or passing large parameters
"out-of-band" is similar to the mechanism used in Carnegie Mellon's Mach
system.

- The ability to pass message data through memory shared between the
client application and the subsystem is similar to the technique used in
an experimental system under development at the University of
Washington, and which also appears in DEC's Topaz system.

With the design of the **NT OS/2** LPC mechanism complete, a model was
created to measure the performance impact of running PM as a protected
subsystem.

The model consisted of the following pieces of modified system software:

- OS/2 Kernel Modifications. A special version of OS/2 1.1 was built.
This version of the system had an additional system service that
simulated a context switch from the calling thread back to the calling
thread.[1] All of the work involved in switching address spaces was
simulated as well.

- *pmwin.dll* and *pmgpi.dll*. A new version of each of these libraries
was created. For each entry point, the cost of marshalling its
parameters into and out of a message buffer was simulated; two calls to
the new context switch routine were done; and finally, a call was made
to the original version of the entry point.

By running PM applications using the modified system software, we were
able to determine exactly how much overhead PM would incur when run as a
subsystem.

Several test cases were run on the model. These included running the
PMBENCH benchmark suite, running PMDRAW and drawing complicated
pictures, running various configurations of PM Excel and scrolling,
drawing charts, and performing other screen manipulations, and finally,
running a journaled interactive session with multiple PM applications
doing different tasks, including menu and dialog box operations.

Before running our tests, we did not know what to expect. We felt that
if the system did not feel sluggish, then the subsystem approach might
be acceptable. After running all of our tests, we were surprised. The
system performed so well that we could not tell the difference between
the subsystem version of PM and the normal version of PM.

The following table shows a condensed listing of our benchmark results:

LPC PM Standard Subsystem

Overhead PM Time PM Time Difference

PMBENCH Test Suite 5.14% *** *** ***

PMDRAW monticello 16.88% 12.403s 14.497s 2.094s

PMDRAW fish 8.80% 11.887s 12.940s 1.053s

Excel Scroll 1's 3.25% 30.880s 31.885s 1.005s

Excel Scroll Big 0.84% 63.060s 63.590s 0.530s

Excel Chart 9.65% 12.900s 14.145s 1.245s

Interactive 1.20% 335.510s 339.670s 4.160s

\=======

Average Overhead 2.16% 466.640s 476.727s 10.087s

From the results of our study, we felt that the additional overhead
imposed by running PM as a protected subsystem was acceptable given the
benefits of such a design. While there is measurable overhead, it is not
detectable when sitting in front of a machine running interactive or
graphics-intensive applications.

After determining that PM could be run as a protected subsystem without
incurring unacceptable performance degradation, we looked at other areas
of the system that would be cleaner to implement as a separate subsystem
but would not impact overall system performance.

Given that OS/2 and POSIX had to be treated as partitioned code within
the executive, they were natural candidates for implementation as
protected subsystems. We believe that real OS/2 (and POSIX) applications
will be more dependent on the performance of PM than any other portion
of the system. The ratio of PM to operating system service calls is
likely to range from 10:1 to 100:1. If PM is a good candidate for
implementation as a protected subsystem, then operating system
environments such as OS/2 or POSIX are also good (if not better)
candidates.

# 6. Standards

During the initial design phase of **NT OS/2**, a great deal of time was
spent examining ways to design a system that could support both the OS/2
and POSIX API sets. This job was complicated by the fact that both of
the API sets we planned to support were moving targets. In fact, the
Cruiser specification was not yet available; it is still evolving.

## 6.1 OS/2 Standards

Our initial OS/2 API set centers around the evolving 32-bit Cruiser, or
OS/2 2.0 API set. (The design of Cruiser APIs is being done in parallel
with the **NT OS/2** design.) In some respects, this standard is harder
to deal with than the POSIX standards. OS/2 is tied to the Intel x86
architecture and these dependencies show up in a number of APIs. Given
the nature of OS/2 design (the joint development agreement), we have had
little success in influencing the design of the 2.0 APIs so that they
are portable and reasonable to implement on non-x86 systems. In
addition, the issue of binary compatibility with OS/2 arises when the
system is back-ported to an 80386 platform. This may involve 16-bit as
well as 32-bit binary compatibility.

## 6.2 POSIX Standards

Our initial POSIX efforts center around the IEEE Std 1003.1-1988 (or
Draft 13). The spec is vague in several areas and contains several
optional features.

In order to sell in certain federal government markets, a POSIX
implementation must be compliant with FIPS 151. This FIPS requires that
certain optional features of POSIX be implemented, and also requires
portions of other POSIX standards (1003.2, "Applications and
Utilities"). In addition, the FIPS requires a certification of
conformance. This certificate can be obtained by passing a certified
POSIX test suite. The current set of test suites are developed by third
parties, and do test for compliance with the POSIX spec. Unfortunately
for us, the test suites were developed on UNIX systems that claim POSIX
compliance. The test suites end up testing a lot of UNIX folklore that
happens to be permissible under an interpretation of the POSIX spec.

To further complicate POSIX compliance, additional drafts of 1003.1,
which are close to approval, have been proposed. The effects of approval
are unknown. It is not clear if future additions to POSIX will be
required under future FIPS, or if additions will be made optional. The
government standards body that is issuing the FIPS is apparently ready
to add any approved POSIX drafts to its FIPS. The latest draft under
consideration (1003.1a), would add a number of features from Berkeley
UNIX 4.3 to POSIX. It is anticipated that a new FIPS will be issued
which requires these features in order to participate in certain
government markets.

# 7. An Analysis of the Design Alternatives

Once the mission and goals of **NT OS/2** were clear, the design work
was started. The most difficult portion of the design centered around
the issue of how to provide OS/2 and POSIX compliance on the same system
without failing to achieve our mission or compromising our goals.

Combining the APIs of multiple operating systems in a single system is
always a difficult task. It does not matter whether the APIs are similar
or different. The most striking example of this problem is the poor
integration of UNIX variants found in the current UNIX market.

In the beginning (1982-1984), there were basically two branches in the
UNIX tree. The BSD branch with Berkeley UNIX 4.2 and 4.3, and the AT\&T
System V branch with System V.2 and V.3. Companies that offered pure
systems in either camp were the norm. Companies in the scientific and
engineering markets supported BSD while business-oriented companies
supported System V:

- Sun 1.0-2.x was pure BSD

- DEC's ULTRIX was pure BSD

- Sequent was pure System V

- Altos was pure System V

After some time, companies began to offer systems with mixed features.
This began with systems advertising "System V with BSD networking."
Soon, nearly all companies offered systems with some features from both
environments. Applications could call APIs from either set. If the API
specified different behavior for a System V or a BSD implementation, it
was usually a tossup as to which semantics were followed.

The current state of System V and BSD integration is the root of nearly
all the confusion in the current UNIX marketplace. To port an
application that was originally BSD to a system that is "System V with
BSD features" requires elaborate configuration files that "pick and
choose" the APIs. With each port to a new system, the configuration
options and combinations must be expanded to accommodate the new system.
The popular UNIX editor, emacs, is a perfect example of this. The emacs
editor comes with nearly 50 configuration files. Each file describes a
derivative of UNIX that has different features and supports a certain
mix of BSD and System V APIs.

A major design issue in **NT OS/2** is to avoid the
integration-of-features problem present in the current UNIX marketplace.
**Microsoft** cannot afford to present POSIX and OS/2 integration as
poorly as most of the UNIX vendors have.

In the selected **NT OS/2** design, an application that uses OS/2 APIs
may only use OS/2 APIs. The POSIX API set is not available to the
application. The reverse restriction is also true. POSIX applications
may not call OS/2 APIs.

## 7.1 POSIX Layered on OS/2

The first alternative examined the feasibility of layering the POSIX API
set as a runtime package on top of a native system service interface
based on an OS/2 API set.

Using this approach, the **NT OS/2** executive would export an OS/2 2.0
API set. If there were functions that required extensions in order to
make this work, we were prepared to make those extensions. An example of
this approach is supporting POSIX *fork()* and *exec()* using OS/2's
DosExecPgm().

We proposed adding a flag to DosExecPgm that would take one of the
following values:

1. The API should work exactly as the current DosExecPgm function works
(that is, a new process is created and its address space is initialized
so that it maps the image specified as the program name parameter).

2 The API should create a process and the address space should be an
image of the address space of the calling process. Thread 1 should be
created in the new process and its initial context should be identical
to the context of the calling thread at the time of the call. The only
exception is that thread 1 in the new process must return with a
different return value than that returned by the calling thread.

3 The API should clean the address space of the process, terminate any
threads in the process, create a new address space such that it maps the
specified program image file, and create thread 1 so that it begins
execution at the entry point specified in the image.

To implement OS/2 DosExecPgm, the API would be called with flag value 1.
POSIX's *fork()* and *exec()* would be implemented using flag values 2
and 3.

On the surface, the above technique seems to work, but it is
complicated. Complications arise in the following areas:

- File descriptors owned by a process would be dealt with differently in
all three variations of DosExecPgm().

- File locks held by the process at the time of the API call would be
handled differently for all three cases. In fact, since file locking
itself is different, the case is really an 8-way case.

- Outstanding timers or process alarms have at least three different
actions.

- Signals pending, or the state of a process's signal or exception
handlers, is affected by the various API options.

The list of problems with this API is large, as should be clear from the
above list. More important, the problem seems to scale exponentially.
Simple operations like opening or creating files, establishing signal or
exception handlers, reading from and writing to the terminal, or even
manipulating regular files all have problems and virtually all require a
mode argument.

One of the other serious problems with this design alternative is that
it presents a poor integration of OS/2 and POSIX. It would be difficult
to separate OS/2 calls from POSIX calls. Multi-threaded OS/2
applications that, either on purpose or as a result of a programming
error, call DosExecPgm specifying a POSIX-oriented option would have
disastrous effects. We could always say that this could not happen, but
in order to achieve the robustness goals of the **NT OS/2** system, the
executive would have to be coded so that it could handle all possible
incorrect parameter combinations.

After determining that layering POSIX on top of OS/2 would bury much of
POSIX in the executive, and would cause most of the overlapping APIs to
require a mode parameter, we looked at ways of implementing the POSIX
API set directly inside the **NT OS/2** executive.

## 7.2 OS/2 and POSIX in the Executive

By implementing both the OS/2 and POSIX API sets directly within the
executive, we were able to work on a layered, controllable design. The
system would yield two API layers, one layer exporting OS/2 APIs and the
other layer exporting POSIX APIs. The API layers would be implemented on
top of an executive support layer.

The executive support layer would implement basic executive services
such as process and address space management, thread
creation/deletion/control, security, an I/O system and a file system.
The executive support layer would control, create, and delete all state
in the system. The API layers would simply call the executive support
layer with appropriate parameters. They would not maintain state.

As we progressed with this design, it became clear that it was nearly
identical to our initial design. Our proposals for the design of the
process structure were not much different from the extensions that we
had planned for DosExecPgm(). The primary difference was that the
parameter combinations passed to the executive layer were controllable.
Since the parameters came from the system code that implemented the API
layers, we were able to make rules and declare that certain parameter
combinations could not occur. This made the executive layer somewhat
easier to write, but the rules for calling the executive became rather
elaborate.

For **NT OS/2** to remain a product that could carry **Microsoft**
through the 1990's, maintainability, extensibility, and robustness had
to be ensured. It seemed that almost everything became an exception. The
well-defined interfaces within the process structure became littered
with exceptions and kludges needed to support the demands of POSIX's job
control option or OS/2's complex process/command subtree relationships.
Simple functions, such as waiting on a child process (common to both
OS/2 and POSIX), became difficult to implement because the executive had
to manage two slightly different cases.

As each new issue arose, the solution always seemed to have a common
theme...

The terminal driver could look to see if the application writing to the
terminal was a POSIX application. If so, then if the terminal was not
the controlling terminal for the process, but the process was not
ignoring SIGSTOP, then the process could be signaled and its parent
notified.

or...

When a process terminates, look to see if it was an OS/2 application or
if it was a POSIX application. If it was an OS/2 application that was
*exec*'d using EXEC_SYNC, then after termination is complete, the
process ID is available for re-use. If it was a POSIX application, then
if the parent was not PID 1, signal it. If the process was a session
group leader, then generate a SIGHUP signal to all members of the
session group with the same controlling terminal, and possibly free the
controlling terminal.

The more the design progressed, the more the system started to look like
a bowl of spaghetti. Problems arose due to subtle differences between
OS/2 and POSIX in almost all areas. The following are a few examples of
the problems:

- Process ID (PID). The POSIX job control option (required by FIPS 151)
is difficult to implement correctly even on a BSD UNIX system. Process
relationships and the lifetime of a PID are complex. A POSIX PID has
nothing in common with an OS/2 PID other than sharing the same acronym.

> The standard solution to this sort of problem usually involved a
> "table off to the side" that could keep track of the differences. We
> had "tables off to the side" for POSIX and OS/2 process IDs, POSIX
> sessions, job control sessions, controlling terminal IDs, file and
> file system serial numbers (device, inode pairs, etc.), and others.

- Exception handling. POSIX requires an exception handling mechanism
based on signals that are similar to signals found in Berkeley UNIX 4.3.
This architecture is drastically different from the current 16-bit OS/2
exception architecture and even more different than portions of the
proposed OS/2 2.0 exception architecture.

> The exception architectures of both systems involve large portions of
> the entire system. The keyboard, video, and terminal drivers are
> involved, as is the process structure, system service dispatcher, trap
> handler, and so on.
>
> Trying to tie together these different pieces of the system in a way
> in which they could all participate in exception handling was
> seriously compromising the design of the system.
>
> The solution to this sort of problem usually involved adding fields to
> the process or thread structures to keep track of this. It became
> clear that our process and thread structures were going to be large.
> Much of the overhead was due to link words and pointers to the "tables
> off to the side," or to fields that were needed only if the process or
> thread represented a POSIX application (or OS/2 application).

- Security. POSIX security impacts major pieces of the system. As the
design progressed, it became clear that POSIX security was at odds with
the Cruiser-like security scheme being designed for **NT OS/2**. Many
features of the security scheme would have to be bypassed in order to
implement the "hodge podge" of security features/APIs that appear in
POSIX.

The list of chicken wire fixes is endless. Nearly all areas of the
system are involved, including timers, time-of-day format, file locks,
pipes, and many others.

The only advantage that this solution had over the previous one was that
the API layer could call the executive support layer with a known set of
parameter combinations. The executive support layer did not have to deal
with illegal parameter combinations.

**NT OS/2** had to explore some new alternatives. What we needed was a
mechanism that would allow the OS/2 API layer to manage and control all
state for all of the OS/2 applications in the system, and to allow the
POSIX API layer to do the same for all of its applications. It was this
realization that brought us to the current design strategy for **NT
OS/2**.

## 7.3 POSIX and OS/2 as Subsystems

The system architecture chosen for **NT OS/2** allows it to achieve its
goals and, therefore, fulfill its mission. **NT OS/2** is designed with
a small, non-preemptible kernel, which executes in kernel mode. A small
but highly functional, preemptible, interruptible, and reentrant
executive, which also executes in kernel mode and which exports a number
of system service APIs, is layered on top of the kernel.

The APIs exported by the executive do not implement either the OS/2 or
POSIX API sets. Instead, they export a set of APIs that allow both an
OS/2 API set and a POSIX API set to be implemented entirely in user mode
as separate processes running as protected subsystems. Using this
approach, an OS/2 or POSIX API is emulated using the following sequence:

- An application calls the local stub for an API function.

- The stub packages the arguments into a message and transmits the
message to either an OS/2 or POSIX subsystem using the **NT OS/2** local
procedure call mechanism.

- The subsystem receives the message, implements the API, and replies to
the application using LPC.

- The local stub receives the reply and returns the results to the
application.

The APIs exported by the **NT OS/2** executive are powerful, but at the
same time, are simple and straightforward. There are no cases in which a
single flag parameter changes the entire meaning of an API. This design
technique allows **NT OS/2** to achieve its goals of robustness,
extensibility, and maintainability.

Implementing OS/2 and POSIX as subsystems allows each subsystem to
implement only the set of semantics required by that subsystem. The
requirements of the subsystems do not translate into "tables off to the
side" or extra fields in data structures managed by the executive. When
a subsystem needs to keep track of additional state associated with an
object, it does so in its own data structures managed in the address
space of the subsystem. This technique leads to more elegant solutions
to problems posed by OS/2's process relationships or by POSIX's job
control data structures.

Rather than having to bypass most of the security features present in
**NT OS/2**, subsystems are able to use the security features to their
fullest extent. The security architecture, along with the high
performance LPC mechanism and powerful process structure and memory
management APIs allow the subsystems to increase the robustness,
extensibility and maintainability of the system while at the same time
decreasing the demands on system resources.

##

1.  <sup>*</sup> This simulation involved invalidating mapping
    information, saving and restoring registers, and saving and
    restoring the mapping information.

