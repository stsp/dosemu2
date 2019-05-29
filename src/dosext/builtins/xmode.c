/*
 * (C) Copyright 1992, ..., 2014 the "DOSEMU-Development-Team".
 *
 * for details see file COPYING in the DOSEMU distribution
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "emu.h"
#include "memory.h"
#include "video.h"
#include "builtins.h"

#include "xmode.h"

#define printf  com_printf
#define fprintf	com_fprintf
#undef	stderr
#define stderr	com_stderr
#define intr    com_intr

static int X_change_config(unsigned, void *);

int xmode_main(int argc, char **argv)
{
  char *p;
  long l, ll[2];


  argv++;
  if(!--argc) {
    fprintf(stderr,
      "usage: xmode <some arguments>\n"
      "  -mode <mode>     activate graphics/text mode\n"
      "  -title <name>    set name of emulator (in window title)\n"
      "  -showapp on|off  show name of running application (in window title)\n"
      "  -font <font>     use <font> as text font\n"
      "  -map <mode>      map window after graphics <mode> has been entered\n"
      "  -unmap <mode>    unmap window before graphics <mode> is left\n"
      "  -winsize <width> <height>    set initial graphics window size\n"
      "  -bpause on|off   pause DOSEMU if the window loses focus\n"
      "  -fullscreen on|off           fullscreen mode\n"
    );
    return 1;
  }

  while(argc) {
    if(!strcmp(*argv, "-title") && argc >= 2) {
      X_change_config(CHG_TITLE_EMUNAME, argv[1]);
      argc -= 2; argv += 2;
    }
    else if (!strcmp(*argv, "-showapp") && argc >= 2) {
      if (strequalDOS (argv [1], "OFF") || strequalDOS (argv [1], "0"))
	l = 0;
      else
	l = 1;

      X_change_config(CHG_TITLE_SHOW_APPNAME, &l);
      argc -= 2; argv += 2;
    }
    else if(!strcmp(*argv, "-font") && argc >= 2) {
      X_change_config(CHG_FONT, argv[1]);
      argc -= 2; argv += 2;
    }
    else if(!strcmp(*argv, "-map") && argc >= 2) {
      l = strtol(argv[1], &p, 0);
      if(argv[1] == p) {
        fprintf(stderr, "invalid mode number \"%s\"\n", argv[1]);
        return 2;
      }
      X_change_config(CHG_MAP, &l);
      argc -= 2; argv += 2;
    }
    else if(!strcmp(*argv, "-unmap") && argc >= 2) {
      l = strtol(argv[1], &p, 0);
      if(argv[1] == p) {
        fprintf(stderr, "invalid mode number \"%s\"\n", argv[1]);
        return 2;
      }
      X_change_config(CHG_UNMAP, &l);
      argc -= 2; argv += 2;
    }
    else if(!strcmp(*argv, "-winsize") && argc >= 3) {
      ll[0] = strtol(argv[1], &p, 0);
      if(argv[1] == p) {
        fprintf(stderr, "invalid width \"%s\"\n", argv[1]);
        return 2;
      }
      ll[1] = strtol(argv[2], &p, 0);
      if(argv[2] == p) {
        fprintf(stderr, "invalid height \"%s\"\n", argv[2]);
        return 2;
      }
      X_change_config(CHG_WINSIZE, ll);
      argc -= 3; argv += 3;
    }
    else if(!strcmp(*argv, "-mode") && argc >= 2) {
      l = strtol(argv[1], &p, 0);
      if(argv[1] == p) {
        fprintf(stderr, "invalid mode number \"%s\"\n", argv[1]);
        return 2;
      }
      if(l & ~0xff) {
        struct REGPACK r = REGPACK_INIT;

        r.r_bx = l & 0xffff;
        r.r_ax = 0x4f02;
        intr(0x10, &r);
      }
      else {
        struct REGPACK r = REGPACK_INIT;

        r.r_ax = l & 0xff;
        intr(0x10, &r);
      }
      argc -= 2; argv += 2;
    }
    else if (!strcmp(*argv, "-bpause") && argc >= 2) {
      if (strequalDOS (argv [1], "OFF") || strequalDOS (argv [1], "0"))
	l = 0;
      else
	l = 1;

      X_change_config(CHG_BACKGROUND_PAUSE, &l);
      argc -= 2; argv += 2;
    }
    else if (!strcmp(*argv, "-fullscreen") && argc >= 2) {
      if (strequalDOS (argv [1], "OFF") || strequalDOS (argv [1], "0"))
	l = 0;
      else
	l = 1;

      X_change_config(CHG_FULLSCREEN, &l);
      argc -= 2; argv += 2;
    }
    else {
      fprintf(stderr, "Don't know what to do with argument \"%s\"; aborting here.\n", *argv);
      return 2;
    }
  }

  return 0;
}

static int X_change_config(unsigned item, void *buf)
{
  if (Video->change_config) {
	return Video->change_config(item, buf);
  }
  return -1;
}

