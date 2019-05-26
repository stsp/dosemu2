%option noinput nounput
%{

#define YY_NO_UNPUT		1
#define USE_LOOP_HANDLING	1
#define LEXER			1

#if USE_LOOP_HANDLING
  #define YY_NEVER_INTERACTIVE 1 /* need this to avoid access to yyin within
				    lexer code, even if yyin != NULL */
  /* however, flex 2.5.31 no longer respects this #define so we work
     around it by opening /dev/null if a cachefile or a macrofile is
     accessed. */
  #define LOOP_LIMIT		1000 /* this to avoid infinite loops,
  					if the user has errors in his
  					config file */
#endif

/* Flex defines these, but stdint.h is going to define them again */
#undef INT8_MAX
#undef INT16_MAX
#undef INT32_MAX
#undef UINT8_MAX
#undef UINT16_MAX
#undef UINT32_MAX

#include <stdlib.h>
#include <termios.h>
#undef ECHO
#include <sys/types.h>
#include <fcntl.h>
#include <stdio.h>
#include <ctype.h>
#include <string.h>
#include <setjmp.h>
#include <sys/stat.h>                    /* structure stat       */
#include <unistd.h>                      /* prototype for stat() */

#include "emu.h"
#include "cpu.h"
#include "disks.h"
#include "lpt.h"
#include "video.h"
#include "mouse.h"
#include "serial.h"
#include "timers.h"
#include "keyboard/keymaps.h"

#include "parser.h"
#include "dosemu_config.h"
#include "lexer.h"
int line_count;

#define NESTING_DEPTH	32 /* as we handle loops as pseudo includes,
			    * this defines the depth of nested loops
			    * as well as that of includes
			    */

static int __active__=1, __next_ITEM_for_me__=0;
#define __active_max (2*NESTING_DEPTH) /* Note: 'while' pushes twice */
static int __active_stack[__active_max+1]={1,0};
static int __active_i=1;
int include_stack_ptr = 0;
int last_include = 0;

static void push__active(void);
static void pop__active(void);
static void enter_includefile(char * fname);
static void enter_macrofile(char *variable);

#if 0 /* this just to test the conditional code */
  #define TESTACTIVE (({if(__active__)fprintf(stderr,">>>%s<<<\n", yytext);}),__active__)
#else
  #define TESTACTIVE __active__
#endif

#define RETURN if (TESTACTIVE) return
#define MAY_BE  if (TESTACTIVE)

#define MAY_BEFORME if (__next_ITEM_for_me__) { \
  if (get_config_variable(yytext)) { \
    __active__= (__next_ITEM_for_me__ > 0); \
  } \
  else __active__= (__next_ITEM_for_me__ < 0); \
  __next_ITEM_for_me__=0; \
} \
else if (TESTACTIVE)

#define MAY_BEINCLUDE(other_stuff) if (TESTACTIVE) { \
  if (__next_ITEM_for_me__ == 2) { \
    __next_ITEM_for_me__=0; \
    yytext[strlen(yytext)-1] = '\0'; \
    enter_includefile(&yytext[1]); \
  } \
  else other_stuff \
}

char *yy_vbuffer=0;

#if USE_LOOP_HANDLING

#define CACHEFILES_MAX  32
#define MACROFILE	CACHEFILES_MAX
FILE *dev_null_files[MACROFILE+1];

static int cachefile_nr(FILE *f)
{
	int i;
	for (i = 0; i < CACHEFILES_MAX; i++)
		if (dev_null_files[i] == f) return i;
	return CACHEFILES_MAX+1;
}

#define YY_INPUT(buf,result,max_size) \
  if (!yyin) { \
    if (yy_vbuffer && yy_vbuffer[0]) { \
      buf[(max_size)-1]=0; \
      strncpy(buf,yy_vbuffer,max_size); \
      if (buf[(max_size)-1]) { \
        yy_vbuffer+=max_size; \
        result=max_size; \
      } \
      else { \
        result=strlen(buf); \
        yy_vbuffer=0; \
      } \
    } \
    else result=0; \
  } \
  else { \
    if ( YY_CURRENT_BUFFER->yy_is_interactive ) { \
      int c = getc( yyin ); \
      result = c == EOF ? 0 : 1; \
      buf[0] = (char) c; \
    } \
    else { \
      int cfile = cachefile_nr(yyin); \
      if (cfile < CACHEFILES_MAX) { \
        result = cachefile_read(buf, max_size, cfile); \
      } \
      else { \
	if (yyin == dev_null_files[MACROFILE]) { \
	  result = macrofile_read(buf, max_size); \
	} \
        else if ( ((result = fread( buf, 1, max_size, yyin )) == 0) && ferror( yyin ) ) \
                  YY_FATAL_ERROR( "input in flex scanner failed" ); \
      } \
    } \
  }

/*
 * We are intercepting the yylex() function calls from the parser
 */ 
#undef YY_DECL
#define YY_DECL static int real_yylex ( YYSTYPE* yylval )


/*
 * we intercept lexer before executing each action
 */
#define YY_USER_ACTION if (__loop_handling__ > 0) \
			if (dump_input(yy_act)) break;

static int __loop_handling__ = 0;
static int dump_input(int rulenum);
static void enter_cachefile(int cfile);
static int cachefile_read(char *buf, int size, int cfile);
static int cachefile_wrap(void);
static int macrofile_read(char *buf, int size);
static int macrofile_wrap(void);


#else /* not USE_LOOP_HANDLING */


#define YY_INPUT(buf,result,max_size) \
  if (!yyin) { \
    if (yy_vbuffer && yy_vbuffer[0]) { \
      buf[(max_size)-1]=0; \
      strncpy(buf,yy_vbuffer,max_size); \
      if (buf[(max_size)-1]) { \
        yy_vbuffer+=max_size; \
        result=max_size; \
      } \
      else { \
        result=strlen(buf); \
        yy_vbuffer=0; \
      } \
    } \
    else result=0; \
  } \
  else { \
    if ( YY_CURRENT_BUFFER->yy_is_interactive ) { \
      int c = getc( yyin ); \
      result = c == EOF ? 0 : 1; \
      buf[0] = (char) c; \
    } \
    else { \
      if ( ((result = fread( buf, 1, max_size, yyin )) == 0) && ferror( yyin ) ) \
                  YY_FATAL_ERROR( "input in flex scanner failed" ); \
    } \
  }

#undef YY_DECL
#define YY_DECL int yylex YY_PROTO(( YYSTYPE* yylval ))

#endif /* not USE_LOOP_HANDLING */


%}

DIGIT		[0-9]
HEXDIGIT 	{DIGIT}|[a-fA-F]
LETTER		[a-zA-Z]
ALPHNUM		{LETTER}|{DIGIT}
IDENT		_*{LETTER}({ALPHNUM}|_)*
STRQUOTELESS	({LETTER}|[/\.\~])({ALPHNUM}|[_\~@\-\+:\./])*

%%

%{
	/* NOTE: "include" _must_ be the first rule, we need to know
	 *       the rule number, which _here_ is always '1'
	 */
#define INCLUDE_RULE_NUM	1
#define LOOP_RULE_NUM		(INCLUDE_RULE_NUM+1)
#define DONE_RULE_NUM		(LOOP_RULE_NUM+1)
%}
"include"		MAY_BE __next_ITEM_for_me__=2;
"while"|"foreach"	MAY_BE {
	#if USE_LOOP_HANDLING
			  if (!__loop_handling__) {
			    __loop_handling__ =1;
			    YY_USER_ACTION
			  }
	#endif
			};
"done"			if (__loop_handling__ <0) pop__active();
"while__yy__"		{ push__active(); RETURN(WHILESTATEMENT); }
"foreach__yy__"		{ push__active(); RETURN(FOREACHSTATEMENT); }

	/* special characters */

[{}()<>=,\-+\*;]		RETURN(yytext[0]);

	/* conditionals */

"if"			{ push__active(); RETURN(IFSTATEMENT); }
"ifdef"			{ push__active(); if (__active__) __next_ITEM_for_me__=1; }
"ifndef"		{ push__active(); if (__active__) __next_ITEM_for_me__=-1; }
"else"			{ 
			  if (__active__) __active__=0;
			  else if (__active_stack[__active_i-1] ) __active__=1;
			}
"endif"			pop__active();

	/* config variable settings */
"define"		RETURN(DEFINE);
"undef"			RETURN(UNDEF);
"checkuservar"		RETURN(CHECKUSERVAR);
"enter_user_scope"	MAY_BE {
			  yylval->i_value = include_stack_ptr+1;
			  return(ENTER_USER_SPACE);
			}
"leave_user_scope"	MAY_BE {
			  yylval->i_value = include_stack_ptr+1;
			  return(LEAVE_USER_SPACE);
			}


	/* boolean values */
on			RETURN(L_ON);
off			RETURN(L_OFF);
auto			RETURN(L_AUTO);
yes			RETURN(L_YES);
no			RETURN(L_NO);

	/* operators */
"/"			RETURN('/');
"div"			RETURN('/');
"|"			RETURN(OR_OP);
"^"			RETURN(XOR_OP);
">>"			RETURN(SHR_OP);
"<<"			RETURN(SHL_OP);
"!"			RETURN(NOT_OP);
"=="			RETURN(EQ_OP);
">="			RETURN(GE_OP);
"<="			RETURN(LE_OP);
"!="			RETURN(NEQ_OP);
"&&"			RETURN(L_AND_OP);
"&"			RETURN(AND_OP);
"||"			RETURN(L_OR_OP);
"~"			RETURN(BIT_NOT_OP);
"eq"			RETURN(STR_EQ_OP);
"ne"			RETURN(STR_NEQ_OP);

	/* numbers */
\\u{HEXDIGIT}{4}	MAY_BE{yylval->i_value = strtoul(yytext+2, 0, 16);
				return(UNICODE); }


{DIGIT}+		MAY_BE {yylval->i_value = strtoul(yytext, 0, 10);
				return(INTEGER); }

0x{HEXDIGIT}+		MAY_BE {yylval->i_value = strtoul(yytext, 0, 0);
				return(INTEGER); }

0b[01]+			MAY_BE {yylval->i_value = strtoul(yytext+2, 0, 2);
				return(INTEGER); }

{DIGIT}+\.{DIGIT}*([eE]\-?{DIGIT}+)? MAY_BE {yylval->r_value = atof(yytext);
				return(REAL); }

	/* casts */
"int"			RETURN(INTCAST);
"real"			RETURN(REALCAST);

	/* functions */
"strlen"		RETURN(STRLEN);
"strtol"		RETURN(STRTOL);
"strncmp"		RETURN(STRNCMP);
"strcat"		RETURN(STRCAT);
"strpbrk"		RETURN(STRPBRK);
"strsplit"		RETURN(STRSPLIT);
"strdel"		RETURN(STRDEL);
"strchr"		RETURN(STRCHR);
"strrchr"		RETURN(STRRCHR);
"strstr"		RETURN(STRSTR);
"strspn"		RETURN(STRSPN);
"strcspn"		RETURN(STRCSPN);
"defined"		RETURN(DEFINED);
"shell"			RETURN(SHELL);

	/* just for test purposes */
exprtest		RETURN(EXPRTEST);

	/* keywords */

feature			RETURN(FEATURE);
abort			RETURN(ABORT);
warn			RETURN(WARN);
x			RETURN(L_X);
sdl			RETURN(L_SDL);
dosbanner		RETURN(DOSBANNER);
fastfloppy		RETURN(FASTFLOPPY);
timer			RETURN(TIMER);
hogthreshold		RETURN(HOGTHRESH);
speaker			RETURN(SPEAKER);
ipxsupport		RETURN(IPXSUPPORT);
ipx_network		RETURN(IPXNETWORK);
pktdriver		RETURN(PKTDRIVER);
debug			RETURN(DEBUG);
mouse			RETURN(MOUSE);
serial			RETURN(SERIAL);
keyboard		RETURN(KEYBOARD);
keystroke		RETURN(PRESTROKE);
terminal		RETURN(TERMINAL);
video			RETURN(VIDEO);
emuretrace		RETURN(EMURETRACE);
mathco			RETURN(MATHCO);
cpu			RETURN(CPU);
cpuspeed		RETURN(CPUSPEED);
rdtsc			RETURN(RDTSC);
bootdrive		RETURN(BOOTDRIVE);
swap_bootdrive		RETURN(SWAP_BOOTDRIVE);
xms			RETURN(L_XMS);
umb_a0			RETURN(UMB_A0);
umb_b0			RETURN(UMB_B0);
umb_f0			RETURN(UMB_F0);
ems			RETURN(L_EMS);
dpmi			RETURN(L_DPMI);
dpmi_lin_rsv_base	RETURN(DPMI_LIN_RSV_BASE);
dpmi_lin_rsv_size	RETURN(DPMI_LIN_RSV_SIZE);
pm_dos_api		RETURN(PM_DOS_API);
ignore_djgpp_null_derefs RETURN(NO_NULL_CHECKS);
dosmem			RETURN(DOSMEM);
ext_mem			RETURN(EXT_MEM);
ports			RETURN(PORTS);
trace			RETURN(TRACE);
clear			RETURN(CLEAR);
sillyint		RETURN(SILLYINT);
irqpassing		RETURN(SILLYINT);
hardware_ram		RETURN(HARDWARE_RAM);
disk			RETURN(DISK);
printer			RETURN(PRINTER);
emusys                  RETURN(EMUSYS);
full_file_locks		RETURN(FULL_FILE_LOCKS);
lfn_support		RETURN(LFN_SUPPORT);
force_int_revect	RETURN(FINT_REVECT);
set_int_hooks		RETURN(SET_INT_HOOKS);
force_fs_redirect	RETURN(FFS_REDIR);
ttylocks		RETURN(TTYLOCKS);
sound_emu               RETURN(L_SOUND);
oss_options             RETURN(L_SND_OSS);
joystick_emu		RETURN(L_JOYSTICK);
dosemumap               RETURN(DOSEMUMAP);
logbufsize              RETURN(LOGBUFSIZE);
logfilesize		RETURN(LOGFILESIZE);
mappingdriver		RETURN(MAPPINGDRIVER);

	/* sillyint values */
use_sigio		RETURN(USE_SIGIO);

	/* ems values */
ems_size		RETURN(EMS_SIZE);
ems_frame		RETURN(EMS_FRAME);
ems_uma_pages		RETURN(EMS_UMA_PAGES);
ems_conv_pages		RETURN(EMS_CONV_PAGES);

	/* speaker values */

emulated		RETURN(EMULATED);
native			RETURN(NATIVE);

	/* cpuemu values */

cpuemu			RETURN(CPUEMU);
vm86			RETURN(VM86);
full			RETURN(FULL);
vm86sim			RETURN(VM86SIM);
fullsim			RETURN(FULLSIM);

cpu_vm			RETURN(CPU_VM);
cpu_vm_dpmi		RETURN(CPU_VM_DPMI);
kvm			RETURN(KVM);

	/* disk keywords */
hdimage			RETURN(HDIMAGE);
image			RETURN(HDIMAGE);
partition		RETURN(L_PARTITION);
wholedisk		RETURN(WHOLEDISK);
readonly		RETURN(READONLY);
threeinch		RETURN(THREEINCH);
threeinch_2880		RETURN(THREEINCH_2880);
threeinch_720		RETURN(THREEINCH_720);
fiveinch		RETURN(FIVEINCH);
fiveinch_360	RETURN(FIVEINCH_360);
sectors			RETURN(SECTORS);
cylinders		RETURN(CYLINDERS);
tracks			RETURN(TRACKS);
heads			RETURN(HEADS);
offset			RETURN(OFFSET);
floppy			RETURN(L_FLOPPY);
cdrom			RETURN(CDROM);
diskcyl4096		RETURN(DISKCYL4096);
hdtype1			RETURN(HDTYPE1);
hdtype2			RETURN(HDTYPE2);
hdtype9			RETURN(HDTYPE9);
default_drives		RETURN(DEFAULT_DRIVES);

	/* keyboard */
ctrl			RETURN(CTRL_MAP);
shift_alt		RETURN(SHIFT_ALT_MAP);
ctrl_alt		RETURN(CTRL_ALT_MAP);

tr                      MAY_BE { yylval->i_value = KEYB_TR;
                                return(KEYB_LAYOUT); }


keytable		RETURN(KEYTABLE);
layout			RETURN(LAYOUT);
rawkeyboard		RETURN(RAWKEYBOARD);
shift			RETURN(SHIFT_MAP);
alt			RETURN(ALT_MAP);
numpad			RETURN(NUMPAD_MAP);
dump			RETURN(DUMP);
		/* dead keys for accents in keytable */
dgrave			RETURN(DGRAVE);
dacute			RETURN(DACUTE);
dcircum			RETURN(DCIRCUM);
dtilde			RETURN(DTILDE);
dbreve			RETURN(DBREVE);
daboved			RETURN(DABOVED);
ddiares			RETURN(DDIARES);
dabover			RETURN(DABOVER);
ddacute			RETURN(DDACUTE);
dcedilla		RETURN(DCEDILLA);
diota			RETURN(DIOTA);
dogonek			RETURN(DOGONEK);
dcaron			RETURN(DCARON);


finnish			MAY_BE { yylval->i_value = KEYB_FINNISH;
			  return(KEYB_LAYOUT); }
finnish-latin1		MAY_BE { yylval->i_value = KEYB_FINNISH_LATIN1;
			  return(KEYB_LAYOUT); }
us			MAY_BE { yylval->i_value = KEYB_US; return(KEYB_LAYOUT); }
uk			MAY_BE { yylval->i_value = KEYB_UK; return(KEYB_LAYOUT); }
de			MAY_BE { yylval->i_value = KEYB_DE; return(KEYB_LAYOUT); }
de-latin1		MAY_BE { yylval->i_value = KEYB_DE_LATIN1;
			  return(KEYB_LAYOUT); }
fr			MAY_BE { yylval->i_value = KEYB_FR; return(KEYB_LAYOUT); }
fr-latin1		MAY_BE { yylval->i_value = KEYB_FR_LATIN1;
			  return(KEYB_LAYOUT); }
dk			MAY_BE { yylval->i_value = KEYB_DK; return(KEYB_LAYOUT); }
dk-latin1		MAY_BE { yylval->i_value = KEYB_DK_LATIN1;
			  return(KEYB_LAYOUT); }
keyb-no			MAY_BE { yylval->i_value = KEYB_NO; return(KEYB_LAYOUT); }
no-latin1		MAY_BE { yylval->i_value = KEYB_NO_LATIN1;
			  return(KEYB_LAYOUT); }
dvorak			MAY_BE { yylval->i_value = KEYB_DVORAK; return(KEYB_LAYOUT); }
sg			MAY_BE { yylval->i_value = KEYB_SG; return(KEYB_LAYOUT); }
sg-latin1		MAY_BE { yylval->i_value = KEYB_SG_LATIN1;
			  return(KEYB_LAYOUT); }
sf			MAY_BE { yylval->i_value = KEYB_SF; return(KEYB_LAYOUT); }
sf-latin1		MAY_BE { yylval->i_value = KEYB_SF_LATIN1;
			  return(KEYB_LAYOUT); }
es			MAY_BE { yylval->i_value = KEYB_ES; return(KEYB_LAYOUT); }
es-latin1		MAY_BE { yylval->i_value = KEYB_ES_LATIN1;
			  return(KEYB_LAYOUT); }
be			MAY_BE { yylval->i_value = KEYB_BE; return(KEYB_LAYOUT); }
po			MAY_BE { yylval->i_value = KEYB_PO; return(KEYB_LAYOUT); }
it			MAY_BE { yylval->i_value = KEYB_IT; return(KEYB_LAYOUT); }
sw			MAY_BE { yylval->i_value = KEYB_SW; return(KEYB_LAYOUT); }
hu			MAY_BE { yylval->i_value = KEYB_HU; return(KEYB_LAYOUT); }
hu-cwi			MAY_BE { yylval->i_value = KEYB_HU_CWI; return(KEYB_LAYOUT); }
hu-latin2		MAY_BE { yylval->i_value = KEYB_HU_LATIN2;
			  return(KEYB_LAYOUT); }
jp106			MAY_BE { yylval->i_value = KEYB_JP106; return(KEYB_LAYOUT); }
pl			MAY_BE { yylval->i_value = KEYB_PL; return(KEYB_LAYOUT); }
hr-cp852		MAY_BE { yylval->i_value = KEYB_HR_CP852;
			  return(KEYB_LAYOUT); }
cz-qwerty		MAY_BE { yylval->i_value = KEYB_CZ_QWERTY;
			  return(KEYB_LAYOUT); }
cz-qwertz		MAY_BE { yylval->i_value = KEYB_CZ_QWERTZ;
			  return(KEYB_LAYOUT); }
hr-latin2		MAY_BE { yylval->i_value = KEYB_HR_LATIN2;
			  return(KEYB_LAYOUT); }
ru 			MAY_BE { yylval->i_value = KEYB_RU; 
				return(KEYB_LAYOUT); }
keyb-user		MAY_BE { yylval->i_value = KEYB_USER; return(KEYB_LAYOUT); }

	/* serial stuff */

base			RETURN(BASE);
irq			RETURN(IRQ);
baudrate		RETURN(BAUDRATE);
device			RETURN(DEVICE);
com                     RETURN(COM);
virtual			RETURN(VIRTUAL);
vmodem			RETURN(VMODEM);
pseudo			RETURN(PSEUDO);
rtscts			RETURN(RTSCTS);
low_latency		RETURN(LOWLAT);
pccom			RETURN(PCCOM);

	/* lock file stuff */
directory              RETURN(DIRECTORY);
namestub               RETURN(NAMESTUB);
binary                 RETURN(BINARY);

	/* terminal stuff */

charset			RETURN(CHARSET);
xterm_title		RETURN(XTERM_TITLE);
color			RETURN(COLOR);
escchar			RETURN(ESCCHAR);
size			RETURN(SIZE);

	/* mouse types */

microsoft		RETURN(MICROSOFT);
ms3button		RETURN(MS3BUTTON);
logitech		RETURN(LOGITECH);
mmseries		RETURN(MMSERIES);
mouseman		RETURN(MOUSEMAN);
hitachi			RETURN(HITACHI);
mousesystems		RETURN(MOUSESYSTEMS);
busmouse		RETURN(BUSMOUSE);
ps2			RETURN(PS2);
imps2			RETURN(IMPS2);
internaldriver		RETURN(INTERNALDRIVER);
emulate3buttons		RETURN(EMULATE3BUTTONS);
cleardtr		RETURN(CLEARDTR);

	/* video stuff - sorry for Matrox but MGA was already used */

vga			RETURN(VGA);
ega			RETURN(EGA);
cga			RETURN(CGA);
mga			RETURN(MGA);
mda			RETURN(MGA);
none			RETURN(NONE);
console			RETURN(CONSOLE);
graphics		RETURN(GRAPHICS);
chipset			RETURN(CHIPSET);
memsize			RETURN(MEMSIZE);
fullrestore		RETURN(FULLREST);
partialrestore		RETURN(PARTREST);
vgaemubios_file		RETURN(VGAEMUBIOS_FILE);
vbios_file		RETURN(VBIOS_FILE);
vbios_copy		RETURN(VBIOS_COPY);
vbios_mmap		RETURN(VBIOS_MMAP);
vbios_seg		RETURN(VBIOS_SEG);
vbios_size		RETURN(VBIOS_SIZE_TOK);
vbios_post		RETURN(VBIOS_POST);
dualmon			RETURN(DUALMON);
forcevtswitch		RETURN(FORCE_VT_SWITCH);
pci			RETURN(PCI);
plainvga		MAY_BE { yylval->i_value = PLAINVGA; return(CHIPSET_TYPE); }
svgalib			MAY_BE { yylval->i_value = SVGALIB; return(CHIPSET_TYPE); }
vesa			MAY_BE { yylval->i_value = VESA; return(CHIPSET_TYPE); }

	/* xwindows stuff */

display			RETURN(L_DISPLAY);
title			RETURN(L_TITLE);
title_show_appname      RETURN(X_TITLE_SHOW_APPNAME);
icon_name		RETURN(ICON_NAME);
blinkrate		RETURN(X_BLINKRATE);
sharecmap		RETURN(X_SHARECMAP);
mitshm                  RETURN(X_MITSHM);
font			RETURN(X_FONT);
fixed_aspect		RETURN(X_FIXED_ASPECT);
aspect_43		RETURN(X_ASPECT_43);
lin_filt		RETURN(X_LIN_FILT);
bilin_filt		RETURN(X_BILIN_FILT);
mode13fact		RETURN(X_MODE13FACT);
winsize			RETURN(X_WINSIZE);
gamma			RETURN(X_GAMMA);
vgaemu_memsize		RETURN(VGAEMU_MEMSIZE);
vesamode		RETURN(VESAMODE);
lfb			RETURN(X_LFB);
pm_interface		RETURN(X_PM_INTERFACE);
mgrab_key		RETURN(X_MGRAB_KEY);
background_pause	RETURN(X_BACKGROUND_PAUSE);
fullscreen		RETURN(X_FULLSCREEN);

	/* SDL stuff */
sdl_hwrend		RETURN(SDL_HWREND);
sdl_font		RETURN(SDL_FONT);

        /* Sound stuff */

sb_base                 RETURN(SB_BASE);
sb_irq                  RETURN(SB_IRQ);
sb_dma                  RETURN(SB_DMA);
sb_hdma                 RETURN(SB_HDMA);
mpu_base                RETURN(MPU_BASE);
midi_synth              RETURN(MIDI_SYNTH);
mpu_irq                 RETURN(MPU_IRQ);
mpu_irq_mt32            RETURN(MPU_IRQ_MT32);
sound_driver		RETURN(SOUND_DRIVER);
midi_driver		RETURN(MIDI_DRIVER);
munt_roms		RETURN(MUNT_ROMS);
snd_plugin_params	RETURN(SND_PLUGIN_PARAMS);
pcm_hpf			RETURN(PCM_HPF);
midi_file		RETURN(MIDI_FILE);
wav_file		RETURN(WAV_FILE);

        /* Joystick stuff */

joy_device              RETURN(JOY_DEVICE);
joy_dos_min             RETURN(JOY_DOS_MIN);
joy_dos_max             RETURN(JOY_DOS_MAX);
joy_granularity         RETURN(JOY_GRANULARITY);
joy_latency             RETURN(JOY_LATENCY);

	/* packet driver */
novell_hack		RETURN(NOVELLHACK);
ethdev			RETURN(ETHDEV);
tapdev			RETURN(TAPDEV);
vdeswitch		RETURN(VDESWITCH);
slirpargs		RETURN(SLIRPARGS);
vnet			RETURN(VNET);
	/* debug flags */

io			RETURN(IO);
port			RETURN(PORT);
config			RETURN(CONFIG);
read			RETURN(READ);
write			RETURN(WRITE);
keyb			RETURN(KEYB);
warning			RETURN(WARNING);
general			RETURN(GENERAL);
hardware		RETURN(HARDWARE);
ipc			RETURN(L_IPC);
network			RETURN(NETWORK);
sound			RETURN(SOUND);
joystick		RETURN(JOYSTICK);

	/* printer stuff */

lpt			RETURN(LPT);
command			RETURN(COMMAND);
timeout			RETURN(TIMEOUT);
file			RETURN(L_FILE);

	/* port/io stuff */

ormask			RETURN(ORMASK);
andmask			RETURN(ANDMASK);
rdonly			RETURN(RDONLY);
wronly			RETURN(WRONLY);
rdwr			RETURN(RDWR);
range			RETURN(RANGE);
fast			RETURN(FAST);
slow			RETURN(SLOW);

	/* ASPI driver */
aspi			RETURN(ASPI);
devicetype		RETURN(DEVICETYPE);
target			RETURN(TARGET);

	/* hacks */
cli_timeout		RETURN(CLI_TIMEOUT);
timemode		RETURN(TIMEMODE);

	/* charset stuff */
external		RETURN(EXTERNAL);
internal		RETURN(INTERNAL);


	/* strings */

\'[^\']*\'		{
			char *s;
			for(s = strchr(yytext, '\n'); s != NULL; s = strchr(s+1,'\n'))
			      line_count++;

			MAY_BE {
			  yylval->s_value = strdup(yytext);
			  return(STRING); }
			}

{STRQUOTELESS}		MAY_BEFORME {
			  yylval->s_value = strdup(yytext);
			  return(STRING); }
${IDENT}		MAY_BE {
				yylval->s_value = strdup(&yytext[1]);
				return(VARIABLE);
			}
$${IDENT}		MAY_BE { enter_macrofile(&yytext[2]);}

	/* Note: we need the rule numbers of below actions 
	 *       The below first one is INCLUDEFILE_RULE_NUM
	 */
\"[^\"]*\"		{
			char *s;
			for(s = strchr(yytext, '\n'); s != NULL; s = strchr(s+1,'\n'))
			      line_count++;

			MAY_BEINCLUDE ( {
			  yylval->s_value = strdup(yytext);
			  return(STRING); } )
			}

	/* comments & whitespace */

[#][^\n]*		;               /* comments to (and excluding) EOLN */
[ \t]+			;   		/* ignore all white space */
\n			line_count++;	/* keep track of lines seen */
.			;/* fprintf(stderr, "%s:%d discarding char '%c'\n", 
				include_fnames[include_stack_ptr],line_count, yytext[0]); */


%%
	/* the above '\n' rule (last rule) has rule-number 'YY_NUM_RULES-2'
	 * We have no other chance as to 'count' backward to get the
	 * rule number of ' quoted string, comments, e.t.c'
	 * BIG_FAT_NOTE: If you insert rules behind INCLUDEFILE_RULE_NUM,
	 *               change INCLUDEFILE_RULE_NUM too !!!
	 */
#define INCLUDEFILE_RULE_NUM (YY_NUM_RULES-2 - 3)
#define COMMENT_RULE_NUM (INCLUDEFILE_RULE_NUM +1)
#define WHITESPACE_RULE_NUM (COMMENT_RULE_NUM +1)
#define NEWLINE__RULE_NUM (WHITESPACE_RULE_NUM +1)

#define MAX_INCLUDE_DEPTH NESTING_DEPTH
static YY_BUFFER_STATE include_stack[MAX_INCLUDE_DEPTH] ={0};
char * include_fnames[MAX_INCLUDE_DEPTH] = {0};
char * include_macbuf[MAX_INCLUDE_DEPTH] = {0};
int include_lines[MAX_INCLUDE_DEPTH] = {0};

static void enter_includefile(char * fname)
{
  FILE * new_yyin;
  char fname_[256];
  if ( include_stack_ptr >= MAX_INCLUDE_DEPTH ) {
    yyerror("Includes nested too deeply" );
    return;
  }
  /* we want to have the include files in the same directory as
   * the main config file, if we have no leading  '/'
   * and we want "keymap/xxx" mapped to e.g. "<DOSEMU_LIB_DIR>/keymap/xxx"
   */
  if (fname[0] != '/') {
    int i;
    if (!strncmp(fname, KEYMAP_DIR, strlen(KEYMAP_DIR)))
      strcpy(fname_, KEYMAP_LOAD_BASE_PATH);
    else
      strcpy(fname_, include_fnames[include_stack_ptr]);
    i=strlen(fname_);
    while (i && (fname_[i] != '/')) i--;
    if (i) {
      i++;
      strcpy(fname_+i,fname);
      fname=fname_;
    }
  }
  new_yyin = fopen( fname, "r" );
  if ( ! new_yyin ) {
    yyerror("cannot open includefile %s", fname);
    return;
  }
  c_printf("CONF: opened include file %s\n", fname);
  include_lines[include_stack_ptr] = line_count;
  include_stack[include_stack_ptr] = YY_CURRENT_BUFFER;
  include_stack_ptr++;
  include_fnames[include_stack_ptr] = strdup(fname);
  line_count = 1;
  yyin = new_yyin;
  include_stack[include_stack_ptr] = yy_create_buffer( yyin, YY_BUF_SIZE );
  yy_switch_to_buffer(include_stack[include_stack_ptr]);
  last_include = 0;
}

int yywrap(void)    /* this gets called at EOF of a parsed file */
{
  if (include_stack_ptr <= 0 ) return(1);
#if USE_LOOP_HANDLING
#if 1
  if (cachefile_nr(yyin) < CACHEFILES_MAX) return cachefile_wrap();
  if (yyin == dev_null_files[MACROFILE]) return macrofile_wrap();
#else
  if (macrobuffer) return macrofile_wrap();
  if (__loop_handling__ < 0) return cachefile_wrap();
#endif
#endif
  yy_switch_to_buffer(include_stack[include_stack_ptr-1] );
  fclose(include_stack[include_stack_ptr]->yy_input_file);
  yy_delete_buffer(include_stack[include_stack_ptr]);
  c_printf("CONF: closed include file %s\n", include_fnames[include_stack_ptr]);
  free(include_fnames[include_stack_ptr]);
  include_stack_ptr--;
  line_count=include_lines[include_stack_ptr];
  last_include = 0;
  return(0);
}


static void push__active(void)
{
  if (config_check_only>2)
    fprintf(stderr, "%03d: PUSH %d->%d %d >%s<\n", line_count, __active_i, __active_i+1, __active__, yytext);
  __active_stack[__active_i++]=__active__;
  if (__active_i > __active_max) {
    __active_i = __active_max;
    yyerror("Lexer block stack overflow, unmatching  if..else..endif");
  }
}

static void pop__active(void)
{
  if (config_check_only>2)
    fprintf(stderr, "%03d: POP %d<-%d %d >%s< %d\n", line_count, __active_i-1, __active_i, __active__, yytext, __loop_handling__);
  if (__active_i <=0) {
    yyerror("Lexer block stack underflow, unmatching  if..else..endif");
    return;
  }
  __active__=__active_stack[--__active_i];
}

void tell_lexer_if(int value)
{
  __active__ = value !=0;
}


#if USE_LOOP_HANDLING

/* ---------------------------------------------------------
 * yylex() wrapper
 *
 * Here the record/replay stuff is handled.
 * We need that in order to realize 'while' loops or such things
 */


#define SAVEBUFSIZE	0x4000
static char *savebuf = 0;
static int savebufsize = 0;
static int savebufwptr =0;


#define CACHEFILESIZE	(CACHEFILES_MAX * sizeof(struct cache_file))
static struct cache_file *cachefile = 0;
static int cachefilesize = 0;
static int cachefilewptr = -1;
static int cachefilecurrent = -1;

static void free_savebuffer(void);
static void free_cachefile_buffers(void);
static void close_cachefile_write(int stop);


OUR_YY_DECL
{
	int ret;

	ret = real_yylex(&yylval);

        if (__loop_handling__ >0) {
		/* we respawn yylex in a loop, while filling the cache files */
		while (__loop_handling__ >0) {
			ret = real_yylex(&yylval);
			if (ret == YY_NULL) {
				__loop_handling__ = 0;
				close_cachefile_write(savebufwptr);
				free_cachefile_buffers();
				free_savebuffer();
				yyerror("EOF while in loop, probably 'done' missing");
				return ret;
			}
		}
		/* and again, to get the first token again */
		ret = real_yylex(&yylval);
	}
	return(ret);
}

static void free_savebuffer(void)
{
	if (savebuf) free(savebuf);
	savebuf = 0;
	savebufsize = 0;
	savebufwptr = 0;
}

static void dumpout(const char *s, int len)
{
	if ((savebufwptr + len) > savebufsize) {
		do {
			savebufsize += SAVEBUFSIZE;
		} while ((savebufwptr + len) > savebufsize);
		if (!savebuf)
			savebuf = malloc(savebufsize);
		else	savebuf = realloc(savebuf, savebufsize);
	}
	memcpy(savebuf+savebufwptr, s, len);
	savebufwptr += len;
}


struct cache_file {
	int start;	/* point behind the loop begin statement */
	int stop;	/* point behind the loop end statement */
	int rptr;
	int parent;
	YY_BUFFER_STATE yybuffer;
	char *origfname;
	int  firstline;
	int  need_loop_back;
	int looplimit;
};

static void free_cachefile_buffers(void)
{
	int i;
	if (cachefile) {
		for (i=0; i <= cachefilewptr; i++)
			if (cachefile[i].origfname) free(cachefile[i].origfname);
		free(cachefile);
		cachefile = 0;
	}
	cachefilesize = 0;
	cachefilecurrent = cachefilewptr = -1;
}

static void create_cachefile(int start)
{
	struct cache_file *cf;

	cachefilewptr++;
	if (((cachefilewptr+1) * sizeof(struct cache_file)) > cachefilesize) {
		cachefilesize += CACHEFILESIZE;
		if (!cachefile)
			cachefile = malloc(cachefilesize);
		else	cachefile = realloc(cachefile, cachefilesize);
	}
	cf = cachefile + cachefilewptr;
	cf->start = start; 
	cf->stop = start;
	cf->rptr = start;
	cf->firstline = line_count;
	cf->origfname = 0;
#if 0
	/* NOTE: The 'include_stack_ptr > 0' sanity check may be needed
	   because of errors in do loops (to much 'done'), though this
	   would be for sure a syntax error in the config file, but we
	   got segfaults in the past and came not so far to report the
	   error. Hence, we have to check if the segfaults happen again.
	   Till then we leave the old code here in place.
			--Hans, 980614
	*/
	if (include_stack_ptr > 0 && include_fnames[include_stack_ptr])
#else
	if (include_fnames[include_stack_ptr])
#endif
		cf->origfname = strdup(include_fnames[include_stack_ptr]);
	cf->parent = cachefilecurrent;
	cachefilecurrent = cachefilewptr;
}

static void close_cachefile_write(int stop)
{
	if (!cachefile || cachefilecurrent <0)
		return;
	cachefile[cachefilecurrent].stop = stop;
	cachefilecurrent = cachefile[cachefilecurrent].parent;
}


static int cachefile_read(char *buf, int size, int cfile)
{
	struct cache_file *cf = cachefile+cfile;

	if (!cachefile || cachefilecurrent <0) return 0;
	if (cf->rptr+size >= cf->stop)
		size = cf->stop - cf->rptr;
	if (size <= 0) return 0;
	memcpy(buf, savebuf + cf->rptr, size);
	cf->rptr += size;
	return size;
}


static void enter_cachefile(int cfile)
{
	struct cache_file *cf;

	if ( include_stack_ptr >= MAX_INCLUDE_DEPTH ) {
		yyerror("Loops nested too deeply" );
		return;
	}
	if (!cachefile) {
		yyerror("mismatching loop begin/end \n");
		return;
	}
	cachefilecurrent = cfile;
	if (config_check_only>1)
		c_printf("CONF: opened cache file %d\n", cachefilecurrent);
	include_lines[include_stack_ptr] = line_count;
	include_stack[include_stack_ptr] = YY_CURRENT_BUFFER;
	include_stack_ptr++;
	cf = cachefile + cachefilecurrent;
	cf->looplimit = LOOP_LIMIT;
	cf->rptr = cf->start;
	if (cf->origfname)
		include_fnames[include_stack_ptr] = strdup(cf->origfname);
	else	include_fnames[include_stack_ptr] = 0;
	line_count = cf->firstline;
	dev_null_files[cachefilecurrent] = yyin = fopen("/dev/null", "r");
	include_stack[include_stack_ptr] = yy_create_buffer( yyin, cf->stop - cf->start +2);
	yy_switch_to_buffer(include_stack[include_stack_ptr]);
}


static int cachefile_wrap(void)
{
	struct cache_file *cf;
	int cfile;

	/* we come here from yywrap, when we got an EOF on the cache file */
	
	if (include_stack_ptr <= 0 || !cachefile || cachefilecurrent <0) return 0;
	cfile = cachefilecurrent;
	cf = cachefile + cfile;
	if (cf->need_loop_back) {
		if (--cf->looplimit <0) {
			yyerror("loop limit of %d loops exceeded\n", LOOP_LIMIT);
			cf->need_loop_back = 0;
		}
		else {
			cf->rptr = cf->start;
			line_count = cf->firstline;
			return(0);
		}
	}
	cachefilecurrent = cf->parent;
	yy_switch_to_buffer(include_stack[include_stack_ptr-1] );
	fclose(include_stack[include_stack_ptr]->yy_input_file);
	dev_null_files[cfile] = NULL;
	yy_delete_buffer(include_stack[include_stack_ptr]);
	free(include_fnames[include_stack_ptr]);
	if (config_check_only>1)
		c_printf("CONF: closed cache file %d\n", cfile);
	include_stack_ptr--;
	line_count=include_lines[include_stack_ptr];
	if (cfile >= 0) {
		/* when in inner loop, we have been executed from
		 * the copy, but the main cache file still is positioned
		 * directly behind the 'while__ ()' in the original.
		 * we have to skip this until 'done'.
		 * This can simply done by setting __active__=0,
		 * because the 'while__' has done an extra push__active()
		 * and the 'done' in the main cache file will do pop__active()
		 */
		__active__ = 0;
	}
	if (cachefilecurrent <0) {
		/* end of loop handling */
		__loop_handling__ = 0;
		free_cachefile_buffers();
		free_savebuffer();
	}
	return(0);
}

void tell_lexer_loop(int cfile, int value)
{
	__active__ = value !=0;
	if (!cachefile) return;
	if (__active__ && cachefilecurrent != cfile) {
		/* we have to open a deeper nested cache file */
		enter_cachefile(cfile);
	}
	cachefile[cfile].need_loop_back = __active__;
	return;
}


static int dump_input(int rulenum)
{
	static int lastchar = '\n';
	int savebufwptr_ = savebufwptr;
	int skip_action = 1;

	switch (rulenum) {
		case INCLUDE_RULE_NUM: {
			dumpout("#",1); /* comment out the include statement*/
			skip_action = 0;
			break;
		}
	}

	if (rulenum != COMMENT_RULE_NUM ) {
		if (rulenum == WHITESPACE_RULE_NUM) {
			if (lastchar != '\n') {
				dumpout(" ",1);
				lastchar = ' ';
			}
		}
		else {
			dumpout(yytext,yyleng);
			lastchar = yytext[yyleng-1];
		}
	}
	else {
		dumpout("#\n",2);
		lastchar = '\n';
		line_count++;
	}
	switch (rulenum) {
		case NEWLINE__RULE_NUM: {
			line_count++;
			break;
		}
		case INCLUDEFILE_RULE_NUM: {
			if (__next_ITEM_for_me__ == 2) {
				dumpout("\n",1);
				lastchar = '\n';
				skip_action = 0;
			}
			break;
		}
		case LOOP_RULE_NUM: {
			char buf[32];
			create_cachefile(savebufwptr_);
			sprintf(buf, "__yy__ %d, ", cachefilecurrent);
			dumpout(buf, strlen(buf));
			break;
		}
		case DONE_RULE_NUM: {
			close_cachefile_write(savebufwptr);
			if (cachefilecurrent <0) {
				/* finished all caching,
				 * starting working phase */
				__loop_handling__ = -1;
				enter_cachefile(0);
			}
		}
	}
	return skip_action;
}

static void enter_macrofile(char *variable)
{
	char *macrobuffer;
	if ( include_stack_ptr >= MAX_INCLUDE_DEPTH ) {
		yyerror("macrocall ... nested too deeply" );
		return;
	}
        macrobuffer = checked_getenv(variable);
	if (!macrobuffer) {
		yywarn("macro '%s' not found \n", variable);
		return;
	}
	if (config_check_only>1)
		c_printf("CONF: opened macro file %s\n", variable);
	include_lines[include_stack_ptr] = line_count;
	include_stack[include_stack_ptr] = YY_CURRENT_BUFFER;
	include_stack_ptr++;
	include_macbuf[include_stack_ptr] =
		include_fnames[include_stack_ptr] = strdup(macrobuffer);
	dev_null_files[MACROFILE] = yyin = fopen("/dev/null", "r");
	include_stack[include_stack_ptr] = yy_create_buffer( yyin, strlen(macrobuffer) +2);
	yy_switch_to_buffer(include_stack[include_stack_ptr]);
}

static int macrofile_wrap(void)
{
	/* we come her from yywrap, when we got an EOF on the macro file */
	
	if (include_stack_ptr <= 0) return 0;
	yy_switch_to_buffer(include_stack[include_stack_ptr-1] );
	fclose(include_stack[include_stack_ptr]->yy_input_file);
	dev_null_files[MACROFILE] = NULL;
	yy_delete_buffer(include_stack[include_stack_ptr]);
	free(include_macbuf[include_stack_ptr]);
	if (config_check_only>1)
		c_printf("CONF: closed macro file\n");
	include_stack_ptr--;
	line_count=include_lines[include_stack_ptr];
	return(0);
}


static int macrofile_read(char *buf, int size)
{
	int len;
	char *macroptr = include_fnames[include_stack_ptr];
	len = strlen(macroptr);
	if (!len) return 0;
	if (size > len) size = len;
	memcpy(buf, macroptr, size);
	include_fnames[include_stack_ptr] +=size;
	return size;
}



#endif /* USE_LOOP_HANDLING */
