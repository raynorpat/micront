lsapmsgs.h msg00001.bin: lsapmsgs.mc
    mc -v lsapmsgs.mc

# MicroNT: UMRES=obj\*\lsa_rev.res should trigger the MAKEFILE.DEF
# `{}.rc{obj\$(TARGET_DIRECTORY)\}.res:` inference rule automatically,
# but under our wine-hosted nmake it doesn't fire. Spell it out.
obj\$(TARGET_DIRECTORY)\lsa_rev.res: lsa_rev.rc lsapmsgs.rc lsapmsgs.h
    rc -r -fo $@ -D_X86_=1 -Di386=1 -I. -I..\..\inc -ID:\\public\oak\inc -ID:\\public\sdk\inc -ID:\\public\sdk\inc\crt lsa_rev.rc
