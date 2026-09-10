TARGET = poiretro_psp
OBJS = main.o pbm_loader.o

CFLAGS = -O2 -G0 -Wall -D_PSP_FW_VERSION=600
CXXFLAGS = $(CFLAGS) -fno-exceptions -fno-rtti
ASFLAGS = $(CFLAGS)

LIBS = -lpspgum -lpspgu -lpspdisplay -lpspge -lpspctrl -lm

EXTRA_TARGETS = EBOOT.PBP
PSP_EBOOT_TITLE = PoiRetro Map Renderer

PSPSDK=$(shell psp-config --pspsdk-path)
include $(PSPSDK)/lib/build.mak
