obj\$(TARGET_DIRECTORY)\mkmsg.exe: obj\$(TARGET_DIRECTORY)\mkmsg.obj
    link -nologo -machine:$(TARGET_DIRECTORY) -debug:full -debugtype:cv -out:obj\$(TARGET_DIRECTORY)\mkmsg.exe obj\$(TARGET_DIRECTORY)\mkmsg.obj $(BASEDIR)\public\sdk\lib\$(TARGET_DIRECTORY)\crtdll.lib
