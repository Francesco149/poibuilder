TARGET = poiretro_psp
OBJS = main.o pbm_loader.o psp_render.o psp_prof.o

CFLAGS = -O2 -G0 -Wall -D_PSP_FW_VERSION=600
CXXFLAGS = $(CFLAGS) -fno-exceptions -fno-rtti
ASFLAGS = $(CFLAGS)

LIBS = -lpspgum -lpspgu -lpspdisplay -lpspge -lpspctrl -lpsprtc -lpsppower -lm

EXTRA_TARGETS = EBOOT.PBP
PSP_EBOOT_TITLE = PoiRetro Map Renderer

PSPSDK=$(shell psp-config --pspsdk-path)
include $(PSPSDK)/lib/build.mak

# Automated benchmark binary: same renderer, scripted orbit camera.
test_build:
	$(CC) $(CFLAGS) -DHEADLESS_BENCHMARK=1 -c main.c -o main_test.o
	$(CC) $(CFLAGS) -DHEADLESS_BENCHMARK=1 -c psp_render.c -o psp_render_test.o
	$(CC) $(CFLAGS) -DHEADLESS_BENCHMARK=1 -c psp_prof.c -o psp_prof_test.o
	$(CC) $(CFLAGS) -L. -L$(shell psp-config --psp-prefix)/lib -L$(shell psp-config --pspsdk-path)/lib -Wl,-zmax-page-size=128 main_test.o psp_render_test.o psp_prof_test.o pbm_loader.o $(LIBS) -lpspdebug -lpspdisplay -lpspge -lpspctrl -lpspnet -lpspnet_apctl -o poiretro_psp_test.elf
	psp-fixup-imports poiretro_psp_test.elf
	rm -f main_test.o psp_render_test.o psp_prof_test.o
