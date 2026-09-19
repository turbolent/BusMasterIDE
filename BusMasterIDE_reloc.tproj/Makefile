
NAME = BusMasterIDE_reloc

PROJECTVERSION = 1.1
LANGUAGE = English

CLASSES = IDEController.m IDEDisk.m IDEKernel.m \
          ATAPIController.m ATAPIControllerCmds.m

HFILES = BMIDEDMA.h IDE.h IDEController.h IDEDisk.h \
         IDEKernel.h ATAPIController.h ATAPIControllerCmds.h \
         ATAPIControllerPublic.h atapi_extern.h

OTHERSRCS = Makefile Makefile.preamble Makefile.postamble \
            Makefile.driver_preamble Load_Commands.sect

MAKEFILEDIR = /NextDeveloper/Makefiles/app
MAKEFILE = tool.make
SOURCEMODE = 444

LIBS =
DEBUG_LIBS = $(LIBS)
PROF_LIBS = $(LIBS)

-include Makefile.preamble

include $(MAKEFILEDIR)/$(MAKEFILE)

-include Makefile.postamble

-include Makefile.dependencies
