#
# (C) Copyright 1992, ..., 2014 the "DOSEMU-Development-Team".
#
# for details see file COPYING in the DOSEMU distribution
#

top_builddir=../../..
include $(top_builddir)/Makefile.conf
-include Makefile.conf

ALL_CFLAGS+=$(DL_CFLAGS) $(SDL_CFLAGS)
CFILES=sdl.c keyb_SDL.c snd_o_SDL.c
OBJS=$(CFILES:.c=.o)
DEPENDS=$(CFILES:.c=.d)

ifdef USE_DL_PLUGINS
all: $(BINPATH)/bin/libplugin_sdl.so
endif

include $(REALTOPDIR)/src/Makefile.common

ALL_CPPFLAGS += $(SDL_CFLAGS) -I$(srcdir)/../X

ifdef USE_DL_PLUGINS
$(BINPATH)/bin/libplugin_sdl.so: $(OBJS) | $(BINPATH)/bin
	$(CC) $(ALL_LDFLAGS) -shared -o $@ $^ $(SDL_LIBS)
endif

install: all
