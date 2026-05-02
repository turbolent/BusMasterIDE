NAME = BusMasterIDE

PROJECTVERSION = 1.1
LANGUAGE = English

LOCAL_RESOURCES = Localizable.strings

GLOBAL_RESOURCES = Default.table

TOOLS = BusMasterIDE_reloc.tproj

OTHERSRCS = Makefile Makefile.preamble Makefile.postamble README \
            ide-test.sh atapi-stress.sh

MAKEFILEDIR = /NextDeveloper/Makefiles/app
MAKEFILE = bundle.make
SOURCEMODE = 444

BUNDLE_EXTENSION = config

-include Makefile.preamble

include $(MAKEFILEDIR)/$(MAKEFILE)

-include Makefile.postamble

-include Makefile.dependencies
