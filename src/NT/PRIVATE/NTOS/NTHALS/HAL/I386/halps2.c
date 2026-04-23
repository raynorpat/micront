/*
 * halps2.c - PS/2 keyboard/mouse detection and Hardware-hive population.
 *
 * On real NT 3.5, NTDETECT.COM populated
 *   \Registry\Machine\Hardware\Description\System\MultifunctionAdapter\<n>\
 *       KeyboardController\0\KeyboardPeripheral\0
 *       PointerController\0\PointerPeripheral\0
 * before ntoskrnl ran. The loader's CONFIGURATION_COMPONENT_DATA tree was
 * then persisted into the volatile Hardware hive by CmpInitializeHardwareC-
 * onfiguration during CmInitSystem1.
 *
 * MicroNT's UEFI loader produces the ARC tree for disks + UARTs but not
 * for PS/2 devices — that detection is the HAL's responsibility (it owns
 * i8042 port I/O). We run here from HalReportResourceUsage, which the
 * kernel calls after CmInitSystem1 (so the registry is up) and before
 * IoInitSystem loads i8042prt / kbdclass / mouclass.
 *
 * Without these keys, i8042prt's IoQueryDeviceDescription callout returns
 * no hardware and DriverEntry bails with STATUS_NO_SUCH_DEVICE.
 */

#include "halp.h"

#define I8042_STATUS_PORT  0x64

static const WCHAR HalpMfaPath[] =
    L"\\Registry\\Machine\\Hardware\\Description\\System\\MultifunctionAdapter\\0";

/*
 * Probe the 8042 controller. A present 8042 responds on port 0x64 with
 * a status byte whose high bits are usable (i.e. not 0xFF). "Not 0xFF"
 * is the conventional lowest-risk presence check — floating ISA buses
 * drive 0xFF; a live chip drives a real status word.
 */
static BOOLEAN
HalpProbePs2Controller(VOID)
{
    UCHAR status = HalpReadPort(I8042_STATUS_PORT);
    return (status != 0xFF);
}

/*
 * Create a child key named "<SubName>\<Instance>" below ParentHandle and
 * write the three standard hardware-description values:
 *   Component Information  - REG_BINARY, CONFIGURATION_COMPONENT header
 *   Identifier             - REG_SZ, human-readable name (NULL = skip)
 *   Configuration Data     - REG_FULL_RESOURCE_DESCRIPTOR blob (NULL = skip)
 *
 * Returns an open handle to the new key so the caller can create children
 * under it, or NULL on failure. Caller closes.
 */
static HANDLE
HalpCreateHwDescKey(
    HANDLE ParentHandle,
    PCWSTR SubName,
    PCWSTR Instance,
    PCWSTR Identifier,
    PVOID  CfgBlob,
    ULONG  CfgBlobLen
    )
{
    UNICODE_STRING nameStr;
    UNICODE_STRING valStr;
    OBJECT_ATTRIBUTES oa;
    HANDLE parentHandle = NULL;
    HANDLE instanceHandle = NULL;
    ULONG disposition;
    NTSTATUS status;
    CONFIGURATION_COMPONENT comp;

    /* Step 1: create the class-typed container key (e.g. "KeyboardController"). */
    RtlInitUnicodeString(&nameStr, (PWSTR)SubName);
    InitializeObjectAttributes(&oa, &nameStr,
                               OBJ_CASE_INSENSITIVE,
                               ParentHandle,
                               (PSECURITY_DESCRIPTOR)NULL);
    status = ZwCreateKey(&parentHandle,
                         KEY_READ | KEY_WRITE,
                         &oa,
                         0, NULL,
                         REG_OPTION_VOLATILE,
                         &disposition);
    if (!NT_SUCCESS(status)) return NULL;

    /* Step 2: create the instance key (e.g. "0") inside that. */
    RtlInitUnicodeString(&nameStr, (PWSTR)Instance);
    InitializeObjectAttributes(&oa, &nameStr,
                               OBJ_CASE_INSENSITIVE,
                               parentHandle,
                               (PSECURITY_DESCRIPTOR)NULL);
    status = ZwCreateKey(&instanceHandle,
                         KEY_READ | KEY_WRITE,
                         &oa,
                         0, NULL,
                         REG_OPTION_VOLATILE,
                         &disposition);
    ZwClose(parentHandle);
    if (!NT_SUCCESS(status)) return NULL;

    /* Component Information: the fields up to but excluding Config-
     * urationDataLength (16 bytes on x86), matching what the kernel's
     * CmpInitializeRegistryNode writes for ARC-sourced nodes. */
    RtlZeroMemory(&comp, sizeof comp);
    comp.AffinityMask = 0xffffffff;
    RtlInitUnicodeString(&valStr, L"Component Information");
    ZwSetValueKey(instanceHandle, &valStr, 0,
                  REG_BINARY,
                  &comp,
                  FIELD_OFFSET(CONFIGURATION_COMPONENT, ConfigurationDataLength));

    if (Identifier) {
        ULONG len = 0;
        while (Identifier[len]) len++;
        RtlInitUnicodeString(&valStr, L"Identifier");
        ZwSetValueKey(instanceHandle, &valStr, 0,
                      REG_SZ,
                      (PVOID)Identifier,
                      (len + 1) * sizeof(WCHAR));
    }

    if (CfgBlob && CfgBlobLen) {
        RtlInitUnicodeString(&valStr, L"Configuration Data");
        ZwSetValueKey(instanceHandle, &valStr, 0,
                      REG_FULL_RESOURCE_DESCRIPTOR,
                      CfgBlob,
                      CfgBlobLen);
    }

    return instanceHandle;
}

VOID
HalpReportPs2Devices(VOID)
{
    UNICODE_STRING mfaPath;
    OBJECT_ATTRIBUTES oa;
    HANDLE mfaHandle = NULL;
    HANDLE kcHandle, kpHandle, pcHandle, ppHandle;
    NTSTATUS status;

    if (!HalpProbePs2Controller()) {
        HalpSerialPrint("HAL: no PS/2 controller detected\r\n");
        return;
    }

    RtlInitUnicodeString(&mfaPath, (PWSTR)HalpMfaPath);
    InitializeObjectAttributes(&oa, &mfaPath,
                               OBJ_CASE_INSENSITIVE,
                               NULL,
                               (PSECURITY_DESCRIPTOR)NULL);
    status = ZwOpenKey(&mfaHandle, KEY_READ | KEY_WRITE, &oa);
    if (!NT_SUCCESS(status)) {
        HalpSerialPrint("HAL: MultifunctionAdapter\\0 not present; cannot report PS/2\r\n");
        return;
    }

    /* --- KeyboardController\0: ports 0x60/0x64 + IRQ 1 --- */
    {
        struct {
            CM_FULL_RESOURCE_DESCRIPTOR     hdr;       /* has PartialDescriptors[1] */
            CM_PARTIAL_RESOURCE_DESCRIPTOR  extra[2];  /* 2nd + 3rd descriptors */
        } blob;
        RtlZeroMemory(&blob, sizeof blob);
        blob.hdr.InterfaceType               = Isa;
        blob.hdr.BusNumber                   = 0;
        blob.hdr.PartialResourceList.Version  = 1;
        blob.hdr.PartialResourceList.Revision = 1;
        blob.hdr.PartialResourceList.Count    = 3;
        /* Descriptor 0: 0x60 data port. */
        blob.hdr.PartialResourceList.PartialDescriptors[0].Type             = CmResourceTypePort;
        blob.hdr.PartialResourceList.PartialDescriptors[0].ShareDisposition = CmResourceShareDriverExclusive;
        blob.hdr.PartialResourceList.PartialDescriptors[0].Flags            = CM_RESOURCE_PORT_IO;
        blob.hdr.PartialResourceList.PartialDescriptors[0].u.Port.Start.LowPart  = 0x60;
        blob.hdr.PartialResourceList.PartialDescriptors[0].u.Port.Start.HighPart = 0;
        blob.hdr.PartialResourceList.PartialDescriptors[0].u.Port.Length         = 1;
        /* Descriptor 1: 0x64 status/command port. */
        blob.extra[0].Type             = CmResourceTypePort;
        blob.extra[0].ShareDisposition = CmResourceShareDriverExclusive;
        blob.extra[0].Flags            = CM_RESOURCE_PORT_IO;
        blob.extra[0].u.Port.Start.LowPart  = 0x64;
        blob.extra[0].u.Port.Start.HighPart = 0;
        blob.extra[0].u.Port.Length         = 1;
        /* Descriptor 2: IRQ 1. */
        blob.extra[1].Type             = CmResourceTypeInterrupt;
        blob.extra[1].ShareDisposition = CmResourceShareDeviceExclusive;
        blob.extra[1].Flags            = CM_RESOURCE_INTERRUPT_LATCHED;
        blob.extra[1].u.Interrupt.Level    = 1;
        blob.extra[1].u.Interrupt.Vector   = 1;
        blob.extra[1].u.Interrupt.Affinity = 1;
        kcHandle = HalpCreateHwDescKey(
            mfaHandle, L"KeyboardController", L"0",
            L"PCAT_ENHANCED",
            &blob, sizeof blob);
    }

    /* --- KeyboardPeripheral\0 under KeyboardController\0:
     *     DeviceSpecific descriptor + CM_KEYBOARD_DEVICE_DATA trailer. --- */
    if (kcHandle) {
        struct {
            CM_FULL_RESOURCE_DESCRIPTOR hdr;       /* Count=1, DeviceSpecific at [0] */
            CM_KEYBOARD_DEVICE_DATA     kbdData;   /* trails descriptor[0] */
        } blob;
        RtlZeroMemory(&blob, sizeof blob);
        blob.hdr.InterfaceType               = Isa;
        blob.hdr.BusNumber                   = 0;
        blob.hdr.PartialResourceList.Version  = 1;
        blob.hdr.PartialResourceList.Revision = 1;
        blob.hdr.PartialResourceList.Count    = 1;
        blob.hdr.PartialResourceList.PartialDescriptors[0].Type             = CmResourceTypeDeviceSpecific;
        blob.hdr.PartialResourceList.PartialDescriptors[0].ShareDisposition = 0;
        blob.hdr.PartialResourceList.PartialDescriptors[0].Flags            = 0;
        blob.hdr.PartialResourceList.PartialDescriptors[0].u.DeviceSpecificData.DataSize =
            sizeof(CM_KEYBOARD_DEVICE_DATA);
        blob.kbdData.Version       = 1;
        blob.kbdData.Revision      = 1;
        blob.kbdData.Type          = 4;   /* IBM enhanced 101/102-key */
        blob.kbdData.Subtype       = 0;
        blob.kbdData.KeyboardFlags = 0;
        kpHandle = HalpCreateHwDescKey(
            kcHandle, L"KeyboardPeripheral", L"0",
            L"PCAT_ENHANCED",
            &blob, sizeof blob);
        if (kpHandle) ZwClose(kpHandle);
        ZwClose(kcHandle);
    }

    /* --- PointerController\0: IRQ 12 only (shares 0x60/0x64 with kbd). --- */
    {
        struct {
            CM_FULL_RESOURCE_DESCRIPTOR hdr;  /* Count=1, Interrupt at [0] */
        } blob;
        RtlZeroMemory(&blob, sizeof blob);
        blob.hdr.InterfaceType               = Isa;
        blob.hdr.BusNumber                   = 0;
        blob.hdr.PartialResourceList.Version  = 1;
        blob.hdr.PartialResourceList.Revision = 1;
        blob.hdr.PartialResourceList.Count    = 1;
        blob.hdr.PartialResourceList.PartialDescriptors[0].Type             = CmResourceTypeInterrupt;
        blob.hdr.PartialResourceList.PartialDescriptors[0].ShareDisposition = CmResourceShareDeviceExclusive;
        blob.hdr.PartialResourceList.PartialDescriptors[0].Flags            = CM_RESOURCE_INTERRUPT_LATCHED;
        blob.hdr.PartialResourceList.PartialDescriptors[0].u.Interrupt.Level    = 12;
        blob.hdr.PartialResourceList.PartialDescriptors[0].u.Interrupt.Vector   = 12;
        blob.hdr.PartialResourceList.PartialDescriptors[0].u.Interrupt.Affinity = 1;
        pcHandle = HalpCreateHwDescKey(
            mfaHandle, L"PointerController", L"0",
            L"PS2 MOUSE",
            &blob, sizeof blob);
    }

    /* --- PointerPeripheral\0: no Configuration Data, identifier only. --- */
    if (pcHandle) {
        ppHandle = HalpCreateHwDescKey(
            pcHandle, L"PointerPeripheral", L"0",
            L"MICROSOFT PS2 MOUSE",
            NULL, 0);
        if (ppHandle) ZwClose(ppHandle);
        ZwClose(pcHandle);
    }

    ZwClose(mfaHandle);

    HalpSerialPrint("HAL: PS/2 keyboard + mouse reported to Hardware hive\r\n");
}
