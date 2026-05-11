# NT OS/2 IRP Language Definition

*Author: Gary D. Kimura*  
*Revision 1.0x, December 15, 1989*

Source: `stuff/docs/irp.doc` (transcribed via soffice + pandoc + cleanup-md.py).

---

Portable Systems Group

NT OS/2 IRP Language Definition

**Author:** Gary D. Kimura

Revision 1.0x, December 15, 1989

# 1. Introduction

The purpose of this chapter is to define the semantic contents of an I/O
Request Packet (IRP). The information contained here is intended for use
mainly by Device Driver and File System developers. The I/O system sends
to the various Device Drivers[1] a stream of multiple IRPs that the
drivers must interpret and respond to. Figure 1 shows the relationship
between the device driver and the I/O system. Communication between the
I/O system and the Device Driver is through IRPs. This chapter
concentrates on the IRP language.

> \+--------+ +--------+ +--------+
> | | | | | |
> | User | NtCall | I/O | Irp | Device |
> | |---------->| System |---------->| Driver |
> | | | | | |
> \+--------+ +--------+ +--------+
>
> Figure 1
> Logical control flow from user to Device Driver

Each IRP has a well defined format and semantic meaning, and the order
in which they are sent must adhere to certain rules. The ordering of
IRPs and responses form a context sensitive language.

Each IRP contains a common header section followed by one or more
function specific records (also called IRP stack locations). From a
Device Drivers viewpoint each IRP request is a single record describing
one function to perform. That is, the drivers only interpret one
function specific record. The additional stack locations are for use
when a driver issues subsequent IRPs to a lower level driver and wishes
to reuse the original IRP.

Each IRP function is identified by a major and minor function field in
the IRP stack location record. The list of possible function
combinations are listed below. Each line lists a major function code
followed (in paranthesis) by a minor function code. Note that some major
functions (e.g., CREATE) do not make use the minor function field.

CLOSE()
CONFIGURATION_CONTROL(...)
CREATE()
DEVICE_CONTROL(...)
DIRECTORY_CONTROL(NOTIFY_CHANGE_DIRECTORY)
DIRECTORY_CONTROL(QUERY_DIRECTORY)
FILE_SYSTEM_CONTROL(DISMOUNT_VOLUME)
FILE_SYSTEM_CONTROL(LOCK_VOLUME)
FILE_SYSTEM_CONTROL(MOUNT_VOLUME)
FILE_SYSTEM_CONTROL(QUERY_INFO_FILE_SYSTEM)
FILE_SYSTEM_CONTROL(SET_INFO_FILE_SYSTEM)
FILE_SYSTEM_CONTROL(UNLOCK_VOLUME)
FILE_SYSTEM_CONTROL(VERIFY_VOLUME)
INTERNAL_DEVICE_CONTROL(...)
LOCK_CONTROL(LOCK)
LOCK_CONTROL(UNLOCK_ALL)
LOCK_CONTROL(UNLOCK_SINGLE)
QUERY_ACL()
QUERY_EA()
QUERY_INFORMATION()
QUERY_VOLUME_INFORMATION()
READ()
READ_TERMINAL()
SET_ACL()
SET_EA()
SET_INFORMATION()
SET_NEW_SIZE()
SET_VOLUME_INFORMATION()
WRITE()

```c
/* We need to define the minor function codes for the configuration,
device, and internal device function codes. */
```

Each Device Driver will only receive a combination of the preceding
function codes based on the drivers device type. This means that a file
system device driver can expect to receive different functions than the
keyboard device driver, or a disk driver. The possible device driver
types are:

Disk Driver,
File System (including network redirector),
Keyboard Driver,
Mouse Driver,
Network Drivers,
Sound Driver,
Tape Driver,
Terminal Driver, and
Video Driver,

```c
/* We will need to futher expand on the different network device
drivers */
```

The remainder of this chapter describes the valid combination of IRP
function codes that each different device driver can expect to receive.
This is followed by a section listing every IRP function code along with
a description of the function's parameters, semantics, and I/O
completion status codes.

# 2. Valid IRP Function Combinations

The section contains an individual table for each device driver type
that lists the set of valid IRP functions that can be sent to the driver
and under what conditions the functions are sent.

## 2.1 Disk Driver IRPs

The set of possible IRPs that can be sent to a disk driver are:

<table>
<tbody>
<tr class="odd">
<td>IRP Function</td>
<td>When sent</td>
<td></td>
</tr>
<tr class="even">
<td>CLOSE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>CREATE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>DEVICE_CONTROL<br />
(...)</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>READ</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>WRITE</td>
<td>Anytime.</td>
<td></td>
</tr>
</tbody>
</table>

## 2.2 File System IRPs

The set of possible IRPs that can be sent to a file system are:

<table>
<tbody>
<tr class="odd">
<td>IRP Function</td>
<td>When sent</td>
<td></td>
</tr>
<tr class="even">
<td>CLOSE</td>
<td>Only after a successful CREATE and then only on an opened file. This closes the file so no other operation can be performed on the file other than CREATE.</td>
<td></td>
</tr>
<tr class="odd">
<td>CREATE</td>
<td>Only after a successful MOUNT_VOLUME and then only on a mounted volume that is not locked. If successful the file is considered opened.</td>
<td></td>
</tr>
<tr class="even">
<td>DIRECTORY_CONTROL<br />
(NOTIFY_CHANGE_DIRECTORY)</td>
<td>Only after a successful CREATE and then only on an opened directory file.</td>
<td></td>
</tr>
<tr class="odd">
<td>DIRECTORY_CONTROL<br />
(QUERY_DIRECTORY)</td>
<td>Only after a successful CREATE and then only on an opened directory file.</td>
<td></td>
</tr>
<tr class="even">
<td>FILE_SYSTEM_CONTROL<br />
(DISMOUNT_VOLUME)</td>
<td>Only after a successful MOUNT_VOLUME and then only on a mounted volume. This dismounts the volume, so no other operation can be performed on the volume other than MOUNT_VOLUME.</td>
<td></td>
</tr>
<tr class="odd">
<td>FILE_SYSTEM_CONTROL<br />
(LOCK_VOLUME)</td>
<td>Only after a successful CREATE and then only on an opened file. This locks the volume containing the file such that no other creates using the same volume will succeed until the volume is unlocked. To be successful, the file used to lock the volume must also be the only opened file on the volume.</td>
<td></td>
</tr>
<tr class="even">
<td>FILE_SYSTEM_CONTROL<br />
(MOUNT_VOLUME)</td>
<td>Anytime. If the operation is successful then a new device object for the volume is created and the volume is considered mounted and not locked.</td>
<td></td>
</tr>
<tr class="odd">
<td>FILE_SYSTEM_CONTROL<br />
(QUERY_INFO_FILE_SYSTEM)</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="even">
<td>FILE_SYSTEM_CONTROL<br />
(SET_INFO_FILE_SYSTEM)</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="odd">
<td>FILE_SYSTEM_CONTROL<br />
(UNLOCK_VOLUME)</td>
<td>Only after a successful CREATE and then only on a opened file. The file system must handle the situation where the user is attempting to unlock a volume that is not locked. If successful this operation unlocks a previously locked volume so that other creates using the volume can now succeed.</td>
<td></td>
</tr>
<tr class="even">
<td>FILE_SYSTEM_CONTROL<br />
(VERIFY_VOLUME)</td>
<td>Only after a successful MOUNT_VOLUME and then only on a mounted volume.</td>
<td></td>
</tr>
<tr class="odd">
<td>LOCK_CONTROL<br />
(LOCK)</td>
<td>Only after a successful CREATE and then only on an opened file. If successful this operation locks a range of bytes within a file. The locks remain in affect until they are explicitly unlocked or the file is closed.</td>
<td></td>
</tr>
<tr class="even">
<td>LOCK_CONTROL<br />
(UNLOCK_ALL)</td>
<td>Only after a successful CREATE and then only on an opened file. The file system must handle the situation where an unlock is received even though there are no outstanding locks for that user.</td>
<td></td>
</tr>
<tr class="odd">
<td>LOCK_CONTROL<br />
(UNLOCK_SINGLE)</td>
<td>Only after a successful CREATE and then only on an opened file. The file system must handle the situation where an unlock is received even though there is not a corresponding lock.</td>
<td></td>
</tr>
<tr class="even">
<td>QUERY_ACL</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="odd">
<td>QUERY_EA</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="even">
<td>QUERY_INFORMATION</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="odd">
<td>QUERY_VOLUME_INFORMATION</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="even">
<td>READ</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="odd">
<td>SET_ACL</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="even">
<td>SET_EA</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="odd">
<td>SET_INFORMATION</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="even">
<td>SET_NEW_SIZE</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="odd">
<td>SET_VOLUME_INFORMATION</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
<tr class="even">
<td>WRITE</td>
<td>Only after a successful CREATE and then only on an opened file.</td>
<td></td>
</tr>
</tbody>
</table>

## 2.3 Keyboard Driver IRPs

The set of possible IRPs that can be sent to the Keyboard driver are:

<table>
<tbody>
<tr class="odd">
<td>IRP Function</td>
<td>When sent</td>
<td></td>
</tr>
<tr class="even">
<td>CLOSE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>CREATE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>DEVICE_CONTROL<br />
(...)</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>QUERY_INFORMATION</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>READ</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>SET_INFORMATION</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>WRITE</td>
<td>Anytime.</td>
<td></td>
</tr>
</tbody>
</table>

## 2.4 Mouse Driver IRPs

The set of possible IRPs that can be sent to the Mouse driver are:

<table>
<tbody>
<tr class="odd">
<td>IRP Function</td>
<td>When sent</td>
<td></td>
</tr>
<tr class="even">
<td>CLOSE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>CREATE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>DEVICE_CONTROL<br />
(...)</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>QUERY_INFORMATION</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>READ</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>SET_INFORMATION</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>WRITE</td>
<td>Anytime.</td>
<td></td>
</tr>
</tbody>
</table>

## 2.5 Network Drivers IRPs

The set of possible IRPs that can be sent to the Network drivers are:

|              |           |
| ------------ | --------- |
| IRP Function | When sent |

```c
/* This table needs to be filled in */
```

## 2.6 Sound Driver IRPs

The set of possible IRPs that can be sent to the Sound driver are:

|              |           |
| ------------ | --------- |
| IRP Function | When sent |

```c
/* This table needs to be filled in */
```

## 2.7 Tape Driver IRPs

The set of possible IRPs that can be sent to the Tape driver are:

|              |           |
| ------------ | --------- |
| IRP Function | When sent |

```c
/* This table needs to be filled in */
```

## 2.8 Terminal Driver IRPs

The set of possible IRPs that can be sent to the Terminal driver are:

|              |           |
| ------------ | --------- |
| IRP Function | When sent |

```c
/* This table needs to be filled in */
```

## 2.9 Video Driver IRPs

The set of possible IRPs that can be sent to the Video driver are:

<table>
<tbody>
<tr class="odd">
<td>IRP Function</td>
<td>When sent</td>
<td></td>
</tr>
<tr class="even">
<td>CLOSE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>CREATE</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>DEVICE_CONTROL<br />
(...)</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>QUERY_INFORMATION</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>READ</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="odd">
<td>SET_INFORMATION</td>
<td>Anytime.</td>
<td></td>
</tr>
<tr class="even">
<td>WRITE</td>
<td>Anytime.</td>
<td></td>
</tr>
</tbody>
</table>

#
3. IRP Function Descriptions

This section describes the input parameters and semantics for each IRP
function code. It also discusses the interactions between the parameters
and lists possible return status codes.

The parameter descriptions list all the fields that are used within the
IRP by the operation being described. Each parameter is either Read
(i.e., used as input to the operation), Set (i.e., used as output for
the operation), or Ignored. To help distinguish the parameters we will
also use the two terms IrpFlags and FunctionFlags to denote the flags
field of the IRP header and the I/O stack location respectively.

In the description of the return status codes we do not include generic
values such as STATUS_PENDING or STATUS_INVALID_PARAMETER which can
be returned for any IRP. We also do not describe values that can be
returned by a lower level device drivers such as STATUS_PARITY_ERROR.

## 3.1 Close

The close function is used to close a previously opened file or
directory. Its two input parameters are a device object and an IRP. The
device object parameter points to a volume previously mounted by the
Device Driver and is where the file opened file exists. The IRP contains
the close function parameters (and are listed below).

Besides closing the file, this function will optionally deletes the file
based upon the disposition specified by the caller (See the
SET_INFORMATION operation). If this is the last file object with the
file opened and the disposition is *delete on close* then the file is
removed from the on-disk structure.

```
Close (
IN PDEVICE_OBJECT DeviceObject,
IN PIRP Irp
);
```

**Parameters within the IRP**:

<table>
<tbody>
<tr class="odd">
<td>Parameter type and name</td>
<td>Description</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PMDL</strong><em><br />
MdlAddress</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>ULONG</strong><em><br />
IrpFlags</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>STRING</strong><em><br />
FileObject-&gt;FileName</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>ULONG</strong><em><br />
FileObject-&gt;RelatedFileObject</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><em><br />
FileObject-&gt;FsContext</em></td>
<td>Read and Set. The driver uses this field to retrieve any private data (established by the CREATE function) that needs to be processed in order to close the file. It is set to NULL upon return from the close function.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>PVOID</strong><em><br />
FileObject-&gt;FsContext2</em></td>
<td>Read and Set. The driver uses this field to retrieve any private data (established by the CREATE function) that needs to be processed in order to close the file. It is set to NULL upon return from the close function.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><em><br />
FileObject-&gt;SectionObjectPointer</em></td>
<td>Set. The close function must set this field to NULL.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>IO_STATUS_BLOCK</strong><br />
<em>IoStatus</em></td>
<td>Set. This receives the final return status of the operation. The possible return status values are listed later.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PEPROCESS</strong><br />
<em>AlternateProcess</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>KPROCESSOR_MODE</strong><br />
<em>RequestorMode</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><br />
<em>SystemBuffer</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>PIO_STATUS_BLOCK</strong><br />
<em>UserIosb</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PKEVENT</strong><br />
<em>UserEvent</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>LARGE_INTEGER</strong><br />
<em>AllocationSize</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><br />
<em>UserBuffer</em></td>
<td>Ignored.</td>
<td></td>
</tr>
</tbody>
</table>

**Parameters within the IRP Stack**:

<table>
<tbody>
<tr class="odd">
<td>Parameter type and name</td>
<td>Description</td>
<td></td>
</tr>
<tr class="even">
<td><strong>UCHAR</strong><br />
<em>MajorFunction</em></td>
<td>Read. Must be equal to IRP_MJ_CLOSE.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>UCHAR</strong><br />
<em>MinorFunction</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>UCHAR</strong><br />
<em>FunctionFlags</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>UCHAR</strong><br />
<em>Control</em></td>
<td>Ignored.</td>
<td></td>
</tr>
</tbody>
</table>

**Iosb Return Status and Information**:

The following status codes are used to complete the CLOSE function.

<table>
<tbody>
<tr class="odd">
<td>Return status followed by information field of IOSB</td>
<td>Description</td>
</tr>
<tr class="even">
<td>STATUS_SUCCESS<br />
Ignored</td>
<td>Indicates that the opened file has been closed.</td>
</tr>
</tbody>
</table>

##
3.2 Create

The create function is used to create or open a file or a directory. Its
two input parameters are a device object and an IRP. The device object
parameter points to a volume previously mounted by the Device Driver and
is where the file will exist. The IRP contains the create function
parameters (and are listed below).

```
Create (
IN PDEVICE_OBJECT DeviceObject,
IN PIRP Irp
);
```

**Parameters within the IRP**:

<table>
<tbody>
<tr class="odd">
<td>Parameter type and name</td>
<td>Description</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PMDL</strong><em><br />
MdlAddress</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>ULONG</strong><em><br />
IrpFlags</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>STRING</strong><em><br />
FileObject-&gt;FileName</em></td>
<td>Read. This is the name of the file being opened.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>ULONG</strong><em><br />
FileObject-&gt;RelatedFileObject</em></td>
<td>Read. This field is used for path relative file names.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>If it is null then the file name is relative to the root of the volume (e.g., "\CONFIG.SYS" is the name of the configuration file located in root directory).</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>If is it not null then it points to a previously opened file object representing a directory on the volume, and the file name is relative to the specified directory (e.g., if the related file object is "\NT\SDK" the file name can be "INC\NTIOAPI.H"). Note that path relative file names do not begin with a backslash.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><em><br />
FileObject-&gt;FsContext</em></td>
<td>Set. This is used by the Device Driver to store file object specific information that can be retrieved later when the driver is called to perform subsequent operations on the file.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>The FAT file system stores in this field a pointer to an internal File Control Block (FCB) structure.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><em><br />
FileObject-&gt;FsContext2</em></td>
<td>Set. This is used by the Device Driver to store file object specific information that can be retrieved later when the driver is called to perform subsequent operations on the file.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>The FAT file system only uses this field for directories. It is a pointer to an internal Context Control Block (CCB) structure.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><em><br />
FileObject-&gt;SectionObjectPointer</em></td>
<td>Set. It is set to the longword context for the file. It is not used for directories. For every opened file the driver allocates a single longword of context for exclusive use by the memory management system. All file objects that denote the same file point to the same longword context.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>In FAT this is done by reserving a longword field in the FCB and having each section object pointer point to this field.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>IO_STATUS_BLOCK</strong><br />
<em>IoStatus</em></td>
<td>Set. This receives the final return status of the operation. The possible return status values are listed later.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>PEPROCESS</strong><br />
<em>AlternateProcess</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>KPROCESSOR_MODE</strong><br />
<em>RequestorMode</em></td>
<td>Read. This is the mode of the requestor. It is used for to help decide if the requestor has the proper access rights to the file.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>/** We also need to pass in the token of the requestor **/</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><br />
<em>SystemBuffer</em></td>
<td>Read. This field is only used if the file is being created and then it only specifies the optional extended attributes for the file. If the field is null the file will not be created with extended attributes. The create operation must complete with an error if there are any problems with the extended attributes.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>For FAT there is a 64K limit to the size of the extended attributes (as packed on the disk). The create operation will complete with an error if this limit is exceeded.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PIO_STATUS_BLOCK</strong><br />
<em>UserIosb</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>PKEVENT</strong><br />
<em>UserEvent</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>LARGE_INTEGER</strong><br />
<em>AllocationSize</em></td>
<td>Read. This field is only used if the file is being created and is ignored for directories and for open operations. It specifies the initial file allocation in bytes to allocate to the file. This is not the same as the end-of-file location.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>PVOID</strong><br />
<em>UserBuffer</em></td>
<td>Ignored.</td>
<td></td>
</tr>
</tbody>
</table>

**Parameters within the IRP Stack**:

<table>
<tbody>
<tr class="odd">
<td>Parameter type and name</td>
<td>Description</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td><strong>UCHAR</strong><br />
<em>MajorFunction</em></td>
<td>Read. Must be equal to IRP_MJ_CREATE.</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td><strong>UCHAR</strong><br />
<em>MinorFunction</em></td>
<td>Ignored.</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td><strong>UCHAR</strong><br />
<em>FunctionFlags</em></td>
<td>Ignored.</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td><strong>UCHAR</strong><br />
<em>Control</em></td>
<td>Ignored.</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td><strong>ULONG</strong><br />
<em>DesiredAccess</em></td>
<td>Read. This is the access mask that the user is trying to acquire to the file. If the user is trying to open a file the mask will be a combination of the following values:</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>DELETE,<br />
READ_CONTROL,<br />
WRITE_DAC,<br />
WRITE_OWNER,<br />
SYNCHRONIZE,<br />
FILE_READ_DATA,<br />
FILE_WRITE_DATA,<br />
FILE_APPEND_DATA,<br />
FILE_READ_EA,<br />
FILE_WRITE_EA,<br />
FILE_EXECUTE,<br />
FILE_READ_ATTRIBUTES, and<br />
FILE_WRITE_ATTRIBUTES.</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>If the user is trying to open a directory the mask will be a combination of the following values:</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>DELETE,<br />
READ_CONTROL,<br />
WRITE_DAC,<br />
WRITE_OWNER,<br />
SYNCHRONIZE,<br />
FILE_LIST_DIRECTORY,<br />
FILE_ADD_FILE,<br />
FILE_ADD_SUBDIRECTORY,<br />
FILE_READ_EA,<br />
FILE_WRITE_EA,<br />
FILE_TRAVERSE,<br />
FILE_DELETE_CHILD,<br />
FILE_READ_ATTRIBUTES, and<br />
FILE_WRITE_ATTRIBUTES.</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>The driver must ensure that the combination of the caller's privileges and requestor's mode grants all of the desired accesses that the user is trying to acquire.</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td><strong>ULONG</strong><br />
<em>Options</em></td>
<td>Read. This field contains all of the different create options and create disposition flags that the user can specify in an NT call. The valid flags and their meanings are listed below:</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_CREATE_DIRECTORY</td>
<td>Read. Indicates that the user is creating a new directory.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_OPEN_DIRECTORY</td>
<td>Read. Indicates that the user is opening an existing directory.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_WRITE_THROUGH</td>
<td>Ignored, but saved away for use by subsequent read and write operations to the file object.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_SEQUENTIAL_ONLY</td>
<td>Ignored, but saved away for use by subsequent read and write operations to the file object.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_MAPPED_IO</td>
<td>Ignored, but saved away for use by subsequent read and write operations to the file object.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_DISABLE_CACHING</td>
<td>Ignored, but saved away for use by subsequent read and write operations to the file object.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_SYNCHRONOUS_IO_ALERT</td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_SYNCHRONOUS_IO_NONALERT</td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_CREATE_TREE_CONNECTION</td>
<td><p>Read. Only used by the network.</p>
<p>/** need a complete description of this parameter **/</p></td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_SUPERSEDE &lt;&lt; 24[2]</td>
<td>Read. Indicates that if the file already exists it should be superseded, and if the file does not exist it should be created.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_CREATE &lt;&lt; 24</td>
<td>Read. Indicates that if the file already exists it is an error, and if the file does not exist it should be created.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_OPEN &lt;&lt; 24</td>
<td>Read. Indicates that if the file already exists it is to be opened, and if the file does not exist it is an error.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_OPEN_IF &lt;&lt; 24</td>
<td>Read. Indicates that if the file already exists it is to be opened, and if the file does not exist it should be created.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>/** We need a list of the illegal flag combinations, and state that they will never be seen in an IRP **/</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td><strong>USHORT</strong><br />
<em>FileAttributes</em></td>
<td>Read. This field specifies the DOS file attributes to use when creating or superseding a file, and is ignored when opening an existing file. It is a combination of any of the following flags:</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_ATTRIBUTE_READONLY<br />
FILE_ATTRIBUTE_HIDDEN<br />
FILE_ATTRIBUTE_SYSTEM<br />
FILE_ATTRIBUTE_ARCHIVE<br />
FILE_ATTRIBUTE_CONTROL, and<br />
FILE_ATTRIBUTE_NORMAL</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>The flag FILE_ATTRIBUTE_NORMAL overrides all other file attribute flags. (i.e., if the user specifies normal and readonly then the file is created as a normal file and not readonly).</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td><strong>USHORT</strong><br />
<em>ShareAccess</em></td>
<td>Read. This field specifies the share mode access between processes trying to open the same file. All users that open a file for shared access must specify the exact same share flags. This is separate from their desired access. For example a file opened shared read, write, and delete, must be opened by all users as shared read, write, and delete even though the desired access might only specify read access.</td>
<td></td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>The valid flags and their meanings are listed below:</td>
<td></td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_SHARE_READ</td>
<td>Read. Indicates that the file can be opened by others for read access. If the file is already opened for shared read access then other users can open it for read access.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_SHARE_WRITE</td>
<td>Read. Indicates that the file can be opened by others for write access. If the file is already opened for shared write access then other users can open it for write access.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td>FILE_SHARE_DELETE</td>
<td>Read. Indicates that the file can be opened by others for delete access. If the file is already opened for shared delete access then other users can open it for delete access.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>FILE_SHARE_RENAME</td>
<td>Read. Indicates that the file can be renamed by others. If the file is already opened for shared renamed access then other users can rename the file.</td>
<td></td>
</tr>
<tr class="odd">
<td></td>
<td></td>
<td>The test that a user requesting shared read, write, or delete can be done by the Device Driver during the create operation (i.e., a user is allowed read access to a shared file if the shared access flags match, shared read is specified, and the file's security protection allows for read access). The test for rename access must be deferred until the a rename IRP is processed (see the Set Information IRP description).</td>
<td></td>
</tr>
<tr class="even">
<td><strong>ULONG</strong><br />
<em>EaLength</em></td>
<td>Read. This parameter is specified only if the user is creating or superseding a file and has specified an EA for the file. This parameter is then the size, in bytes, of the EA set specified by the user. (i.e., it is the size of the system buffer parameter).</td>
<td></td>
<td></td>
</tr>
</tbody>
</table>

**Iosb Return Status and Information**:

The following status codes are used to complete the CREATE function.

<table>
<tbody>
<tr class="odd">
<td>Return status followed by information field of IOSB</td>
<td>Description</td>
<td></td>
</tr>
<tr class="even">
<td>STATUS_SUCCESS<br />
FILE_OPENED</td>
<td>Indicates that an existing file has been successfully located and opened.</td>
<td></td>
</tr>
<tr class="odd">
<td>STATUS_SUCCESS<br />
FILE_SUPERSEDED</td>
<td>Indicates that an existing file has been successfully located and superseded.</td>
<td></td>
</tr>
<tr class="even">
<td>STATUS_SUCCESS<br />
FILE_CREATED</td>
<td>Indicates that an existing file (of the same name) does not exist and that a new file has been successfully created.</td>
<td></td>
</tr>
<tr class="odd">
<td>STATUS_ACCESS_DENIED<br />
Ignored</td>
<td>Indicates that because of protection on the file, parent directory, or volume access has been denied to the file. This can also occur if the caller specified options or share access flags are not compatible with either the file or the previous share access that it was opened with.</td>
<td></td>
</tr>
<tr class="even">
<td>STATUS_OBJECT_NAME_INVALID<br />
Ignored</td>
<td>Indicates that the last name in the object's file name field does not contain a syntactically valid name (e.g., it's too long or contains invalid characters).</td>
<td></td>
</tr>
<tr class="odd">
<td>STATUS_OBJECT_NAME_NOT_FOUND<br />
Ignored</td>
<td>Indicates that the last name in the object's file name field is not the name of an existing file.</td>
<td></td>
</tr>
<tr class="even">
<td>STATUS_OBJECT_PATH_INVALID<br />
Ignored</td>
<td>Indicates that a name within the path part of the object's file name field does not contain a syntactically valid name.</td>
<td></td>
</tr>
<tr class="odd">
<td>STATUS_OBJECT_PATH_NOT_FOUND<br />
Ignored</td>
<td>Indicates that a name within the path part of the object's file name field does not contain the name of an existing directory.</td>
<td></td>
</tr>
<tr class="even">
<td>STATUS_DISK_FULL_ERROR<br />
Ignored</td>
<td>Indicates that because the disk is full the file cannot be created. This can occur when disk space cannot be allocated for the directory entry, file node, or the extended attributes.</td>
<td></td>
</tr>
<tr class="odd">
<td>STATUS_DISK_FULL_WARNING<br />
FILE_SUPERSEDED</td>
<td>Indicates that the file has been superseded but because the disk is full the file cannot be given the user specified file allocation size.</td>
<td></td>
</tr>
<tr class="even">
<td>STATUS_DISK_FULL_WARNING<br />
FILE_CREATED</td>
<td>Indictes that the file has been created but because the disk is full the file cannot be given ths user specified file allocation size.</td>
<td></td>
</tr>
<tr class="odd">
<td>STATUS_EA_INVALID<br />
Ignored</td>
<td>Indicates that the EA structure passed into this function is syntactically invalid.</td>
<td></td>
</tr>
</tbody>
</table>

##
3.3 Device Control

## 3.4 Directory Control(Notify Change Directory)

## 3.5 Directory Control(Query Directory)

## 3.6 File System Control(Dismount Volume)

## 3.7 File System Control(Lock Volume)

## 3.8 File System Control(Mount Volume)

The mount function is used mount a new disk volume. Its two input
parameters are a device object and an IRP. The device object parameter
points to the Device Drivers original device object that is created when
the driver is initialized.

The mount operation can handle mounting new volume, and remounting a
previously mounted volume. The parameter description that follows
assumes that it is processing a new volume. At the end of the
description we cover the updating required for the remount case.

```
Mount (
IN PDEVICE_OBJECT DeviceObject,
IN PIRP Irp
);
```

**Parameters within the IRP**:

<table>
<tbody>
<tr class="odd">
<td>Parameter type and name</td>
<td>Description</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PMDL</strong><em><br />
MdlAddress</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>ULONG</strong><em><br />
IrpFlags</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PFILE_OBJECT</strong><em><br />
FileObject</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>IO_STATUS_BLOCK</strong><br />
<em>IoStatus</em></td>
<td>Set. This receives the final return status of the operation. The possible return status values are listed later.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PEPROCESS</strong><br />
<em>AlternateProcess</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>KPROCESSOR_MODE</strong><br />
<em>RequestorMode</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><br />
<em>SystemBuffer</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>PIO_STATUS_BLOCK</strong><br />
<em>UserIosb</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PKEVENT</strong><br />
<em>UserEvent</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>LARGE_INTEGER</strong><br />
<em>AllocationSize</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PVOID</strong><br />
<em>UserBuffer</em></td>
<td>Ignored.</td>
<td></td>
</tr>
</tbody>
</table>

**Parameters within the IRP Stack**:

<table>
<tbody>
<tr class="odd">
<td>Parameter type and name</td>
<td>Description</td>
<td></td>
</tr>
<tr class="even">
<td><strong>UCHAR</strong><br />
<em>MajorFunction</em></td>
<td>Read. Must be equal to IRP_MJ_FILE_SYSTEM_CONTROL.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>UCHAR</strong><br />
<em>MinorFunction</em></td>
<td>Read. Must be equal to IRP_MN_MOUNT_VOLUME.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>UCHAR</strong><br />
<em>FunctionFlags</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>UCHAR</strong><br />
<em>Control</em></td>
<td>Ignored.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>PDEVICE_OBJECT</strong><br />
<em>Vpb-&gt;DeviceObject</em></td>
<td>Set. If the mount is successful this field is set the point to the newly allocated device object for the volume. If the mount is unsuccessful or this is a remount then this field is not updated.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>ULONG</strong><br />
<em>Vpb-&gt;DeviceObject-&gt;Flags</em></td>
<td>Set. If the mount is successful then the flag DO_DIRECT_IO is set in the newly created device objects flags field. Setting this flag allows the Device Driver to receive unbuffered I/O requests for this volume.</td>
<td></td>
</tr>
<tr class="even">
<td><strong>ULONG</strong><br />
<em>Vpb-&gt;SerialNumber</em></td>
<td>Set. If the mount is successful this field is set to the serial number found on the volume. It is ignored if the mount is unsuccessful or in the case of a remount.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>CHAR</strong><br />
<em>Vpb-&gt;VolumeName[20]</em></td>
<td>Set. If the mount is successful this field is set to the label found on the volume. If the volume does not have a label then this field should be set to all spaces.</td>
<td></td>
</tr>
<tr class="even">
<td></td>
<td>For FAT the volume label, if present, is found in the root directory as a special dirent.</td>
<td></td>
</tr>
<tr class="odd">
<td><strong>PDEVICE_OBJECT</strong><br />
<em>DeviceObject</em></td>
<td>Read. This is the device object that the Device Driver is to use when formulating IRPs to read or write to the volume. It is also called the target device object. If the volume is mounted successful this value must be remembered so the driver can handle subsequent requests to the volume.</td>
<td></td>
</tr>
</tbody>
</table>

**Iosb Return Status and Information**:

The following status codes are used to complete the MOUNT function.

<table>
<tbody>
<tr class="odd">
<td>Return status followed by information field of IOSB</td>
<td>Description</td>
</tr>
<tr class="even">
<td>STATUS_SUCCESS<br />
Ignored</td>
<td>Indicates that the volume has been successful mounted.</td>
</tr>
<tr class="odd">
<td>STATUS_WRONG_VOLUME<br />
Ignored</td>
<td>Indicates that the volume cannot be mounted either because it does not recognize the on-disk structure or the on-disk structure has been currupted.</td>
</tr>
</tbody>
</table>

**Mounting a new volume**:

The following figure shows the major I/O structures after processing a
successful mount request.

> \+---------------+<-------+
> Irp->DeviceObject - - -> | | |
> \+---------------+ |
> |
> \+---------------+<----+ |
> Irp->Vpb - - - - - - -> | | | |
> | DeviceObject |--+ | |
> | SerialNumber | | | |
> | VolumeName | | | |
> \+---------------+ | | |
> | | |
> \+---------------+<-+ | |
> | Newly | | |
> | Allocated | | |
> | Device | | |
> | Object | | |
> |...............| | |
> | | | |
> | Device Driver |-----+ |
> | Private Data |--------+
> | |
> \+---------------+
>
> The I/O structures after a mount operation

In the preceding figure the newly allocated device object has
immediately following it a Device Driver private data record that is for
used only by the driver. This technique should be used in the driver to
keep track of the VPB and the device object where it is to send its read
and write requests. It should also be used to link together all of the
mounted volumes serviced by the driver.

**Remounting a volume**:

By using the device driver private data record to maintain a link of all
mounted volumes a Device Driver can determine if a mount request for a
volume matches a previously mounted volume (They match if the both
volume have the same serial number and volume label). The following
figure shows the major I/O structure after processing a remount.

> \+---------------+<-------+
> Irp->DeviceObject -> | | |
> \+---------------+ |
> |
> \+---------------+ |
> Irp->Vpb - - - - -> | | |
> | RealDevice |--------|----> +---+
> \+---------------+ | +-> | |
> | | | |
> \+---------------+<----+ | | | |
> | | | | | +---+
> | RealDevice |-----|--|--+
> | DeviceObject |--+ | |
> \+---------------+ | | |
> | | |
> \+---------------+<-+ | |
> | Previously | | |
> | Allocated | | |
> | Device | | |
> | Object | | |
> |...............| | |
> | | | |
> | Device Driver |-----+ |
> | Private Data |--------+
> | |
> \+---------------+
>
> The I/O structures after a remount operation

The remount operation does not allocate any new structures, instead it
it performs the following operations:

- The Device Drivers Private Data pointer to the target device object is
changed to point to the new target device object.

- The RealDevice field of the Vpb that we previously mounted is set to
the RealDevice field of the new Vpb that was passed in as a parameter in
the IRP.

- The Irp->Vpb is deallocated from pool by the device driver, and
complete the mount request with STATUS_SUCCESS.

## 3.9 File System Control(Query Information File System)

## 3.10 File System Control(Set Information File System)

## 3.11 File System Control(Unlock Volume)

## 3.12 File System Control(Verify Volume)

## 3.13 Internal Device Control

## 3.14 Lock Control(Lock)

## 3.15 Lock Control(Unlock All)

## 3.16 Lock Control(Unlock Single)

## 3.17 Query Acl

## 3.18 Query Ea

## 3.19 Query Information

## 3.20 Query Volume Information

## 3.21 Read

## 3.22 Read Terminal

## 3.23 Set Acl

## 3.24 Set Ea

## 3.25 Set Information

## 3.26 Set New Size

## 3.27 Set Volume Information

## 3.28 Write

**Revision History**

Original Draft 1.0, December 15, 1989

1.  For clarity we will use the term Device Driver to refer to both
    Device Drivers and File systems.

2.  To test if the flags FILE_SUPERSEDE, FILE_OPEN, FILE_CREATE, and
    FILE_OPEN_IF are in the options parameter the driver must first
    shift the flag 24 bits to the left and then do the test (e.g.,
    Option & (FILE_SUPERSEDE << 24)).
