/* parser.y
 *
 * Parser version 1     ... before 0.66.5
 * Parser version 2     at state of 0.66.5   97/05/30
 * Parser version 3     at state of 0.97.0.1 98/01/03
 *
 * Note:  starting with version 2, you may protect against version 3 via
 *
 *   ifdef parser_version_3
 *     # version 3 style parser
 *   else
 *     # old style parser
 *   endif
 *
 * Note2: starting with version 3 you _need_ atleast _one_ statement such as
 *
 *   $XYZ = "something"
 *
 * to make the 'new version style check' happy, else dosemu will abort.
 */

/* Merged parser stuff for keyboard plugin
 */

/* Merged parser stuff for translate plugin
 */

%{

#define PARSER_VERSION_STRING "parser_version_3"

#include <stdlib.h>
#include <termios.h>
#include <sys/types.h>
#include <fcntl.h>
#include <stdio.h>
#include <ctype.h>
#include <string.h>
#include <sys/stat.h>                    /* structure stat       */
#include <unistd.h>                      /* prototype for stat() */
#include <sys/wait.h>
#include <signal.h>
#include <stdarg.h>
#include <pwd.h>
#include <syslog.h>
#include <string.h>
#include <errno.h>
#include <assert.h>
#ifdef __linux__
#include <mntent.h>
#endif

#include "dosemu_config.h"
#include "emu.h"
#ifdef X86_EMULATOR
#include "cpu-emu.h"
#endif
#include "disks.h"
#include "port.h"
#define allow_io	port_allow_io
#include "lpt.h"
#include "video.h"
#include "vc.h"
#include "mouse.h"
#include "serial.h"
#include "timers.h"
#include "keyboard/keymaps.h"
#include "keyboard/keyb_server.h"
#include "memory.h"
#include "mapping.h"
#include "utilities.h"
#include "aspi.h"
#include "pktdrvr.h"
#include "iodev.h" /* for TM_BIOS / TM_PIT / TM_LINUX */

#define USERVAR_PREF	"dosemu_"
static int user_scope_level;

static int after_secure_check = 0;
static serial_t *sptr;
static serial_t nullser;
static mouse_t *mptr = &config.mouse;
static int c_ser = 0;

static struct disk *dptr;
static struct disk nulldisk;
#define c_hdisks config.hdisks
#define c_fdisks config.fdisks

char own_hostname[128];

static struct printer nullprt;
static struct printer *pptr = &nullprt;
static int c_printers = 0;

static int ports_permission = IO_RDWR;
static unsigned int ports_ormask = 0;
static unsigned int ports_andmask = 0xFFFF;
static unsigned int portspeed = 0;
static char dev_name[255]= "";

static int errors = 0;
static int warnings = 0;

static int priv_lvl = 0;
static int saved_priv_lvl = 0; 


static char *file_being_parsed;

			/* this to ensure we are parsing a new style */
static int parser_version_3_style_used = 0;
#define CONFNAME_V3USED "version_3_style_used"

	/* local procedures */

static void start_ports(void);
static void start_mouse(void);
static void stop_mouse(void);
static void start_debug(void);
static void start_video(void);
static void stop_video(void);
static void set_vesamodes(int width, int height, int color_bits);
static int detect_vbios_seg(void);
static int detect_vbios_size(void);
static void stop_ttylocks(void);
static void start_serial(void);
static void stop_serial(void);
static void start_printer(void);
static void stop_printer(void);
static void start_keyboard(void);
static void keytable_start(int layout);
static void keytable_stop(void);
static void dump_keytables_to_file(char *name);
static void stop_terminal(void);
static void start_disk(void);
static void do_part(char *);
static void start_floppy(void);
static void stop_disk(int token);
static void start_vnet(char *);
static FILE* open_file(const char* filename);
static void close_file(FILE* file);
static void write_to_syslog(char *message);
static void set_irq_value(int bits, int i1);
static void set_irq_range(int bits, int i1, int i2);
static int undefine_config_variable(const char *name);
static void check_user_var(char *name);
static char *run_shell(char *command);
static int for_each_handling(int loopid, char *varname, char *delim, char *list);
static void enter_user_scope(int incstackptr);
static void leave_user_scope(int incstackptr);
static void handle_features(int which, int value);
static void set_joy_device(char *devstring);
static int parse_timemode(const char *);
static void set_hdimage(struct disk *dptr, char *name);
static void set_drive_c(void);
static void set_default_drives(void);

	/* class stuff */
#define IFCLASS(m) if (is_in_allowed_classes(m))

#define CL_ALL			-1
#define CL_VAR		    0x200
#define CL_VPORT	   0x2000
#define CL_PORT		  0x20000
#define CL_PCI		  0x40000
#define CL_IRQ		 0x200000
#define CL_HARDRAM	0x1000000
#define CL_NET		0x2000000

static int is_in_allowed_classes(int mask);

#define TOF(x) ( x.type == TYPE_REAL ? x.value.r : x.value.i )
#define V_VAL(x,y,z) \
do { x.type = y.type; if (x.type == TYPE_REAL) x.value.r = (z); \
      else x.value.i = (z); } \
while (0)

	/* variables in lexer.l */




	/* for unicode keyboard plugin */
static void keyb_mod(int wich, t_keysym keynum, int unicode);
static void dump_keytable_part(FILE *f, t_keysym *map, int size);



#include "translate/translate.h"
#include "translate/dosemu_charset.h"
	/* for translate plugin */

static void set_internal_charset(char *charset_name);
static void set_external_charset(char *charset_name);

enum {
	TYPE_NONE,
	TYPE_INTEGER,
	TYPE_BOOLEAN,
	TYPE_REAL
} _type;

%}



%start lines

%union {
	int i_value;
	char *s_value;
	float r_value;
	struct {
		int type;
		union {
			int i;
			float r;
		} value;
	} t_value;
};

%{
#include "lexer.h"
%}

%token <i_value> INTEGER L_OFF L_ON L_AUTO L_YES L_NO CHIPSET_TYPE
%token <i_value> KEYB_LAYOUT
%token <r_value> REAL
%token <s_value> STRING VARIABLE

	/* needed for expressions */
%token EXPRTEST
%token INTCAST REALCAST
%left AND_OP OR_OP XOR_OP SHR_OP SHL_OP
%right NOT_OP /* logical NOT */
%left EQ_OP GE_OP LE_OP '=' '<' '>' NEQ_OP
%left STR_EQ_OP STR_NEQ_OP
%left L_AND_OP L_OR_OP
%left '+' '-'
%left '*' '/'
%right UMINUS UPLUS BIT_NOT_OP

%token	STRLEN STRTOL STRNCMP STRCAT STRPBRK STRSPLIT STRCHR STRRCHR STRSTR
%token	STRDEL STRSPN STRCSPN SHELL
%token	DEFINED
%type	<i_value> expression int_expr bool_expr
%type	<r_value> real_expression real_expr
%type	<t_value> typed_expr
%type	<s_value> string_unquoted string_expr variable_content strarglist strarglist_item

	/* flow control */
%token DEFINE UNDEF IFSTATEMENT WHILESTATEMENT FOREACHSTATEMENT
%token <i_value> ENTER_USER_SPACE LEAVE_USER_SPACE

	/* variable handling */
%token CHECKUSERVAR

	/* main options */
%token DOSBANNER FASTFLOPPY HOGTHRESH SPEAKER IPXSUPPORT IPXNETWORK NOVELLHACK
%token ETHDEV TAPDEV VDESWITCH SLIRPARGS VNET
%token DEBUG MOUSE SERIAL COM KEYBOARD TERMINAL VIDEO EMURETRACE TIMER
%token MATHCO CPU CPUSPEED RDTSC BOOTDRIVE SWAP_BOOTDRIVE
%token L_XMS L_DPMI DPMI_LIN_RSV_BASE DPMI_LIN_RSV_SIZE PM_DOS_API NO_NULL_CHECKS
%token PORTS DISK DOSMEM EXT_MEM
%token L_EMS UMB_A0 UMB_B0 UMB_F0 EMS_SIZE EMS_FRAME EMS_UMA_PAGES EMS_CONV_PAGES
%token TTYLOCKS L_SOUND L_SND_OSS L_JOYSTICK FULL_FILE_LOCKS
%token ABORT WARN
%token L_FLOPPY EMUSYS L_X L_SDL
%token DOSEMUMAP LOGBUFSIZE LOGFILESIZE MAPPINGDRIVER
%token LFN_SUPPORT FFS_REDIR SET_INT_HOOKS FINT_REVECT
	/* speaker */
%token EMULATED NATIVE
	/* cpuemu */
%token CPUEMU CPU_VM CPU_VM_DPMI VM86 FULL VM86SIM FULLSIM KVM
	/* keyboard */
%token RAWKEYBOARD
%token PRESTROKE
%token KEYTABLE SHIFT_MAP ALT_MAP NUMPAD_MAP DUMP
%token DGRAVE DACUTE DCIRCUM DTILDE DBREVE DABOVED DDIARES DABOVER DDACUTE DCEDILLA DIOTA DOGONEK DCARON
	/* ipx */
%token NETWORK PKTDRIVER
        /* lock files */
%token DIRECTORY NAMESTUB BINARY
	/* serial */
%token BASE IRQ DEVICE CHARSET BAUDRATE VIRTUAL VMODEM PSEUDO RTSCTS LOWLAT PCCOM
	/* mouse */
%token MICROSOFT MS3BUTTON LOGITECH MMSERIES MOUSEMAN HITACHI MOUSESYSTEMS BUSMOUSE PS2 IMPS2
%token INTERNALDRIVER EMULATE3BUTTONS CLEARDTR
	/* x-windows */
%token L_DISPLAY L_TITLE X_TITLE_SHOW_APPNAME ICON_NAME X_BLINKRATE X_SHARECMAP X_MITSHM X_FONT
%token X_FIXED_ASPECT X_ASPECT_43 X_LIN_FILT X_BILIN_FILT X_MODE13FACT X_WINSIZE
%token X_GAMMA X_FULLSCREEN VGAEMU_MEMSIZE VESAMODE X_LFB X_PM_INTERFACE X_MGRAB_KEY X_BACKGROUND_PAUSE
	/* sdl */
%token SDL_HWREND SDL_FONT
	/* video */
%token VGA MGA CGA EGA NONE CONSOLE GRAPHICS CHIPSET FULLREST PARTREST
%token MEMSIZE VBIOS_SIZE_TOK VBIOS_SEG VGAEMUBIOS_FILE VBIOS_FILE 
%token VBIOS_COPY VBIOS_MMAP DUALMON
%token VBIOS_POST

%token FORCE_VT_SWITCH PCI
	/* terminal */
%token COLOR ESCCHAR XTERM_TITLE SIZE
	/* debug */
%token IO PORT CONFIG READ WRITE KEYB PRINTER WARNING GENERAL HARDWARE
%token L_IPC SOUND
%token TRACE CLEAR

	/* printer */
%token LPT COMMAND TIMEOUT L_FILE
	/* disk */
%token L_PARTITION WHOLEDISK THREEINCH THREEINCH_720 THREEINCH_2880 FIVEINCH FIVEINCH_360 READONLY LAYOUT
%token SECTORS CYLINDERS TRACKS HEADS OFFSET HDIMAGE HDTYPE1 HDTYPE2 HDTYPE9 DISKCYL4096
%token DEFAULT_DRIVES
	/* ports/io */
%token RDONLY WRONLY RDWR ORMASK ANDMASK RANGE FAST SLOW
	/* Silly interrupts */
%token SILLYINT USE_SIGIO
	/* hardware ram mapping */
%token HARDWARE_RAM
        /* Sound Emulation */
%token SB_BASE SB_IRQ SB_DMA SB_HDMA MPU_BASE MPU_IRQ MPU_IRQ_MT32 MIDI_SYNTH
%token SOUND_DRIVER MIDI_DRIVER MUNT_ROMS SND_PLUGIN_PARAMS PCM_HPF MIDI_FILE WAV_FILE
	/* CD-ROM */
%token CDROM
	/* ASPI driver */
%token ASPI DEVICETYPE TARGET
	/* features */
%token FEATURE
	/* joystick */
%token JOYSTICK JOY_DEVICE JOY_DOS_MIN JOY_DOS_MAX JOY_GRANULARITY JOY_LATENCY
	/* Hacks */
%token CLI_TIMEOUT
%token TIMEMODE

	/* we know we have 1 shift/reduce conflict :-( 
	 * and tell the parser to ignore that */
	/* %expect 1 */

%type <i_value> int_bool irq_bool bool speaker floppy_bool cpuemu
%type <i_value> cpu_vm cpu_vm_dpmi

	/* special bison declaration */
%token <i_value> UNICODE
%token SHIFT_ALT_MAP CTRL_MAP CTRL_ALT_MAP


	/* charset */
%token INTERNAL EXTERNAL

%%

lines		: line
		| lines line
		| lines optdelim line
		;

optdelim	: ';'
		| optdelim ';'
		;

line:		CHARSET '{' charset_flags '}' {}
		/* charset flags */
		| HOGTHRESH expression	{ config.hogthreshold = $2; }
		| DEFINE string_unquoted{ IFCLASS(CL_VAR){ define_config_variable($2);} free($2); }
		| UNDEF string_unquoted	{ IFCLASS(CL_VAR){ undefine_config_variable($2);} free($2); }
		| IFSTATEMENT '(' expression ')' {
			/* NOTE:
			 * We _need_ absolutely to return to state stack 0
			 * because we 'backward' modify the input stream for
			 * the parser (in lexer). Hence, _if_ the parser needs
			 * to read one token more than needed, we are lost,
			 * because we can't discard it. So please, don't
			 * play with the grammar without knowing what you do.
			 * The ')' _will_ return to state stack 0, but fiddling
			 * with brackets '()' in the underlaying 'expression'
			 * rules may distroy this.
			 *                          -- Hans 971231
			 */
			tell_lexer_if($3);
		}
		/* Note: the below syntax of the while__yy__ statement
		 * is internal and _not_ visible out side.
		 * The visible syntax is:
		 *	while ( expression )
		 *	   <loop contents>
		 *	done
		 */
		| WHILESTATEMENT INTEGER ',' '(' expression ')' {
			tell_lexer_loop($2, $5);
		}
		| FOREACHSTATEMENT INTEGER ',' VARIABLE '(' string_expr ',' strarglist ')' {
			tell_lexer_loop($2, for_each_handling($2,$4,$6,$8));
			free($4); free($6); free($8);
		}
		| SHELL '(' strarglist ')' {
			char *s = run_shell($3);
			if (s) free(s);
			free($3);
		}
		| ENTER_USER_SPACE { enter_user_scope($1); }
		| LEAVE_USER_SPACE { leave_user_scope($1); }
		| VARIABLE '=' strarglist {
		    if (!parser_version_3_style_used) {
			parser_version_3_style_used = 1;
			define_config_variable(CONFNAME_V3USED);
		    }
		    if ((strpbrk($1, "uhc") == $1) && ($1[1] == '_'))
			yyerror("reserved variable %s can't be set\n", $1);
		    else {
			if (user_scope_level) {
			    char *s = malloc(strlen($1)+sizeof(USERVAR_PREF));
			    strcpy(s, USERVAR_PREF);
			    strcat(s,$1);
			    setenv(s, $3, 1);
			    free(s);
			}
			else IFCLASS(CL_VAR) setenv($1, $3, 1);
		    }
		    free($1); free($3);
		}
		| CHECKUSERVAR check_user_var_list
		| EXPRTEST typed_expr {
		    if ($2.type == TYPE_REAL)
			c_printf("CONF TESTING: exprtest real %f\n", $2.value.r);
		    else
			c_printf("CONF TESTING: exprtest int %d\n", $2.value.i);
		}
		/* abandoning 'single' abort due to shift/reduce conflicts
		   Just use ' abort "" '
		| ABORT			{ exit(99); }
		*/
		| ABORT strarglist
		    { if ($2[0]) fprintf(stderr,"CONF aborted with: %s\n", $2);
			exit(99);
		    }
		| WARN strarglist	{ c_printf("CONF: %s\n", $2); free($2); }
 		| EMUSYS string_expr
		    {
		    free(config.emusys); config.emusys = $2;
		    c_printf("CONF: config.emusys = '%s'\n", $2);
		    }
		| EMUSYS '{' string_expr '}'
		    {
		    free(config.emusys); config.emusys = $3;
		    c_printf("CONF: config.emusys = '%s'\n", $3);
		    }
		| DOSEMUMAP string_expr
		    {
		    DOSEMU_MAP_PATH = $2;
		    c_printf("CONF: dosemu.map path = '%s'\n", $2);
		    }
		| MAPPINGDRIVER string_expr
		    {
		    free(config.mappingdriver); config.mappingdriver = $2;
		    c_printf("CONF: mapping driver = '%s'\n", $2);
		    }
		| FULL_FILE_LOCKS bool
		    {
		    config.full_file_locks = ($2!=0);
		    }
		| LFN_SUPPORT bool
		    {
		    config.lfn = ($2!=0);
		    }
		| FINT_REVECT bool
		    {
		    config.force_revect = ($2 == -2 ? 1 : $2);
		    }
		| SET_INT_HOOKS bool
		    {
		    config.int_hooks = ($2 == -2 ? 1 : $2);
		    }
		| FFS_REDIR bool
		    {
		    config.force_redir = ($2!=0);
		    }
		| FASTFLOPPY floppy_bool
			{
			config.fastfloppy = ($2!=0);
			c_printf("CONF: fastfloppy = %d\n", config.fastfloppy);
			}
		| CPU expression
			{
			int cpu = cpu_override (($2%100)==86?($2/100)%10:0);
			if (cpu > 0) {
				c_printf("CONF: CPU set to %d86\n",cpu);
				vm86s.cpu_type = cpu;
			}
			else
				yyerror("error in CPU user override\n");
			}
		| CPU EMULATED
			{
			vm86s.cpu_type = 5;
#ifdef X86_EMULATOR
			config.cpuemu = 1;
			c_printf("CONF: CPUEMU set to %d for %d86\n",
				config.cpuemu, (int)vm86s.cpu_type);
#endif
			}
		| CPU_VM cpu_vm
			{
			config.cpu_vm = $2;
			c_printf("CONF: CPU VM set to %d\n", config.cpu_vm);
			}
		| CPU_VM_DPMI cpu_vm_dpmi
			{
			config.cpu_vm_dpmi = $2;
			c_printf("CONF: CPU VM set to %d for DPMI\n",
				 config.cpu_vm_dpmi);
			}
		| CPUEMU cpuemu
			{
#ifdef X86_EMULATOR
			config.cpuemu = $2;
			if (config.cpuemu > 4) {
				config.cpuemu -= 2;
#ifdef HOST_ARCH_X86
				config.cpusim = 1;
#endif
			}
			c_printf("CONF: %s CPUEMU set to %d for %d86\n",
				CONFIG_CPUSIM ? "simulated" : "JIT",
				config.cpuemu, (int)vm86s.cpu_type);
#endif
			}
		| CPUSPEED real_expression
			{ 
#if 0 /* no longer used, but left in for dosemu.conf compatibility */
			if (config.realcpu >= CPU_586) {
			  config.cpu_spd = ((double)LLF_US)/$2;
			  config.cpu_tick_spd = ((double)LLF_TICKS)/$2;
			  c_printf("CONF: CPU speed = %g\n", ((double)$2));
			}
#endif
			}
		| CPUSPEED INTEGER INTEGER
			{ 
#if 0 /* no longer used, but left in for dosemu.conf compatibility */
			if (config.realcpu >= CPU_586) {
			  config.cpu_spd = (LLF_US*$3)/$2;
			  config.cpu_tick_spd = (LLF_TICKS*$3)/$2;
			  c_printf("CONF: CPU speed = %d/%d\n", $2, $3);
			}
#endif
			}
		| RDTSC bool
		    {
			config.rdtsc = ($2!=0);
			c_printf("CONF: %sabling use of pentium timer\n",
				(config.rdtsc?"En":"Dis"));
		    }
		| PCI bool
		    {
		      config.pci_video = ($2!=0);
		      IFCLASS(CL_PCI) {}
		      config.pci = (abs($2)==2); 
		    }
		| BOOTDRIVE string_expr
                    {
                      if ($2[0] == 0) {
		        config.hdiskboot = -1;
		      } else if ($2[0] >= 'a') {
		        config.hdiskboot = $2[0] - 'a';
		      } else {
		        error("wrong value for $_bootdrive\n");
		        config.hdiskboot = -1;
		      }
		      free($2);
		    }
		| SWAP_BOOTDRIVE bool
		    {
		      config.swap_bootdrv = ($2!=0);
		    }
		| DEFAULT_DRIVES int_expr
		    {
		      c_printf("default_drives %i\n", $2);
		      switch ($2) {
		      case 0:
		        set_drive_c();
		        break;
		      case 1:
		        set_default_drives();
		        break;
		      default:
			error("Path group %i not implemented\n", $2);
			exit(1);
		      }
		    }
		| TIMER expression
		    {
		    config.freq = $2;
		    if ($2) {
		        config.update = 1000000 / $2;
		    } else {
			config.update = 54925;
			config.freq = 18;
		    }
		    c_printf("CONF: timer freq=%d, update=%d\n",config.freq,config.update);
		    }
		| LOGBUFSIZE expression
		    {
		      char *b;
		      flush_log();
		      b = malloc($2+1024);
		      if (!b) {
			error("cannot get logbuffer\n");
			exit(1);
		      }
		      logptr = logbuf = b;
		      logbuf_size = $2;
		    }
		| LOGFILESIZE expression
		    {
		      logfile_limit = $2;
		    }
		| DOSBANNER bool
		    {
		    config.dosbanner = ($2!=0);
		    c_printf("CONF: dosbanner %s\n", ($2) ? "on" : "off");
		    }
		| EMURETRACE bool
		    { IFCLASS(CL_VPORT){
		    if ($2 && !config.emuretrace && priv_lvl)
		      yyerror("Can not modify video port access in user config file");
		    config.emuretrace = ($2!=0);
		    c_printf("CONF: emu_retrace %s\n", ($2) ? "on" : "off");
		    }}
		| L_EMS '{' ems_flags '}'
		| L_EMS int_bool
		    {
		    if ($2 >= 0) config.ems_size = $2;
		    if ($2 > 0) c_printf("CONF: %dk bytes EMS memory\n", $2);
		    }
		| UMB_A0 bool
		    {
		    config.umb_a0 = $2;
		    if ($2 > 0) c_printf("CONF: umb at 0a0000: %s\n", ($2) ? "on" : "off");
		    }
		| UMB_B0 bool
		    {
		    config.umb_b0 = ($2!=0);
		    if ($2 > 0) c_printf("CONF: umb at 0b0000: %s\n", ($2) ? "on" : "off");
		    }
		| UMB_F0 bool
		    {
		    config.umb_f0 = ($2!=0);
		    if ($2 > 0) c_printf("CONF: umb at 0f0000: %s\n", ($2) ? "on" : "off");
		    }
		| L_DPMI int_bool
		    {
		    if ($2>=0) config.dpmi = $2;
		    c_printf("CONF: DPMI-Server %s (%#x)\n", ($2) ? "on" : "off", ($2));
		    }
		| DPMI_LIN_RSV_BASE int_bool
		    {
		    config.dpmi_lin_rsv_base = $2;
		    c_printf("CONF: DPMI linear reserve base addr = %#x\n", $2);
		    }
		| DPMI_LIN_RSV_SIZE int_bool
		    {
		    config.dpmi_lin_rsv_size = $2;
		    c_printf("CONF: DPMI linear reserve size = %#x\n", $2);
		    }
		| PM_DOS_API bool
		    {
		    config.pm_dos_api = ($2!=0);
		    c_printf("CONF: PM DOS API Translator %s\n", ($2) ? "on" : "off");
		    }
		| NO_NULL_CHECKS bool
		    {
		    config.no_null_checks = ($2!=0);
		    c_printf("CONF: No DJGPP NULL deref checks: %s\n", ($2) ? "on" : "off");
		    }
		| DOSMEM int_bool	{ if ($2>=0) config.mem_size = $2; }
		| EXT_MEM int_bool
		    {
		    if ($2>=0) config.ext_mem = $2;
		    if ($2 > 0) c_printf("CONF: %dk bytes XMS memory\n", $2);
		    }
		| MATHCO bool		{ config.mathco = ($2!=0); }
		| IPXSUPPORT bool
		    {
		    config.ipxsup = ($2!=0);
		    c_printf("CONF: IPX support %s\n", ($2) ? "on" : "off");
		    }
		| IPXNETWORK int_bool	{ config.ipx_net = $2; }
		| PKTDRIVER bool
		    {
		      if (config.vnet == VNET_TYPE_TAP || config.vnet == VNET_TYPE_VDE || $2 == 0 || is_in_allowed_classes(CL_NET)) {
			config.pktdrv = ($2!=0);
			c_printf("CONF: Packet Driver %s.\n", 
				($2) ? "enabled" : "disabled");
		      }
		    }
		| ETHDEV string_expr	{ free(config.ethdev); config.ethdev = $2; }
		| TAPDEV string_expr	{ free(config.tapdev); config.tapdev = $2; }
		| VDESWITCH string_expr	{ free(config.vdeswitch); config.vdeswitch = $2; }
		| SLIRPARGS string_expr	{ free(config.slirp_args); config.slirp_args = $2; }
		| NOVELLHACK bool	{ config.pktflags = ($2!=0); }
		| VNET string_expr	{ start_vnet($2); free($2); }
		| SPEAKER speaker
		    {
		    if ($2 == SPKR_NATIVE) {
		      if (can_do_root_stuff) {
                        c_printf("CONF: allowing speaker port access!\n");
		      } else {
                        c_printf("CONF: native speaker not allowed: emulate\n");
			$2 = SPKR_EMULATED;
		      }
		    }
		    else
                      c_printf("CONF: not allowing speaker port access\n");
		    config.speaker = $2;
		    }
		| VIDEO
		    { start_video(); }
		  '{' video_flags '}'
		    { stop_video(); }
		| XTERM_TITLE string_expr { free(config.xterm_title); config.xterm_title = $2; }
		| TERMINAL
                  '{' term_flags '}'
		    { stop_terminal(); }
		| DEBUG strarglist {
			parse_debugflags($2, 1);
			free($2);
		}
		| DEBUG
		    { start_debug(); }
		  '{' debug_flags '}'
		| MOUSE
		    { start_mouse(); }
		  '{' mouse_flags '}'
		    { stop_mouse(); }
                | TTYLOCKS
                  '{' ttylocks_flags '}'
                    { stop_ttylocks(); }
		| SERIAL
		    { start_serial(); }
		  '{' serial_flags '}'
		    { stop_serial(); }
		| KEYBOARD
		    { start_keyboard(); }
	          '{' keyboard_flags '}'
		| KEYTABLE KEYB_LAYOUT
			{keytable_start($2);}
		  '{' keyboard_mods '}'
		  	{keytable_stop();}
 		| PRESTROKE string_expr
		    {
		    append_pre_strokes($2);
		    c_printf("CONF: appending pre-strokes '%s'\n", $2);
		    free($2);
		    }
		| KEYTABLE DUMP string_expr {
			dump_keytables_to_file($3);
			free($3);
		    }
		| PORTS
		    { IFCLASS(CL_PORT) start_ports(); }
		  '{' port_flags '}'
		| TRACE PORTS '{' trace_port_flags '}'
		| DISK
		    { start_disk(); }
		  '{' disk_flags '}'
		    { stop_disk(DISK); }
		| L_FLOPPY
		    { start_floppy(); }
		  '{' floppy_flags '}'
		    { stop_disk(L_FLOPPY); }
                | CDROM '{' string_expr '}'
                    {
		    static int which = 0;
		    if (which >= 3) {
			c_printf("CONF: too many cdrom drives defined\n");
			free($3);
		    }
		    else {
			Path_cdrom[which] = $3;
			c_printf("CONF: cdrom MSCD000%d on %s\n", which+1 ,$3);
			which++;
		    }
		    }
                | ASPI '{' string_expr DEVICETYPE string_expr TARGET expression '}'
                    {
		    char *s = aspi_add_device($3, $5, $7);
		    if (s) {
			c_printf("CONF: aspi available for %s\n", s);
			free(s);
		    }
		    else c_printf("CONF: aspi device %s not available\n", $3);
		    free($3);
		    free($5);
		    }
		| PRINTER
		    { start_printer(); }
		  '{' printer_flags '}'
		    { stop_printer(); }
		| L_X '{' x_flags '}'
		| L_SDL '{' sdl_flags '}'
		| SOUND bool	{ config.sound = ($2!=0); }
                | L_SOUND '{' sound_flags '}'
		| L_JOYSTICK bool { if (! $2) { config.joy_device[0] = config.joy_device[1] = NULL; } }
                | L_JOYSTICK '{' joystick_flags '}'
		| SILLYINT
                    { IFCLASS(CL_IRQ) config.sillyint=0; }
                  '{' sillyint_flags '}'
		| SILLYINT irq_bool
                    { IFCLASS(CL_IRQ) if ($2) {
		        config.sillyint = 1 << $2;
		        c_printf("CONF: IRQ %d for irqpassing\n", $2);
		      }
		    }
		| HARDWARE_RAM
                    { IFCLASS(CL_HARDRAM) {}
		    if (priv_lvl)
		      yyerror("Can not change hardware ram access settings in user config file");
		    }
                   '{' hardware_ram_flags '}'
		| FEATURE '{' expression '=' expression '}'
		    {
			handle_features($3, $5);
		    }
		| CLI_TIMEOUT int_bool
		    { config.cli_timeout = $2; }
		| TIMEMODE string_expr
		    {
		    config.timemode = parse_timemode($2);
		    c_printf("CONF: time mode = '%s'\n", $2);
		    free($2);
		    }
		| STRING
		    { yyerror("unrecognized command '%s'", $1); free($1); }
		| error
		;

expression:	typed_expr { $$ = TOF($1); }
		;

real_expression:typed_expr { $$ = TOF($1); }
		;

	/* run-time typed expressions */

typed_expr:	  int_expr {$$.type = TYPE_INTEGER; $$.value.i=$1;}
		| bool_expr {$$.type = TYPE_BOOLEAN; $$.value.i=$1;}
		| real_expr {$$.type = TYPE_REAL; $$.value.r=$1;}
		| typed_expr '+' typed_expr
			{V_VAL($$,$1,TOF($1) + TOF($3)); }
		| typed_expr '-' typed_expr
			{V_VAL($$,$1,TOF($1) - TOF($3)); }
		| typed_expr '*' typed_expr
			{V_VAL($$,$1,TOF($1) * TOF($3)); }
		| typed_expr '/' typed_expr {
			if (TOF($3))	V_VAL($$,$1,TOF($1) / TOF($3));
			else V_VAL($$,$1,TOF($3));
		}
		| '-' typed_expr %prec UMINUS 
			{V_VAL($$,$2,-TOF($2)); }
		| '+' typed_expr %prec UPLUS
			{V_VAL($$,$2,TOF($2)); }
		| typed_expr SHR_OP typed_expr
			{ unsigned int shift = (1 << (int)TOF($3));
			if (!shift) $$ = $1;
			else V_VAL($$, $1, TOF($1) / shift);}
		| typed_expr SHL_OP typed_expr
			{ unsigned int shift = (1 << (int)TOF($3));
			if (!shift) $$ = $1;
			else V_VAL($$, $1, TOF($1) * shift);}
		| variable_content {
			char *s;
			$$.type = TYPE_INTEGER;
			$$.value.i = strtoul($1,&s,0);
			switch (*s) {
				case '.':  case 'e':  case 'E':
				/* we assume a real number */
				$$.type = TYPE_REAL;
				$$.value.r = strtod($1,0);
			}
			free($1);
		}
		| '(' typed_expr ')' {$$ = $2;}
		;

int_expr:	  INTEGER
		| typed_expr AND_OP typed_expr
			{$$ = (int)TOF($1) & (int)TOF($3); }
		| typed_expr OR_OP typed_expr
			{$$ = (int)TOF($1) | (int)TOF($3); }
		| typed_expr XOR_OP typed_expr
			{$$ = (int)TOF($1) ^ (int)TOF($3); }
		| BIT_NOT_OP typed_expr %prec BIT_NOT_OP
			{$$ = (int)TOF($2) ^ (-1); }
		| L_AUTO	{$$ = -1; }
		| INTCAST '(' typed_expr ')' {$$ = TOF($3);}
		| STRTOL '(' string_expr ')' {
			$$ = strtol($3,0,0);
			free($3);
		}
		| STRLEN '(' string_expr ')' {
			$$ = strlen($3);
			free($3);
		}
		| STRNCMP '(' string_expr ',' string_expr ',' expression ')' {
			$$ = strncmp($3,$5,$7);
			free($3); free($5);
		}
		| STRPBRK '(' string_expr ',' string_expr ')' {
			char *s = strpbrk($3,$5);
			if (s) $$ = s - $3;
			else $$ = -1;
			free($3); free($5);
		}
		| STRCHR '(' string_expr ',' string_expr ')' {
			char *s = strchr($3,$5[0]);
			if (s) $$ = s - $3;
			else $$ = -1;
			free($3); free($5);
		}
		| STRRCHR '(' string_expr ',' string_expr ')' {
			char *s = strrchr($3,$5[0]);
			if (s) $$ = s - $3;
			else $$ = -1;
			free($3); free($5);
		}
		| STRSTR '(' string_expr ',' string_expr ')' {
			char *s = strstr($3,$5);
			if (s) $$ = s - $3;
			else $$ = -1;
			free($3); free($5);
		}
		| STRSPN '(' string_expr ',' string_expr ')' {
			$$ = strspn($3,$5);
			free($3); free($5);
		}
		| STRCSPN '(' string_expr ',' string_expr ')' {
			$$ = strcspn($3,$5);
			free($3); free($5);
		}
		| STRING {
			if ( $1[0] == '\'' && $1[1] && $1[2] == '\'' && !$1[3] )
				$$ = $1[1];
			else	yyerror("unrecognized expression '%s'", $1);
			free($1);
		}
		;

bool_expr:	  typed_expr EQ_OP typed_expr
			{$$ = TOF($1) == TOF($3); }
		| typed_expr NEQ_OP typed_expr
			{$$ = TOF($1) != TOF($3); }
		| typed_expr GE_OP typed_expr
			{$$ = TOF($1) >= TOF($3); }
		| typed_expr LE_OP typed_expr
			{$$ = TOF($1) <= TOF($3); }
		| typed_expr '<' typed_expr
			{$$ = TOF($1) < TOF($3); }
		| typed_expr '>' typed_expr
			{$$ = TOF($1) > TOF($3); }
		| typed_expr L_AND_OP typed_expr
			{$$ = TOF($1) && TOF($3); }
		| typed_expr L_OR_OP typed_expr
			{$$ = TOF($1) || TOF($3); }
		| string_expr STR_EQ_OP string_expr
			{$$ = strcmp($1,$3) == 0; free($1); free($3); }
		| string_expr STR_NEQ_OP string_expr
			{$$ = strcmp($1,$3) != 0; free($1); free($3); }
		| NOT_OP typed_expr {$$ = (TOF($2) ? 0:1); }
		| L_YES		{$$ = -2; }
		| L_NO		{$$ = 0; }
		| L_ON		{$$ = -2; }
		| L_OFF		{$$ = 0; }
		| DEFINED '(' string_unquoted ')' {
			$$ = get_config_variable($3) !=0;
			free($3);
		}
		;

real_expr:	  REAL
		| REALCAST '(' typed_expr ')' {$$ = TOF($3);}
		;

variable_content:
		VARIABLE {
			const char *s = $1;
			if (get_config_variable(s))
				s = "1";
			else if (strncmp("c_",s,2)
					&& strncmp("u_",s,2)
					&& strncmp("h_",s,2) ) {
				s = checked_getenv(s);
				if (!s) s = "";
			}
			else
				s = "0";
			$$ = strdup(s);
			free($1);
		}
		;

string_unquoted:STRING {
			$$ = $1;
			if ($$[0] == '\'' || $$[0] == '\"') {
				size_t len = strlen($1) - 2;
				memmove($$, $$+1, len);
				$$[len] = '\0';
			}
		}
		;

string_expr:	string_unquoted
		| STRCAT '(' strarglist ')' {$$ = $3; }
		| STRSPLIT '(' string_expr ',' expression ',' expression ')' {
			int i = $5;
			int len = $7;
			int slen = strlen($3);
			if ((i >=0) && (i < slen) && (len > 0)) {
				if ((i+len) > slen) len = slen - i;
				$3[i+len] = 0;
				$$ = strdup($3 + i);
			}
			else
				$$ = strdup("");
			free($3);
		}
		| STRDEL '(' string_expr ',' expression ',' expression ')' {
			int i = $5;
			int len = $7;
			int slen = strlen($3);
			char *s = strdup($3);
			if ((i >=0) && (i < slen) && (len > 0)) {
				if ((i+len) > slen) s[i] = 0;
				else memmove(s+i, s+i+len, slen-i-len+1);
			}
			free($3);
			$$ = s;
		}
		| SHELL '(' strarglist ')' {
			$$ = run_shell($3);
			free($3);
		}
		| variable_content {$$ = $1;}
		;

strarglist:	strarglist_item
		| strarglist ',' strarglist_item {
			char *s = malloc(strlen($1)+strlen($3)+1);
			strcpy(s, $1);
			strcat(s, $3);
			$$ = s;
			free($1); free($3);
		}
		;

strarglist_item: string_expr
		| '(' typed_expr ')' {
			int ret;
			if ($2.type == TYPE_REAL) {
				ret = asprintf(&$$, "%g", $2.value.r);
				assert(ret != -1);
			} else {
				ret = asprintf(&$$, "%d", $2.value.i);
				assert(ret != -1);
			}
		}
		;

check_user_var_list:
		VARIABLE {
			check_user_var($1);
			free($1);
		}
		| check_user_var_list ',' VARIABLE {
			check_user_var($3);
			free($3);
		}
		;

	/* x-windows */

x_flags		: x_flag
		| x_flags x_flag
		;
x_flag		: L_DISPLAY string_expr	{ free(config.X_display); config.X_display = $2; }
		| L_TITLE string_expr	{ free(config.X_title); config.X_title = $2; }
		| X_TITLE_SHOW_APPNAME bool	{ config.X_title_show_appname = ($2!=0); }
		| ICON_NAME string_expr	{ free(config.X_icon_name); config.X_icon_name = $2; }
		| X_BLINKRATE expression	{ config.X_blinkrate = $2; }
		| X_SHARECMAP		{ config.X_sharecmap = 1; }
		| X_MITSHM              { config.X_mitshm = 1; }
		| X_MITSHM bool         { config.X_mitshm = ($2!=0); }
		| X_FONT string_expr		{ free(config.X_font); config.X_font = $2; }
		| X_FIXED_ASPECT bool   { config.X_fixed_aspect = ($2!=0); }
		| X_ASPECT_43           { config.X_aspect_43 = 1; }
		| X_LIN_FILT            { config.X_lin_filt = 1; }
		| X_BILIN_FILT          { config.X_bilin_filt = 1; }
		| X_MODE13FACT expression  { config.X_mode13fact = $2; }
		| X_WINSIZE INTEGER INTEGER
                   {
                     config.X_winsize_x = $2;
                     config.X_winsize_y = $3;
                   }
		| X_WINSIZE expression ',' expression
                   {
                     config.X_winsize_x = $2;
                     config.X_winsize_y = $4;
                   }
		| X_GAMMA expression  { config.X_gamma = $2; }
		| X_FULLSCREEN bool   { config.X_fullscreen = $2; }
		| VGAEMU_MEMSIZE expression	{ config.vgaemu_memsize = $2; }
		| VESAMODE INTEGER INTEGER { set_vesamodes($2,$3,0);}
		| VESAMODE INTEGER INTEGER INTEGER { set_vesamodes($2,$3,$4);}
		| VESAMODE expression ',' expression { set_vesamodes($2,$4,0);}
		| VESAMODE expression ',' expression ',' expression
			{ set_vesamodes($2,$4,$6);}
		| X_LFB bool            { config.X_lfb = ($2!=0); }
		| X_PM_INTERFACE bool   { config.X_pm_interface = ($2!=0); }
		| X_MGRAB_KEY string_expr { free(config.X_mgrab_key); config.X_mgrab_key = $2; }
		| X_BACKGROUND_PAUSE bool	{ config.X_background_pause = ($2!=0); }
		;

  /* sdl */
sdl_flags	: sdl_flag
		| sdl_flags sdl_flag
		;
sdl_flag	: SDL_HWREND expression	{ config.sdl_hwrend = ($2!=0); }
		| SDL_FONT string_expr	{ free(config.sdl_font); config.sdl_font = $2; }
		;

	/* sb emulation */
 
sound_flags	: sound_flag
		| sound_flags sound_flag
		;
sound_flag	: SB_BASE expression	{ config.sb_base = $2; }
		| SB_DMA expression	{ config.sb_dma = $2; }
		| SB_HDMA expression { config.sb_hdma = $2; }
		| SB_IRQ expression	{ config.sb_irq = $2; }
		| MPU_BASE expression	{ config.mpu401_base = $2; }
		| MIDI_SYNTH string_expr	{ free(config.midi_synth); config.midi_synth = $2; }
		| MPU_IRQ int_bool	{ config.mpu401_irq = $2; }
		| MPU_IRQ_MT32 expression	{ config.mpu401_irq_mt32 = $2; }
		| SOUND_DRIVER string_expr	{ free(config.sound_driver); config.sound_driver = $2; }
		| MIDI_DRIVER string_expr	{ free(config.midi_driver); config.midi_driver = $2; }
		| MUNT_ROMS string_expr
			{
				free(config.munt_roms_dir);
				config.munt_roms_dir = concat_dir(LOCALDIR, $2);
				free($2);
			}
		| SND_PLUGIN_PARAMS string_expr	{ free(config.snd_plugin_params); config.snd_plugin_params = $2; }
		| PCM_HPF bool		{ config.pcm_hpf = ($2!=0); }
		| MIDI_FILE string_expr	{ free(config.midi_file); config.midi_file = $2; }
		| WAV_FILE string_expr	{ free(config.wav_file); config.wav_file = $2; }
		;

	/* joystick emulation */
 
joystick_flags	: joystick_flag
		| joystick_flags joystick_flag
		;
joystick_flag	: JOY_DEVICE string_expr      	{ set_joy_device($2); }
		| JOY_DOS_MIN expression	{ config.joy_dos_min = $2; }
		| JOY_DOS_MAX expression	{ config.joy_dos_max = $2; }
		| JOY_GRANULARITY expression	{ config.joy_granularity = $2; }
		| JOY_LATENCY expression	{ config.joy_latency = $2; }
		;

	/* video */

video_flags	: video_flag
		| video_flags video_flag
		;
video_flag	: VGA			{ config.cardtype = CARD_VGA; }
		| MGA			{ config.cardtype = CARD_MDA; }
		| CGA			{ config.cardtype = CARD_CGA; }
		| EGA			{ config.cardtype = CARD_EGA; }
		| NONE			{ config.cardtype = CARD_NONE; }
		| CHIPSET CHIPSET_TYPE
		    {
		    config.chipset = $2;
                    c_printf("CHIPSET: %d\n", $2);
		    }
		| MEMSIZE expression	{ config.gfxmemsize = $2; }
		| GRAPHICS
		    { config.vga = 1;
		    }
		| GRAPHICS L_AUTO
		    { config.vga = -1;
		    }
		| CONSOLE
		    { config.console_video = 1;
		    }
		| CONSOLE L_AUTO
		    { config.console_video = -1;
		    }
		| FULLREST		{ config.fullrestore = 1; }
		| PARTREST		{ config.fullrestore = 0; }
		| VBIOS_FILE string_expr	{ free(config.vbios_file); config.vbios_file = $2;
					  config.mapped_bios = 1;
					  config.vbios_copy = 0; }
		| VGAEMUBIOS_FILE string_expr	{ free(config.vgaemubios_file); config.vgaemubios_file = $2; }
		| VBIOS_COPY		{ free(config.vbios_file);
					  config.vbios_file = NULL;
					  config.mapped_bios = 1;
					  config.vbios_copy = 1; }
		| VBIOS_MMAP		{ free(config.vbios_file);
					  config.vbios_file = NULL;
					  config.mapped_bios = 1;
					  config.vbios_copy = 1; }
		| VBIOS_SEG expression
		   {
		   config.vbios_seg = $2;
		   c_printf("CONF: VGA-BIOS-Segment %x\n", $2);
		   if (($2 != 0xe000) && ($2 != 0xc000))
		      {
		      config.vbios_seg = detect_vbios_seg();
		      if (config.vbios_seg == -1) config.vbios_seg = 0xc000;
		      c_printf("CONF: VGA-BIOS-Segment set to 0x%x\n", config.vbios_seg);
		      }
		   }
		| VBIOS_SIZE_TOK expression
		   {
		   config.vbios_size = $2;
		   c_printf("CONF: VGA-BIOS-Size %x\n", $2);
		   if (($2 != 0x8000) && ($2 != 0x10000))
		      {
		      config.vbios_size = detect_vbios_size();
		      if (config.vbios_size == -1) config.vbios_size = 0x10000;
		      c_printf("CONF: VGA-BIOS-Size set to 0x%x\n", config.vbios_size);
		      }
		   }
		| VBIOS_POST		{ config.vbios_post = 1; }
		| DUALMON		{ config.dualmon = 1; }
		| FORCE_VT_SWITCH	{ config.force_vt_switch = 1; }
		| PCI			{ config.pci_video = 1; }
		| STRING
		    { yyerror("unrecognized video option '%s'", $1);
		      free($1); }
		| error
		;

	/* terminal */

term_flags	: term_flag
		| term_flags term_flag
		;
term_flag	: ESCCHAR expression       { config.term_esc_char = $2; }
		| COLOR bool		{ config.term_color = ($2!=0); }
		| SIZE string_expr         { config.term_size = $2; }
		| STRING
		    { yyerror("unrecognized terminal option '%s'", $1);
		      free($1); }
		| error
		;

/* method_val	: FAST			{ $$ = METHOD_FAST; } */
/* 		| NCURSES		{ $$ = METHOD_NCURSES; } */
/* 		; */

	/* debugging */

debug_flags	: debug_flag
		| debug_flags debug_flag
		;
debug_flag	: VIDEO bool		{ set_debug_level('v', ($2!=0)); }
		| L_OFF			{ set_debug_level('a', 0); }
		| SERIAL bool		{ set_debug_level('s', ($2!=0)); }
		| CONFIG bool		{ set_debug_level('c', ($2!=0)); }
		| DISK bool		{ set_debug_level('d', ($2!=0)); }
		| READ bool		{ set_debug_level('R', ($2!=0)); }
		| WRITE bool		{ set_debug_level('W', ($2!=0)); }
		| KEYB bool		{ set_debug_level('k', ($2!=0)); }
		| KEYBOARD bool		{ set_debug_level('k', ($2!=0)); }
		| PRINTER bool		{ set_debug_level('p', ($2!=0)); }
		| IO bool		{ set_debug_level('i', ($2!=0)); }
		| PORT bool 		{ set_debug_level('i', ($2!=0)); }
		| WARNING bool		{ set_debug_level('w', ($2!=0)); }
		| GENERAL bool		{ set_debug_level('g', ($2!=0)); }
		| L_XMS bool		{ set_debug_level('X', ($2!=0)); }
		| L_DPMI bool		{ set_debug_level('M', ($2!=0)); }
		| MOUSE bool		{ set_debug_level('m', ($2!=0)); }
		| HARDWARE bool		{ set_debug_level('h', ($2!=0)); }
		| L_IPC bool		{ set_debug_level('I', ($2!=0)); }
		| L_EMS bool		{ set_debug_level('E', ($2!=0)); }
		| NETWORK bool		{ set_debug_level('n', ($2!=0)); }
		| L_X bool		{ set_debug_level('X', ($2!=0)); }
		| L_SDL bool		{ set_debug_level('v', ($2!=0)); }
		| SOUND	bool		{ set_debug_level('S', ($2!=0)); }
		| JOYSTICK bool		{ set_debug_level('j', ($2!=0)); }
		| STRING
		    { yyerror("unrecognized debug flag '%s'", $1); free($1); }
		| error
		;

	/* mouse */

mouse_flags	: mouse_flag
		| mouse_flags mouse_flag
		;
mouse_flag	: DEVICE string_expr	{ free(mptr->dev); mptr->dev = $2; }
		| INTERNALDRIVER	{ mptr->intdrv = TRUE; }
		| EMULATE3BUTTONS	{ mptr->emulate3buttons = TRUE; }
		| BAUDRATE expression	{ mptr->baudRate = $2; }
		| CLEARDTR
		    { if (mptr->type == MOUSE_MOUSESYSTEMS)
			 mptr->cleardtr = TRUE;
		      else
			 yyerror("option CLEARDTR is only valid for MicroSystems-mice");
		    }
		| MICROSOFT
		  {
		  mptr->type = MOUSE_MICROSOFT;
		  mptr->flags = CS7 | CREAD | CLOCAL | HUPCL;
		  }
		| MS3BUTTON
		  {
		  mptr->type = MOUSE_MS3BUTTON;
		  mptr->flags = CS7 | CREAD | CLOCAL | HUPCL;
		  }
		| MOUSESYSTEMS
		  {
		  mptr->type = MOUSE_MOUSESYSTEMS;
		  mptr->flags = CS8 | CREAD | CLOCAL | HUPCL;
/* is cstopb needed?  mptr->flags = CS8 | CSTOPB | CREAD | CLOCAL | HUPCL; */
		  }
		| MMSERIES
		  {
		  mptr->type = MOUSE_MMSERIES;
		  mptr->flags = CS8 | PARENB | PARODD | CREAD | CLOCAL | HUPCL;
		  }
		| LOGITECH
		  {
		  mptr->type = MOUSE_LOGITECH;
		  mptr->flags = CS8 | CSTOPB | CREAD | CLOCAL | HUPCL;
		  }
		| PS2
		  {
		  mptr->type = MOUSE_PS2;
		  mptr->flags = 0;
		  }
		| IMPS2
		  {
		  mptr->type = MOUSE_IMPS2;
		  mptr->flags = 0;
		  }
		| MOUSEMAN
		  {
		  mptr->type = MOUSE_MOUSEMAN;
		  mptr->flags = CS7 | CREAD | CLOCAL | HUPCL;
		  }
		| HITACHI
		  {
		  mptr->type = MOUSE_HITACHI;
		  mptr->flags = CS8 | CREAD | CLOCAL | HUPCL;
		  }
		| BUSMOUSE
		  {
		  mptr->type = MOUSE_BUSMOUSE;
		  mptr->flags = 0;
		  }
		| STRING
		    { yyerror("unrecognized mouse flag '%s'", $1); free($1); }
		| error
		;

	/* keyboard */

keyboard_flags	: keyboard_flag
		| keyboard_flags keyboard_flag
		;
keyboard_flag	: LAYOUT KEYB_LAYOUT	{ keyb_layout($2); }
		| LAYOUT KEYB_LAYOUT {keyb_layout($2);} '{' keyboard_mods '}'
		| LAYOUT L_NO		{ keyb_layout(KEYB_NO); }
		| LAYOUT L_AUTO		{ keyb_layout(-1); }
		| RAWKEYBOARD bool	{ config.console_keyb = $2; }
		| STRING
		    { yyerror("unrecognized keyboard flag '%s'", $1);
		      free($1);}
		| error
		;

keyboard_mods	: keyboard_mod
		| keyboard_mods keyboard_mod
		;

keyboard_mod	: CTRL_MAP expression '=' { keyb_mod('C', $2, 0); } keyboard_modvals
		| SHIFT_ALT_MAP expression '=' { keyb_mod('a', $2, 0); } keyboard_modvals
		| CTRL_ALT_MAP expression '=' { keyb_mod('c', $2, 0); } keyboard_modvals
		| expression '=' { keyb_mod(' ', $1, 0); } keyboard_modvals
		| SHIFT_MAP expression '=' { keyb_mod('S', $2, 0); } keyboard_modvals
		| ALT_MAP expression '=' { keyb_mod('A', $2, 0); } keyboard_modvals
		| NUMPAD_MAP expression '=' { keyb_mod('N', $2, 0); } keyboard_modvals
		;

keyboard_modvals: keyboard_modval
		| keyboard_modvals ',' keyboard_modval
		;

keyboard_modval : UNICODE { keyb_mod(0, $1, 1); }
		| DGRAVE { keyb_mod(0, DKY_DEAD_GRAVE, 1); }
		| DACUTE { keyb_mod(0, DKY_DEAD_ACUTE, 1); }
		| DCIRCUM { keyb_mod(0, DKY_DEAD_CIRCUMFLEX, 1); }
		| DTILDE { keyb_mod(0, DKY_DEAD_TILDE, 1); }
		| DBREVE { keyb_mod(0, DKY_DEAD_BREVE, 1); }
		| DABOVED { keyb_mod(0, DKY_DEAD_ABOVEDOT, 1); }
		| DDIARES { keyb_mod(0, DKY_DEAD_DIAERESIS, 1); }
		| DABOVER { keyb_mod(0, DKY_DEAD_ABOVERING, 1); }
		| DDACUTE { keyb_mod(0, DKY_DEAD_DOUBLEACUTE, 1); }
		| DCEDILLA { keyb_mod(0, DKY_DEAD_CEDILLA, 1); }
		| DIOTA { keyb_mod(0, DKY_VOID, 1); } /* no dead iotas exist */
		| DOGONEK { keyb_mod(0,DKY_DEAD_OGONEK, 1); }
		| DCARON { keyb_mod(0, DKY_DEAD_CARON, 1); }
		| INTEGER { keyb_mod(0, $1, 0); }
		| '(' expression ')' { keyb_mod(0, $2, 0); }
		| string_unquoted {
			char *p = $1;
			while (*p) keyb_mod(0, *p++, 0);
			free($1);
		}
		;

	/* lock files */

ttylocks_flags	: ttylocks_flag
		| ttylocks_flags ttylocks_flag
		;
ttylocks_flag	: DIRECTORY string_expr	{ free(config.tty_lockdir); config.tty_lockdir = $2; }
		| NAMESTUB string_expr	{ free(config.tty_lockfile); config.tty_lockfile = $2; }
		| BINARY		{ config.tty_lockbinary = TRUE; }
		| STRING
		    { yyerror("unrecognized ttylocks flag '%s'", $1); free($1); }
		| error
		;

	/* serial ports */

serial_flags	: serial_flag
		| serial_flags serial_flag
		;
serial_flag	: DEVICE string_expr		{ free(sptr->dev); sptr->dev = $2; }
		| VIRTUAL		  {
					   if (isatty(0)) {
					     sptr->virt = TRUE;
					     sptr->pseudo = TRUE;
					     no_local_video = 1;
					     sptr->dev = strdup(ttyname(0));
					   } else {
					     error("FD 0 is not a tty, can't "
					           "use a virtual com port\n");
					     exit(1);
					   }
					  }
		| PSEUDO		  { sptr->pseudo = TRUE; }
		| VMODEM		  { sptr->vmodem = TRUE; }
		| RTSCTS		  { sptr->system_rtscts = TRUE; }
		| LOWLAT		  { sptr->low_latency = TRUE; }
		| PCCOM			  { sptr->custom = SER_CUSTOM_PCCOM; }
		| COM expression	  { sptr->real_comport = $2; }
		| BASE expression		{ sptr->base_port = $2; }
		| IRQ expression		{ sptr->irq = $2; }
		| MOUSE			{ sptr->mouse = 1; }
		| STRING
		    { yyerror("unrecognized serial flag '%s'", $1); free($1); }
		| error
		;

	/* printer */

printer_flags	: printer_flag
		| printer_flags printer_flag
		;
printer_flag	: LPT expression	{ c_printers = $2 - 1; }
		| COMMAND string_expr	{ pptr->prtcmd = $2; }
		| TIMEOUT expression	{ pptr->delay = $2; }
		| L_FILE string_expr		{ pptr->dev = $2; }
		| BASE expression		{ pptr->base_port = $2; }
		| STRING
		    { yyerror("unrecognized printer flag %s", $1); free($1); }
		| error
		;

	/* disks */

floppy_flags	: floppy_flag
		| floppy_flags floppy_flag
		;
floppy_flag	: READONLY              { dptr->wantrdonly = 1; }
		| THREEINCH	{ dptr->default_cmos = THREE_INCH_FLOPPY; }
		| THREEINCH_2880	{ dptr->default_cmos = THREE_INCH_2880KFLOP; }
		| THREEINCH_720	{ dptr->default_cmos = THREE_INCH_720KFLOP; }
		| FIVEINCH	{ dptr->default_cmos = FIVE_INCH_FLOPPY; }
		| FIVEINCH_360	{ dptr->default_cmos = FIVE_INCH_360KFLOP; }
		| L_FLOPPY string_expr
		  {
		  struct stat st;

		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a floppy-device given.");
		  if (stat($2, &st) < 0) {
		    yyerror("Could not stat floppy device.");
		  }
		  if (S_ISREG(st.st_mode)) {
		    dptr->type = IMAGE;
		  } else if (S_ISBLK(st.st_mode)) {
		    dptr->type = FLOPPY;
		  } else if (S_ISDIR(st.st_mode)) {
		    dptr->type = DIR_TYPE;
		  } else {
		    yyerror("Floppy device/file %s is wrong type", $2);
		  }
		  dptr->dev_name = $2;
		  dptr->floppy = 1;  // tell IMAGE and DIR we are a floppy
		  }
		| DEVICE string_expr
		  {
		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a disk-image file or device given.");
		  dptr->dev_name = $2;
		  }
		| DIRECTORY string_expr
		  {
		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a directory given.");
		  dptr->type = DIR_TYPE;
		  dptr->dev_name = $2;
		  }
		| STRING
		    { yyerror("unrecognized floppy disk flag '%s'\n", $1); free($1); }
		| error
		;

disk_flags	: disk_flag
		| disk_flags disk_flag
		;
disk_flag	: READONLY		{ dptr->wantrdonly = 1; }
		| DISKCYL4096	{ dptr->diskcyl4096 = 1; }
		| HDTYPE1	{ dptr->hdtype = 1; }
		| HDTYPE2	{ dptr->hdtype = 2; }
		| HDTYPE9	{ dptr->hdtype = 9; }
		| SECTORS expression	{ dptr->sectors = $2; }
		| CYLINDERS expression	{ dptr->tracks = $2; }
		| TRACKS expression	{ dptr->tracks = $2; }
		| HEADS expression		{ dptr->heads = $2; }
		| OFFSET expression	{ dptr->header = $2; }
		| DEVICE string_expr
		  {
		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a disk-image file or device given.");
		  dptr->dev_name = $2;
		  }
		| L_FILE string_expr
		  {
		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a disk-image file or device given.");
		  dptr->dev_name = $2;
		  }
		| HDIMAGE string_expr
		  {
		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a harddisk-image file given.");
		  set_hdimage(dptr, $2);
		  }
		| WHOLEDISK STRING
		  {
		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a harddisk given.");
		  dptr->type = HDISK;
		  dptr->dev_name = $2;
		  }
		| L_PARTITION string_expr INTEGER
		  {
                  yywarn("{ partition \"%s\" %d } the"
			 " token '%d' is ignored and can be removed.",
			 $2,$3,$3);
		  do_part($2);
		  }
		| L_PARTITION string_expr
		  { do_part($2); }
		| DIRECTORY string_expr
		  {
		  if (dptr->dev_name != NULL)
		    yyerror("Two names for a directory given.");
		  dptr->type = DIR_TYPE;
		  dptr->dev_name = $2;
		  }
		| STRING
		    { yyerror("unrecognized disk flag '%s'\n", $1); free($1); }
		| error
		;

	/* i/o ports */

port_flags	: port_flag
		| port_flags port_flag
		;
port_flag	: INTEGER
	           {
		   c_printf("CONF: I/O port 0x%04x\n", (unsigned short)$1);
	           allow_io($1, 1, ports_permission, ports_ormask,
	                    ports_andmask, portspeed, (char*)dev_name);
		   if (portspeed) portspeed += ((portspeed>0) ? 1 : -1);
	           }
		| '(' expression ')'
	           {
	           allow_io($2, 1, ports_permission, ports_ormask,
	                    ports_andmask, portspeed, (char*)dev_name);
		   if (portspeed) portspeed += ((portspeed>0) ? 1 : -1);
	           }
		| RANGE INTEGER INTEGER
		   {
		   if (portspeed > 1) portspeed = 0;
		   c_printf("CONF: range of I/O ports 0x%04x-0x%04x\n",
			    (unsigned short)$2, (unsigned short)$3);
		   allow_io($2, $3 - $2 + 1, ports_permission, ports_ormask,
			    ports_andmask, portspeed, (char*)dev_name);
		   portspeed=0;
		   strcpy(dev_name,"");
		   }
		| RANGE expression ',' expression
		   {
		   if (portspeed > 1) portspeed = 0;
		   c_printf("CONF: range of I/O ports 0x%04x-0x%04x\n",
			    (unsigned short)$2, (unsigned short)$4);
		   allow_io($2, $4 - $2 + 1, ports_permission, ports_ormask,
			    ports_andmask, portspeed, (char*)dev_name);
		   portspeed=0;
		   strcpy(dev_name,"");
		   }
		| RDONLY		{ ports_permission = IO_READ; }
		| WRONLY		{ ports_permission = IO_WRITE; }
		| RDWR			{ ports_permission = IO_RDWR; }
		| ORMASK expression	{ ports_ormask = $2; }
		| ANDMASK expression	{ ports_andmask = $2; }
                | FAST	                { portspeed = 1; }
                | SLOW	                { portspeed = -1; }
                | DEVICE string_expr         { strcpy(dev_name,$2); free($2); } 
		| STRING
		    { yyerror("unrecognized port command '%s'", $1);
		      free($1); }
		| error
		;

trace_port_flags	: trace_port_flag
		| trace_port_flags trace_port_flag
		;
trace_port_flag	: INTEGER 
			{ register_port_traceing($1, $1); }
		| '(' expression ')'
			{ register_port_traceing($2, $2); }
		| RANGE INTEGER INTEGER
			{ register_port_traceing($2, $3); }
		| RANGE expression ',' expression
			{ register_port_traceing($2, $4); }
		| CLEAR { clear_port_traceing(); }
		| STRING
		    { yyerror("unrecognized port trace command '%s'", $1);
		      free($1); }
		| error
		;

	/* IRQ definition for Silly Interrupt Generator */

sillyint_flags	: sillyint_flag
		| sillyint_flags sillyint_flag
		;
sillyint_flag	: INTEGER { set_irq_value(1, $1); }
		| '(' expression ')' { set_irq_value(1, $2); }
		| USE_SIGIO expression { set_irq_value(0x10001, $2); }
		| RANGE INTEGER INTEGER { set_irq_range(1, $2, $3); }
		| RANGE expression ',' expression { set_irq_range(1, $2, $4); }
		| USE_SIGIO RANGE INTEGER INTEGER { set_irq_range(0x10001, $3, $4); }
		| USE_SIGIO RANGE expression ',' expression { set_irq_range(0x10001, $3, $5); }
		| STRING
		    { yyerror("unrecognized irqpassing command '%s'", $1);
		      free($1); }
		| error
		;

	/* EMS definitions  */

ems_flags	: ems_flag
		| ems_flags ems_flag
		;
ems_flag	: INTEGER
	           {
		     config.ems_size = $1;
		     if ($1 > 0) c_printf("CONF: %dk bytes EMS memory\n", $1);
	           }
		| '(' expression ')'
	           {
		     config.ems_size = $2;
		     if ($2 > 0) c_printf("CONF: %dk bytes EMS memory\n", $2);
	           }
		| EMS_SIZE expression
		   {
		     config.ems_size = $2;
		     if ($2 > 0) c_printf("CONF: %dk bytes EMS memory\n", $2);
		   }
		| EMS_FRAME expression
		   {
/* is there a technical reason why the EMS frame can't be at 0xC0000 or
   0xA0000 if there's space? */
#if 0
		     if ( (($2 & 0xfc00)>=0xc800) && (($2 & 0xfc00)<=0xe000) ) {
		       config.ems_frame = $2 & 0xfc00;
		       c_printf("CONF: EMS-frame = 0x%04x\n", config.ems_frame);
		     }
		     else yyerror("wrong EMS-frame: 0x%04x", $2);
#endif
	             config.ems_frame = $2 & 0xfc00;
		     c_printf("CONF: EMS-frame = 0x%04x\n", config.ems_frame);
		   }
		| EMS_UMA_PAGES expression
		   {
		     config.ems_uma_pages = $2;
		   }
		| EMS_CONV_PAGES expression
		   {
		     config.ems_cnv_pages = $2;
		   }
		| STRING
		    { yyerror("unrecognized ems command '%s'", $1);
		      free($1); }
		| error
		;

	/* memory areas to spare for hardware (adapter) ram */

hardware_ram_flags : hardware_ram_flag
		| hardware_ram_flags hardware_ram_flag
		;
hardware_ram_flag : INTEGER
	           {
                     if (!register_hardware_ram('h', $1, PAGE_SIZE)) {
                       yyerror("wrong hardware ram address : 0x%08x", $1);
                     }
	           }
		| '(' expression ')'
	           {
                     if (!register_hardware_ram('h', $2, PAGE_SIZE)) {
                       yyerror("wrong hardware ram address : 0x%08x", $2);
                     }
	           }
		| RANGE INTEGER INTEGER
		   {
                     if (register_hardware_ram('h', $2, $3 - $2))
	               c_printf("CONF: hardware ram pages at 0x%08x-%08x\n", $2, $3);
                     else
                       yyerror("wrong hardware ram address : 0x%08x", $2);
		   }
		| RANGE expression ',' expression
		   {
                     if (register_hardware_ram('h', $2, $4 - $2))
	               c_printf("CONF: hardware ram pages at 0x%08x-%08x\n", $2, $4);
                     else
                       yyerror("wrong hardware ram address : 0x%08x", $2);
		   }
		| STRING
		    { yyerror("unrecognized hardware ram command '%s'", $1);
		      free($1); }
		| error
		;

	/* booleans */

bool:		expression
		;

floppy_bool:	expression
		;

int_bool:	expression 
		{
			if ($1 == -2) {
				yyerror("got 'on', expected 'off' or an integer");
			}
		}
		;

irq_bool:	expression {
			if ( $1 && (($1 < 2) || ($1 > 15)) ) {
				yyerror("got '%d', expected 'off' or an integer 2..15", $1);
			} 
		}
		;

	/* speaker values */

speaker		: L_OFF		{ $$ = SPKR_OFF; }
		| NATIVE	{ $$ = SPKR_NATIVE; }
		| EMULATED	{ $$ = SPKR_EMULATED; }
		| STRING        { yyerror("got '%s', expected 'emulated' or 'native'", $1);
				  free($1); }
		| error         { yyerror("expected 'emulated' or 'native'"); }
		;

	/* cpuemu value */

cpuemu		: L_OFF		{ $$ = 0; }
		| VM86		{ $$ = 3; }
		| FULL		{ $$ = 4; }
		| VM86SIM	{ $$ = 5; }
		| FULLSIM	{ $$ = 6; }
		| STRING        { yyerror("got '%s', expected 'off', 'vm86' or 'full'", $1);
				  free($1); }
		| error         { yyerror("expected 'off', 'vm86' or 'full'"); }
		;

cpu_vm		: L_AUTO	{ $$ = -1; }
		| VM86		{ $$ = CPUVM_VM86; }
		| KVM		{ $$ = CPUVM_KVM; }
		| EMULATED	{
#ifdef X86_EMULATOR
				 $$ = CPUVM_EMU;
#else
				 yyerror("CPU emulator not compiled in");
#endif
				}
		| STRING        { yyerror("got '%s' for cpu_vm", $1);
				  free($1); }
		| error         { yyerror("bad value for cpu_vm"); }
		;

cpu_vm_dpmi	: L_AUTO	{ $$ = -1; }
		| NATIVE	{ $$ = CPUVM_NATIVE; }
		| KVM		{ $$ = CPUVM_KVM; }
		| EMULATED	{ $$ = CPUVM_EMU; }
		| STRING        { yyerror("got '%s' for cpu_vm_dpmi", $1);
				  free($1); }
		| error         { yyerror("bad value for cpu_vm_dpmi"); }

charset_flags	: charset_flag
		| charset_flags charset_flag
		;

charset_flag	: INTERNAL STRING { set_internal_charset ($2); free($2); }
		| EXTERNAL STRING { set_external_charset ($2); free($2); }
		;

%%

	/* features */

static void handle_features(int which, int value)
{
  if ((which < 0)
	|| (which >= (sizeof(config.features) / sizeof(config.features[0])))) {
    c_printf("CONF: wrong feature number %d\n", which);
    return;
  }
  config.features[which] = value;
  c_printf("CONF: feature %d set to %d\n", which, value);
}

	/* joystick */

static void set_joy_device(char *devstring)
{
  char *spacepos;

  free(config.joy_device[0]);
  config.joy_device[0] = devstring;
  config.joy_device[1] = NULL;
  spacepos = strchr(devstring, ' ');
  if (spacepos != NULL) {
    *spacepos = '\0';
    config.joy_device[1] = spacepos + 1;
  }
}

	/* mouse */

static void start_mouse(void)
{
  mptr = &config.mouse;
  mptr->fd = -1;
  mptr->com = -1;
  mptr->has3buttons = 1;	// drivers can disable this
}

static void stop_mouse(void)
{
  char *p, *p1;
  if (mptr->dev && (p = strstr(mptr->dev, "com")) && strlen(p) > 3) {
    /* parse comX setting */
    mptr->com = atoi(p + 3);
    /* see if something else is specified and remove comX */
    if (p > mptr->dev) {
      p[-1] = 0;
    } else if ((p1 = strchr(p, ','))) {
      int l;
      p1++;
      l = strlen(p1);
      memmove(mptr->dev, p1, l + 1);
    } else {
      free(mptr->dev);
      mptr->dev = NULL;
    }
    c_printf("MOUSE: using COM%i\n", mptr->com);
  }
  c_printf("MOUSE: %s, type %x using internaldriver: %s, emulate3buttons: %s baudrate: %d\n", 
        mptr->dev && mptr->dev[0] ? mptr->dev : "no device specified",
        mptr->type, mptr->intdrv ? "yes" : "no", 
        mptr->emulate3buttons ? "yes" : "no", mptr->baudRate);
}

	/* debug */

static void start_ports(void)
{
  if (priv_lvl)
    yyerror("Can not change port privileges in user config file");
  ports_permission = IO_RDWR;
  ports_ormask = 0;
  ports_andmask = 0xFFFF;
}

	/* debug */

static void start_debug(void)
{
  set_debug_level('a', 0);	      /* Default is no debugging output at all */
}

	/* video */

static void start_video(void)
{
  free(config.vbios_file);
  config.vbios_file = NULL;
  config.vbios_copy = 0;
  config.vbios_seg  = 0xc000;
  config.vbios_size = 0x10000;
  config.console_video = 0;
  config.cardtype = CARD_NONE;
  config.chipset = PLAINVGA;
  config.mapped_bios = 0;
  config.vga = 0;
  config.gfxmemsize = 256;
  config.fullrestore = 0;
  config.dualmon = 0;
  config.force_vt_switch = 0;
}

static void stop_video(void)
{
  if (priv_lvl)
    config.console_video = 0;

  if ((config.cardtype != CARD_VGA) || !config.console_video) {
    config.vga = 0;
  }
}

	/* vesa modes */
static void set_vesamodes(int width, int height, int color_bits)
{
  vesamode_type *vmt = malloc(sizeof *vmt);
  if(vmt != NULL) {
    vmt->width = width;
    vmt->height = height;
    vmt->color_bits = color_bits;
    vmt->next = config.vesamode_list;
    config.vesamode_list = vmt;
  }
}

	/* vbios detection */
static int auto_vbios_seg = -1;
static int auto_vbios_size = -1;

static void detect_vbios(void)
{
  unsigned char c[0x21];
  int foffset;

  if (auto_vbios_seg != -1) return;
  if (!can_do_root_stuff || config.vbios_file) return;
  for (foffset = 0xc0000; foffset < 0xf0000; foffset += 0x800) {
    load_file("/dev/mem", foffset, c, sizeof(c));
    if (c[0]==0x55 && c[1]==0xaa
        && c[0x1e]=='I' && c[0x1f]=='B' && c[0x20]=='M') {
      auto_vbios_seg = foffset >> 4;
      auto_vbios_size = c[2]*0x200;
      break;
    }
  }
}

static int detect_vbios_seg(void)
{
  detect_vbios();
  return auto_vbios_seg;
}

static int detect_vbios_size(void)
{
  detect_vbios();
  return auto_vbios_size;
}

static void stop_ttylocks(void)
{
  c_printf("SER: directory %s namestub %s binary %s\n", config.tty_lockdir,
	   config.tty_lockfile,(config.tty_lockbinary?"Yes":"No"));
}

	/* serial */

static void start_serial(void)
{
  if (c_ser >= MAX_SER)
    sptr = &nullser;
  else {
    /* The defaults for interrupt, base_port, real_comport and dev are 
    ** automatically filled in inside the do_ser_init routine of serial.c
    */
    sptr = &com_cfg[c_ser];
    sptr->dev = NULL;
    sptr->irq = 0; 
    sptr->base_port = 0;
    sptr->end_port = 0;
    sptr->real_comport = 0;
    sptr->mouse = 0;
    sptr->virt = FALSE;
    sptr->pseudo = FALSE;
    sptr->system_rtscts = FALSE;
    sptr->low_latency = FALSE;
    sptr->dmx_port = 0;
    sptr->custom = SER_CUSTOM_NONE;
  }
}


static void stop_serial(void)
{
  if (c_ser >= MAX_SER) {
    c_printf("SER: too many ports, ignoring %s\n", sptr->dev);
    return;
  }
  c_printf("SER%d: %s", c_ser, sptr->dev ?: "none");
  if (sptr->base_port)
    c_printf(" port %x", sptr->base_port);
  if (sptr->irq)
    c_printf(" irq %x", sptr->irq);
  c_printf("\n");
  c_ser++;
  config.num_ser = c_ser;
}

	/* keyboard */

static int keyboard_statement_already = 0;

static void start_keyboard(void)
{
  config.layout = -1;
  config.console_keyb = 0;
  keyboard_statement_already = 1;
}

static void stop_terminal(void)
{
}

	/* printer */

static void start_printer(void)
{
  pptr->prtcmd = NULL;
  pptr->dev = NULL;
  pptr->remaining = -1;
  pptr->delay = 10;
}

static void stop_printer(void)
{
  printer_config(c_printers, pptr);
  c_printf("CONF(LPT%d) f: %s   c: %s  t: %d  port: %x\n",
           c_printers, pptr->dev, pptr->prtcmd,
           pptr->delay, pptr->base_port);
  c_printers++;
  if (c_printers > config.num_lpt)
    config.num_lpt = c_printers;
}

	/* disk */

static void start_floppy(void)
{
  if (c_fdisks >= MAX_FDISKS)
    {
    yyerror("There are too many floppy disks defined");
    dptr = &nulldisk;          /* Dummy-Entry to avoid core-dumps */
    }
  else
    dptr = &disktab[c_fdisks];

  dptr->sectors = 0;             /* setup default values */
  dptr->heads   = 0;
  dptr->tracks  = 0;
  dptr->type    = FLOPPY;
  dptr->default_cmos = THREE_INCH_FLOPPY;
  dptr->timeout = 0;
  dptr->dev_name = NULL;              /* default-values */
  dptr->wantrdonly = 0;
  dptr->header = 0;
}

static void dp_init(struct disk *dptr)
{
  dptr->type    =  NODISK;
  dptr->sectors = -1;
  dptr->heads   = -1;
  dptr->tracks  = -1;
  dptr->fdesc   = -1;
  dptr->hdtype = 0;
  dptr->timeout = 0;
  dptr->dev_name = NULL;              /* default-values */
  dptr->wantrdonly = 0;
  dptr->header = 0;
}

static void start_disk(void)
{
  if (c_hdisks >= MAX_HDISKS)
    {
    yyerror("There are too many hard disks defined");
    dptr = &nulldisk;          /* Dummy-Entry to avoid core-dumps */
    }
  else
    dptr = &hdisktab[c_hdisks];

  dp_init(dptr);
}

static void start_vnet(char *mode)
{
  if (strcmp(mode, "") == 0) {
    config.vnet = VNET_TYPE_AUTO;
    return;
  }
  if (strcmp(mode, "tap") == 0) {
    config.vnet = VNET_TYPE_TAP;
    return;
  }
  if (strcmp(mode, "vde") == 0) {
    config.vnet = VNET_TYPE_VDE;
    return;
  }
  IFCLASS(CL_NET) {}
  if (strcmp(mode, "eth") == 0)
    config.vnet = VNET_TYPE_ETH;
  else {
    error("Unknown vnet mode \"%s\"\n", mode);
    config.exitearly = 1;
  }
}

static void do_part(char *dev)
{
  if (dptr->dev_name != NULL)
    yyerror("Two names for a partition given.");
  dptr->type = PARTITION;
  dptr->dev_name = dev;
#ifdef __linux__
  dptr->part_info.number = atoi(dptr->dev_name+8);
#endif
  if (dptr->part_info.number == 0)
    yyerror("%s must be a PARTITION, can't find number suffix!\n",
	    dptr->dev_name);
}

static void stop_disk(int token)
{
#ifdef __linux__
  FILE   *f;
  struct mntent *mtab;
#endif
  int    mounted_rw;

  if (dptr == &nulldisk)              /* is there any disk? */
    return;                           /* no, nothing to do */

  if (!dptr->dev_name) {               /* Is there a file/device-name? */
    if (token == L_FLOPPY)
      error("floppy %c: no device/file-name given!\n", 'A'+c_fdisks);
    else
      error("drive %c: no device/file-name given!\n", 'C'+c_hdisks);
    return;
  } else {                               /* check the file/device for existance */
      struct stat st;

      if (stat(dptr->dev_name, &st) != 0) { /* Does this file exist? */
        yyerror("disk: device/file %s doesn't exist.", dptr->dev_name);
      }
    }

  if (dptr->type == NODISK)    /* Is it one of image, floppy, harddisk ? */
    yyerror("disk: no device/file-name given!"); /* No, error */
  else
    c_printf("CONF: disk type '%s'", disk_t_str(dptr->type));

  if (dptr->type == PARTITION) {
    c_printf(" partition# %d", dptr->part_info.number);
#ifdef __linux__
    mtab = NULL;
    if ((f = setmntent(MOUNTED, "r")) != NULL) {
      while ((mtab = getmntent(f)))
        if (!strcmp(dptr->dev_name, mtab->mnt_fsname)) break;
      endmntent(f);
    }
    if (mtab) {
      mounted_rw = ( hasmntopt(mtab, MNTOPT_RW) != NULL );
      if (mounted_rw && !dptr->wantrdonly) 
        yyerror("\n\nYou specified '%s' for read-write Direct Partition Access,"
                "\nit is currently mounted read-write on '%s' !!!\n",
                dptr->dev_name, mtab->mnt_dir);
      else if (mounted_rw) 
        yywarn("You specified '%s' for read-only Direct Partition Access,"
               "\n         it is currently mounted read-write on '%s'.\n",
               dptr->dev_name, mtab->mnt_dir);
      else if (!dptr->wantrdonly) 
        yywarn("You specified '%s' for read-write Direct Partition Access,"
               "\n         it is currently mounted read-only on '%s'.\n",
               dptr->dev_name, mtab->mnt_dir);
    }
#endif
  }

  if (dptr->type == IMAGE) {
    char buf[HEADER_SIZE];
    struct image_header *header = (struct image_header *)&buf;
    int fd;

    dptr->header = 0;

    fd = open(dptr->dev_name, O_RDONLY);
    if (fd != -1) {
      if (read(fd, &buf, sizeof buf) == HEADER_SIZE) {
        if (memcmp(header->sig, IMAGE_MAGIC, IMAGE_MAGIC_SIZE) == 0)
          dptr->header = header->header_end;
        c_printf(" header_size: %ld", (long)dptr->header);
      }
      close(fd);
    }
  }

  if (token == L_FLOPPY) {
    c_printf(" floppy %c:\n", 'A'+c_fdisks);
    disktab[c_fdisks].drive_num = c_fdisks;
    c_fdisks++;
  }
  else {
    c_printf(" drive %c:\n", 'C'+c_hdisks);
    hdisktab[c_hdisks].drive_num = (c_hdisks | 0x80);
    c_hdisks++;
  }
}

	/* keyboard */

void keyb_layout(int layout)
{
  struct keytable_entry *kt = keytable_list;
  config.layout = layout;
  if (layout == -1) {
    /* auto: do it later */
    config.keytable = NULL;
    return;
  }
  while (kt->name) {
    if (kt->keyboard == layout) {
      if (kt->flags & KT_ALTERNATE) {
        c_printf("CONF: Alternate keyboard-layout %s\n", kt->name);
        config.altkeytable = kt;
      } else {
      c_printf("CONF: Keyboard-layout %s\n", kt->name);
      config.keytable = kt;
      }
      return;
    }
    kt++;
  }
  c_printf("CONF: ERROR -- Keyboard has incorrect number!!!\n");
}

static void keytable_start(int layout)
{
  static struct keytable_entry *saved_kt = 0;
  if (layout == -1) {
    if (keyboard_statement_already) {
      if (config.keytable != saved_kt) {
        yywarn("keytable changed to %s table, but previously was defined %s\n",
                config.keytable->name, saved_kt->name);
      }
    }
  }
  else {
    saved_kt = config.keytable;
    keyb_layout(layout);
  }
}

static void keytable_stop(void)
{
  keytable_start(-1);
}

static void dump_keytables_to_file(char *name)
{
  FILE * f;
  struct keytable_entry *kt = keytable_list;

  f = fopen(name, "w");
  if (!f) {
    error("cannot create keytable file %s\n", name);
    exit(1);
  }
  
  while (kt->name) {
    dump_keytable(f, kt);
    kt++;
  }
  fclose(f);
  exit(0);
}

static void set_irq_value(int bits, int i1)
{
  if ((i1>2) && (i1<=15)) {
    config.sillyint |= (bits << i1);
    c_printf("CONF: IRQ %d for irqpassing", i1);
    if (bits & 0x10000)  c_printf(" uses SIGIO\n");
    else c_printf("\n");
  }
  else yyerror("wrong IRQ for irqpassing command: %d", i1);
}

static void set_irq_range(int bits, int i1, int i2) {
  int i;
  if ( (i1<3) || (i1>15) || (i2<3) || (i2>15) || (i1 > i2 ) ) {
    yyerror("wrong IRQ range for irqpassing command: %d .. %d", i1, i2);
  }
  else {
    for (i=i1; i<=i2; i++) config.sillyint |= (bits << i);
    c_printf("CONF: range of IRQs for irqpassing %d .. %d", i1, i2);
    if (bits & 0x10000)  c_printf(" uses SIGIO\n");
    else c_printf("\n");
  }
}


	/* errors & warnings */

void yywarn(const char *string, ...)
{
  va_list vars;
  va_start(vars, string);
  fprintf(stderr, "Warning: ");
  vfprintf(stderr, string, vars);
  fprintf(stderr, "\n");
  va_end(vars);
  warnings++;
}

void yyerror(const char *string, ...)
{
  va_list vars;
  va_start(vars, string);
  if (include_stack_ptr != 0 && !last_include) {
	  int i;
	  fprintf(stderr, "In file included from %s:%d\n",
		  include_fnames[0], include_lines[0]);
	  for(i = 1; i < include_stack_ptr; i++) {
		  fprintf(stderr, "                 from %s:%d\n",
			  include_fnames[i], include_lines[i]);
	  }
	  last_include = 1;
  }
  fprintf(stderr, "Error in %s: (line %.3d) ", 
	  include_fnames[include_stack_ptr], line_count);
  vfprintf(stderr, string, vars);
  fprintf(stderr, "\n");
  va_end(vars);
  errors++;
}


/*
 * open_file - opens the configuration-file named *filename and returns
 *             a file-pointer. The error/warning-counters are reset to zero.
 */

static FILE *open_file(const char *filename)
{
  errors   = 0;                  /* Reset error counter */
  warnings = 0;                  /* Reset counter for warnings */

  if (!filename) return 0;
  return fopen(filename, "r"); /* Open config-file */
}

/*
 * close_file - Close the configuration file and issue a message about
 *              errors/warnings that occured. If there were errors, the
 *              flag early-exit is that, so dosemu won't really.
 */

static void close_file(FILE * file)
{
  if (file) fclose(file);                  /* Close the config-file */

  if(errors)
    fprintf(stderr, "%d error(s) detected while parsing the configuration-file\n",
	    errors);
  if(warnings)
    fprintf(stderr, "%d warning(s) detected while parsing the configuration-file\n",
	    warnings);

  if (errors != 0)               /* Exit dosemu on errors */
    {
      config.exitearly = TRUE;
    }
}

/* write_to_syslog */
static void write_to_syslog(char *message)
{
  openlog("dosemu", LOG_PID, LOG_USER | LOG_NOTICE);
  syslog(LOG_PID | LOG_USER | LOG_NOTICE, "%s", message);
  closelog();
}

static void set_hdimage(struct disk *dptr, char *name)
{
  char *l = strstr(name, ".lnk");

  c_printf("Setting up hdimage %s\n", name);
  if (l && strlen(l) == 4) {
    const char *tmpl = "eval echo -n `cat %s`";
    char *cmd, path[1024], *rname;
    FILE *f;
    size_t ret;

    asprintf(&cmd, tmpl, name);
    free(name);
    f = popen(cmd, "r");
    free(cmd);
    ret = fread(path, 1, sizeof(path), f);
    pclose(f);
    if (ret == 0)
      return;
    path[ret] = '\0';
    c_printf("Link resolved to %s\n", path);
    rname = expand_path(path);
    if (access(rname, R_OK) != 0) {
      warn("hdimage: %s does not exist\n", rname);
      free(rname);
      return;
    }
    dptr->dev_name = rname;
    dptr->type = DIR_TYPE;
    c_printf("Set up as a directory\n");
    return;
  }
  dptr->type = IMAGE;
  dptr->dev_name = name;
  c_printf("Set up as an image\n");
}

static int add_drive(const char *name, int num)
{
  struct disk *dptr = &hdisktab[c_hdisks];
  char *rname = expand_path(name);
  if (access(rname, R_OK) != 0) {
    free(rname);
    return -1;
  }
  dp_init(dptr);
  dptr->dev_name = rname;
  dptr->type = DIR_TYPE;
  dptr->drive_num = (num | 0x80);
  c_printf("Added drive %i (%x): %s\n", c_hdisks, dptr->drive_num, name);
  c_hdisks++;
  return 0;
}

static void set_drive_c(void)
{
  int err;

  c_printf("Setting up drive C, %s\n", dosemu_drive_c_path);
  if (!config.alt_drv_c && !exists_dir(dosemu_drive_c_path)) {
    char *system_str;
    c_printf("Creating default drive C\n");
    err = asprintf(&system_str, "mkdir -p %s/tmp", dosemu_drive_c_path);
    assert(err != -1);
    err = system(system_str);
    free(system_str);
    if (err) {
      error("unable to create %s\n", dosemu_drive_c_path);
      return;
    }
  }
  if (c_hdisks) {
    error("wrong mapping of Group 0 to %c\n", 'C' + c_hdisks);
    dosemu_drive_c_path = DRIVE_C_DEFAULT;
  }
  err = add_drive(dosemu_drive_c_path, c_hdisks);
  assert(!err);
}

static void set_default_drives(void)
{
  int num = c_hdisks;
#define AD(p) \
    if (p) \
      add_drive(p, num); \
    num++
  c_printf("Setting up default drives from %c\n", 'C' + num);
  AD(commands_path);
  AD(fddir_boot);
  AD(fddir_default);
}

static FILE *open_dosemu_users(void)
{
  FILE *fp;
  fp = open_file(DOSEMU_USERS_FILE);
  if (fp) return fp;
  return 0;
}

static void setup_home_directories(void)
{
  setenv("DOSEMU_IMAGE_DIR", dosemu_image_dir_path, 1);
  LOCALDIR = get_dosemu_local_home();
  RUNDIR = mkdir_under(LOCALDIR, "run");
  DOSEMU_MIDI_PATH = assemble_path(RUNDIR, DOSEMU_MIDI);
  DOSEMU_MIDI_IN_PATH = assemble_path(RUNDIR, DOSEMU_MIDI_IN);
}

static void lax_user_checking(void)
{
  const char *p;

  define_config_variable("c_all");
  p = getenv("USER");
  if (!p)
    p = "guest";
  setenv("DOSEMU_USER", p, 1);
  setenv("DOSEMU_REAL_USER", p, 1);
  setup_home_directories();
}

/* Parse TimeMode, Paul Crawford and Andrew Brooks 2004-08-01 */
/* Accepts "bios", "pit", "linux", default is "bios". Use with TIMEMODE token */
int parse_timemode(const char *timemodestr)
{
   if (timemodestr == NULL || timemodestr[0] == '\0')
     return(TM_BIOS); /* default */
   if (strcmp(timemodestr, "linux")==0)
     return(TM_LINUX);
   if (strcmp(timemodestr, "pit")==0)
     return(TM_PIT);
   if (strcmp(timemodestr, "bios")==0)
     return(TM_BIOS);
   yyerror("Unrecognised time mode (not bios, pit or linux)");
   return(TM_BIOS);
}

/* Parse Users for DOSEMU, by Alan Hourihane, alanh@fairlite.demon.co.uk */
/* Jan-17-1996: Erik Mouw (J.A.K.Mouw@et.tudelft.nl)
 *  - added logging facilities
 * In 1998:     Hans
 *  - havy changes and re-arangments
 */
void
parse_dosemu_users(void)
{
#define ALL_USERS "all"
#define PBUFLEN 256

  FILE *volatile fp;
  struct passwd *pwd;
  char buf[PBUFLEN];
  int userok = 0;
  char *ustr;
  int uid;
  int have_vars=0;

  /* We come here _very_ early (at top of main()) to avoid security conflicts.
   * priv_init() has already been called, but nothing more.
   *
   * We will exit, if /etc/dosemu.users says that the user has no right
   * to run a suid root dosemu (and we are on), but will continue, if the user
   * is running a non-suid copy _and_ is mentioned in dosemu users.
   * The dosemu.users entry for such a user is:
   *
   *      joeodd  ... nosuidroot
   *
   * The functions we call rely on the following setting:
   */
  after_secure_check = 0;
  priv_lvl = 0;

  setenv("DOSEMU_CONF_DIR", DOSEMU_CONF_DIR, 1);
  /* we check for some vital global settings
   * which we need before proceeding
   */

  fp = open_dosemu_users();
  if (fp) while (fgets(buf, PBUFLEN, fp) != NULL) {
    int l = strlen(buf);
    if (l && (buf[l-1] == '\n')) buf[l-1] = 0;
    ustr = strtok(buf, " \t\n=,;:");
    if (ustr && (ustr[0] != '#')) {
      if (!strcmp(ustr, "default_lib_dir")) {
        ustr=strtok(0, " \t\n=,;:");
        if (ustr) {
          if (!exists_dir(ustr)) {
            const char *tx = "default_lib_dir %s does not exist\n";
            fprintf(stderr, tx, ustr);
            fprintf(stdout, tx, ustr);
            exit(1);
          }
          ustr = strdup(ustr);
          replace_string(CFG_STORE, dosemu_lib_dir_path, ustr);
          dosemu_lib_dir_path = ustr;
        }
      }
      if (!strcmp(ustr, "default_hdimage_dir")) {
        ustr=strtok(0, " \t\n=,;:");
        if (ustr) {
          if (!exists_dir(ustr)) {
            const char *tx = "default_hdimage_dir %s does not exist\n";
            fprintf(stderr, tx, ustr);
            fprintf(stdout, tx, ustr);
            exit(1);
          }
          ustr = strdup(ustr);
          replace_string(CFG_STORE, dosemu_image_dir_path, ustr);
          dosemu_image_dir_path = ustr;
        }
      }
      else if (!strcmp(ustr, "log_level")) {
        int ll = 0;
        ustr=strtok(0, " \t\n=,;:");
        if (ustr) {
          ll = atoi(ustr);
          if (ll < 0) ll = 0;
          if (ll > 2) ll = 2;
        }
      }
      else if (!strcmp(ustr, "config_script")) {
        ustr=strtok(0, " \t\n=,;:");
        if (ustr && strcmp(ustr, DEFAULT_CONFIG_SCRIPT)) {
          config_script_path = strdup(ustr);
          if (!exists_file(config_script_path)) {
            const char *tx = "config_script %s does not exist\n";
            fprintf(stderr, tx, ustr);
            fprintf(stdout, tx, ustr);
            exit(1);
          }
	  config_script_name = strdup(ustr);
	}
      }
    }
  }
  if (fp) fclose(fp);

  if (!can_do_root_stuff || under_root_login) {
     /* simply ignore -- we're not suid-root */
     lax_user_checking();
     after_secure_check = 1;
     return;
  }

  /* We want to test if the _user_ is allowed to do certain privileged    */
  /* things, o check if the username connected to the get_orig_uid() is   */
  /* in the DOSEMU_USERS_FILE file (usually /etc/dosemu.users).           */
   
  uid = get_orig_uid();

  errno = 0; /* man says this is necessary?! */
  pwd = getpwuid(uid);

  /* Sanity Check, Shouldn't be anyone logged in without a userid */
  if (!pwd) 
     {
       error("Illegal User: uid=%i, error=%s\n", uid, strerror(errno));
       sprintf(buf, "Illegal DOSEMU user: uid=%i", uid);
       write_to_syslog(buf);
       exit(1);
     }

  /* preset DOSEMU_*USER env, such that a user can't fake it */
  setenv("DOSEMU_USER", "unknown", 1);
  setenv("DOSEMU_REAL_USER", pwd->pw_name, 1);

  {
       fp = open_dosemu_users();
       if (fp) {
	   for(userok=0; fgets(buf, PBUFLEN, fp) != NULL && !userok; ) {
	     int l = strlen(buf);
	     if (l && (buf[l-1] == '\n')) buf[l-1] = 0;
	     ustr = strtok(buf, " \t\n,;:");
	     if (ustr && (ustr[0] != '#')) {
	       if (strcmp(ustr, pwd->pw_name)== 0) 
		 userok = 1;
	       else if (strcmp(ustr, ALL_USERS)== 0)
		 userok = 1;
	       if (userok) {
		 setenv("DOSEMU_USER", ustr, 1);
		 while ((ustr=strtok(0, " \t,;:")) !=0) {
		   if (ustr[0] == '#') break;
		   define_config_variable(ustr);
		   have_vars = 1;
		 }
	         if (!have_vars && !using_sudo)
		   define_config_variable("restricted");
	       }
	     }
	   }
           fclose(fp);
       }
  }

  define_config_variable("c_all");
  if(userok==0 && !using_sudo) {
    define_config_variable("restricted");
  }
  if (get_config_variable("nosuidroot") || (get_config_variable("restricted") && !on_console())) {
    fprintf(stderr, "Dropping root privileges: guest or a restricted user not on console.\n");
    priv_drop();
    lax_user_checking();
    after_secure_check = 1;
    return;
  }

  /* now we setup up our local DOSEMU home directory, where we
   * have (among other things) all temporary stuff in
   * (since 0.97.10.2)
   */
  setup_home_directories();
  after_secure_check = 1;
}


char *commandline_statements;

static void do_parse(FILE *fp, const char *confname, const char *errtx)
{
  yyin = fp;
  line_count = 1;
  include_stack_ptr = 0;
  c_printf("CONF: Parsing %s file.\n", confname);
  file_being_parsed = strdup(confname);
  include_fnames[include_stack_ptr] = file_being_parsed;
  yyrestart(fp);
  if (yyparse())
    yyerror(errtx, confname);
  close_file(fp);
  include_stack_ptr = 0;
  include_fnames[include_stack_ptr] = 0;
  free(file_being_parsed);
}

int parse_config(const char *confname, const char *dosrcname)
{
  FILE *fd;
  int is_user_config;
#if YYDEBUG != 0
  yydebug  = 1;
#endif

  define_config_variable(PARSER_VERSION_STRING);

  /* Let's try confname if not null, and fail if not found */
  /* Else try the user's own .dosrc (old) or .dosemurc (new) */
  /* If that doesn't exist we will default to CONFIG_FILE */

  {
    if (!dosrcname) {
      char *name;
      name = assemble_path(dosemu_localdir_path, DOSEMU_RC);
      if (access(name, R_OK) == -1) {
        free(name);
        name = get_path_in_HOME(DOSEMU_RC);
      }
      if (access(name, R_OK) == 0)
        setenv("DOSEMU_RC", name, 1);
      free(name);
    }
    else {
      setenv("DOSEMU_RC",dosrcname,1);
    }

    /* privileged options allowed? */
    is_user_config = (confname && config_script_path && strcmp(confname, config_script_path));
    priv_lvl = !under_root_login && can_do_root_stuff && is_user_config;

    if (is_user_config) define_config_variable("c_user");
    else define_config_variable("c_system");

    yy_vbuffer = dosemu_conf;
    do_parse(NULL, "built-in dosemu.conf", "error in built-in dosemu.conf");
    yy_vbuffer = global_conf;
    do_parse(NULL, "built-in global.conf", "error in built-in global.conf");
    if (confname) {
      yy_vbuffer = NULL;
      fd = open_file(confname);
      if (!fd) {
        fprintf(stderr, "Cannot open base config file %s, Aborting DOSEMU.\n",confname);
        exit(1);
      }
      do_parse(fd, confname, "error in configuration file %s");
    }

    if (priv_lvl) undefine_config_variable("c_user");
    else undefine_config_variable("c_system");

    if (!get_config_variable(CONFNAME_V3USED)) {
	/* we obviously have an old configuration file
         * ( or a too simple one )
	 * giving up
	 */
	yyerror("\nYour %s script or configuration file is obviously\n"
		"an old style or a too simple one\n"
		"Please read README.txt on how to upgrade\n", confname);
	exit(1);
    }

    /* privileged options allowed for user's config? */
    priv_lvl = !under_root_login && can_do_root_stuff;
    if (priv_lvl) define_config_variable("c_user");

    /* Now we parse any commandline statements from option '-I'
     * We do this under priv_lvl set above, so we have the same secure level
     * as with .dosrc
     */

    if (commandline_statements) {
      #define XX_NAME "commandline"

      open_file(0);
      define_config_variable("c_comline");
      c_printf("Parsing " XX_NAME  " statements.\n");
      yyin=0;				 /* say: we have no input file */
      yy_vbuffer=commandline_statements; /* this is the input to scan */
      do_parse(0, XX_NAME, "error in user's %s statement");
      undefine_config_variable("c_comline");
    }
  }

#ifdef TESTING
  error("TESTING: parser is terminating program\n");
  exit(0);
#endif
  return 1;
}

#define MAX_CONFIGVARIABLES 128
char *config_variables[MAX_CONFIGVARIABLES+1] = {0};
static int config_variables_count = 0;
static int config_variables_last = 0;
static int allowed_classes = -1;
static int saved_allowed_classes = -1;



static int is_in_allowed_classes(int mask)
{
  if (!(allowed_classes & mask)) {
    yyerror("insufficient class privilege to use this configuration option\n");
    exit(99);
  }
  return 1;
}

struct config_classes {
	const char *cls;
	int mask;
} config_classes[] = {
	{"c_all", CL_ALL},
	{"c_normal", CL_ALL & (~(CL_VAR | CL_VPORT | CL_IRQ | CL_HARDRAM | CL_PCI | CL_NET))},
	{"c_var", CL_VAR},
	{"c_system", CL_ALL},
	{"c_vport", CL_VPORT},
	{"c_port", CL_PORT},
	{"c_irq", CL_IRQ},
	{"c_pci", CL_PCI},
	{"c_hardram", CL_HARDRAM},
	{"c_net", CL_NET},
	{0,0}
};

static int get_class_mask(char *name)
{
  struct config_classes *p = &config_classes[0];
  while (p->cls) {
    if (!strcmp(p->cls,name)) return p->mask;
    p++;
  }
  return 0;
}

static void update_class_mask(void)
{
  int i, m;
  allowed_classes = 0;
  for (i=0; i< config_variables_count; i++) {
    if ((m=get_class_mask(config_variables[i])) != 0) {
      allowed_classes |= m;
    }
  }
}

static void enter_user_scope(int incstackptr)
{
  if (user_scope_level) return;
  saved_priv_lvl = priv_lvl;
  priv_lvl = 1;
  saved_allowed_classes = allowed_classes;
  allowed_classes = 0;
  user_scope_level = incstackptr;
  c_printf("CONF: entered user scope, includelevel %d\n", incstackptr-1);
}

static void leave_user_scope(int incstackptr)
{
  if (user_scope_level != incstackptr) return;
  priv_lvl = saved_priv_lvl;
  allowed_classes = saved_allowed_classes;
  user_scope_level = 0;
  c_printf("CONF: left user scope, includelevel %d\n", incstackptr-1);
}

char *get_config_variable(const char *name)
{
  int i;
  for (i=0; i< config_variables_count; i++) {
    if (!strcmp(name, config_variables[i])) {
      config_variables_last = i;
      return config_variables[i];
    }
  }
  return 0;
}

int define_config_variable(const char *name)
{
  if (priv_lvl) {
    if (strcmp(name, CONFNAME_V3USED) && strncmp(name, "u_", 2)) {
      c_printf("CONF: not enough privilege to define config variable %s\n", name);
      return 0;
    }
  }
  if (!get_config_variable(name)) {
    if (config_variables_count < MAX_CONFIGVARIABLES) {
      config_variables[config_variables_count++] = strdup(name);
      if (!priv_lvl) update_class_mask();
    }
    else {
      if (after_secure_check)
        c_printf("CONF: overflow on config variable list\n");
      return 0;
    }
  }
  if (after_secure_check)
    c_printf("CONF: config variable %s set\n", name);
  return 1;
}

static int undefine_config_variable(const char *name)
{
  if (priv_lvl) {
    if (strncmp(name, "u_", 2)) {
      c_printf("CONF: not enough privilege to undefine config variable %s\n", name);
      return 0;
    }
  }
  if (get_config_variable(name)) {
    int i;
    if (!strcmp(name, CONFNAME_V3USED)) parser_version_3_style_used = 0;
    free(config_variables[config_variables_last]);
    for (i=config_variables_last; i<(config_variables_count-1); i++) {
      config_variables[i] = config_variables[i+1];
    }
    config_variables_count--;
    if (!priv_lvl) update_class_mask();
    c_printf("CONF: config variable %s unset\n", name);
    return 1;
  }
  return 0;
}

char *checked_getenv(const char *name)
{
  if (user_scope_level) {
     char *s, *name_ = malloc(strlen(name)+sizeof(USERVAR_PREF));
     strcpy(name_, USERVAR_PREF);
     strcat(name_, name);
     s = getenv(name_);
     free(name_);
     if (s) return s;
  }
  return getenv(name);
}

static void check_user_var(char *name)
{
	char *name_;
	char *s;

	if (user_scope_level) return;
	name_ = malloc(strlen(name)+sizeof(USERVAR_PREF));
	strcpy(name_, USERVAR_PREF);
	strcat(name_, name);
	s = getenv(name_);
	if (s) {
		if (getenv(name))
			c_printf("CONF: variable %s replaced by user\n", name);
		setenv(name, s, 1);
		unsetenv(name_);
	}
	free(name_);
}


static char *run_shell(char *command)
{
	int pipefds[2];
	pid_t pid;
	char excode[16] = "1";

	setenv("DOSEMU_SHELL_RETURN", excode, 1);
	if (pipe(pipefds)) return strdup("");
	pid = fork();
	if (pid == -1) return strdup("");
	if (!pid) {
		/* child */
		int ret;
		close(pipefds[0]);	/* we won't read from the pipe */
		dup2(pipefds[1], 1);	/* make the pipe child's stdout */
		priv_drop();	/* drop any priviledges */
		ret = system(command);
			/* tell the parent: "we have finished",
			 * this way we need not to play games with select()
			 */
		if (ret == -1) ret = errno;
		else ret >>=8;
		write(pipefds[1],"\0\0\0",4);
		close(pipefds[1]);
		_exit(ret);
	}
	else {
		/* parent */
		char *buf = 0;
		int recsize = 128;
		int bufsize = 0;
		int ptr =0;
		int ret;
		int status;

		close(pipefds[1]);	/* we won't write to the pipe */
		do {
			bufsize = ptr + recsize;
			if (!buf) buf = malloc(bufsize);
			else buf = realloc(buf, bufsize);
			ret = read(pipefds[0], buf+ptr, recsize -1);
			if (ret > 0) {
				ptr += ret;
			}
		} while (ret >0 && (ret < 4 || memcmp(buf+ptr-4,"\0\0\0",4)));
		close(pipefds[0]);
		waitpid(pid, &status, 0);
		buf[ptr] = 0;
		if (!buf[0]) {
			free(buf);
			buf = strdup("");
		}
		sprintf(excode, "%d", WEXITSTATUS(status));
		setenv("DOSEMU_SHELL_RETURN", excode, 1);
		return buf;
	}
}


struct for_each_entry {
	char *list;
	char *ptr;
	int skip_restart;
};

#define FOR_EACH_DEPTH	16
static struct for_each_entry *for_each_list = 0;

static int for_each_handling(int loopid, char *varname, char *delim, char *list)
{
	struct for_each_entry *fe;
	char * _new;
	char saved;
	if (!for_each_list) {
		int size = FOR_EACH_DEPTH * sizeof(struct for_each_entry);
		for_each_list = malloc(size);
		memset(for_each_list, 0, size);
	}
	if (loopid > FOR_EACH_DEPTH) {
		yyerror("too deeply nested foreach\n");
		return 0;
	}
	fe = for_each_list + loopid;
	if (!fe->list) {
		/* starting the loop */
		fe->ptr = fe->list = strdup(list);
		fe->skip_restart = 0;
		if (loopid) {
			/* in inner loops we need to skip the restart */
			fe->skip_restart = 1;
		}
	}
	else {
		if (fe->skip_restart) {
			fe->skip_restart = 0;
			return 1;
		}
	}
	while (fe->ptr[0] && strchr(delim,fe->ptr[0])) fe->ptr++;
	/* subsequent call */
	if (!fe->ptr[0]) {
		/* loop end */
		free(fe->list);
		fe->list = 0;
		return (0);
	}
	_new = strpbrk(fe->ptr, delim);
	if (!_new) _new = strchr(fe->ptr,0);
	saved = *_new;
	*_new = 0;
	setenv(varname,fe->ptr,1);
	if (saved) _new++;
	fe->ptr = _new;
	return (1);
}

#ifdef TESTING_MAIN

static void die(char *reason)
{
  error("par dead: %s\n", reason);
  exit(0);
}

int
main(int argc, char **argv)
{
  if (argc != 2)
    die("no filename!");

  if (!parse_config(argv[1], argv[2] /* will be NULL if not given */))
    die("parse failed!\n");
}

#endif

/* for keyboard plugin */



static void keyb_mod(int wich, t_keysym keynum, int unicode)
{
	static t_keysym *table = 0;
	static int count = 0;

	if (wich == ' ') {
		switch (keynum & 0xFF00) {
		case 0x000: wich = ' '; break;
		case 0x100: wich = 'S'; break;
		case 0x200: wich = 'A'; break;
		case 0x300: wich = 'N'; break;
		case 0x400: wich = 'C'; break;
		case 0x500: wich = 'a'; break;
		case 0x600: wich = 'c'; break;
		default: 
			/* It's a bad value ditch it */
			wich ='X'; table = 0; count = 0; break;
		}
		keynum &= 0xFF;
	}

	switch (wich) {
	case ' ': table = config.keytable->key_map;
		count=config.keytable->sizemap;
		break;
	case 'S': table = config.keytable->shift_map;
		count=config.keytable->sizemap;
		break;
	case 'A': table = config.keytable->alt_map;
		count=config.keytable->sizemap;
		break;
	case 'C': table = config.keytable->ctrl_map;
		count=config.keytable->sizemap;
		break;
	case 'a': table = config.keytable->shift_alt_map;
		count=config.keytable->sizemap;
		break;
	case 'c': table = config.keytable->ctrl_alt_map;
		count=config.keytable->sizemap;
		break;
	case 'N': table = config.keytable->num_table;
		count=config.keytable->sizepad;
		break;
	}


	if (!table || (count == 0) || (wich != 0 && keynum >= count)) {
		count = 0;
		table = 0;
		return;
	}
	if (wich != 0) {
		table += keynum;
		count -= keynum;
		return;
	}
	if (!unicode) {
		if (keynum == 0) {
			keynum = DKY_VOID;
		} else {
			keynum = keynum + 0xEF00;
		}
	}
	if (count > 0) {
		*table++ = keynum;
		count--;
	}
}


static const char *get_key_name(t_keysym key)
{
	struct key_names {
		t_keysym key;
		const char *name;
	};
	static struct key_names names[] =
	{
		{ DKY_DEAD_GRAVE,	"dgrave"},
		{ DKY_DEAD_ACUTE,	"dacute"},
		{ DKY_DEAD_CIRCUMFLEX,	"dcircum"},
		{ DKY_DEAD_TILDE,	"dtilde"},
		{ DKY_DEAD_BREVE,	"dbreve"},
		{ DKY_DEAD_ABOVEDOT,	"daboved"},
		{ DKY_DEAD_DIAERESIS,	"ddiares"},
		{ DKY_DEAD_ABOVERING,	"dabover"},
		{ DKY_DEAD_DOUBLEACUTE,	"ddacute"},
		{ DKY_DEAD_CEDILLA,	"dcedilla"},
		{ DKY_DEAD_OGONEK,	"dogonek"},
		{ DKY_DEAD_CARON,	"dcaron"},
	};
	int i;
	for(i = 0; i < sizeof(names)/sizeof(names[0]); i++) {
		if (names[i].key == key) {
			return names[i].name;
		}
	}
	return 0;
}

static void dump_keytable_part(FILE *f, t_keysym *map, int size)
{
  int i, in_string=0;
  t_keysym c;
  const char *cc; 
  char comma=' ', buf[16];

  /* Note: This code assumes every font is a superset of ascii */
  if (!map) {
	  return;
  }
  size--;
  for (i=0; i<=size; i++) {
    c = map[i];
    if (!(i & 15)) fprintf(f,"    ");
    cc = get_key_name(c);
    if (!cc && (c < 128) && isprint(c) && !strchr("\\\"\'`", c)) {
      if (in_string) fputc(c,f);
      else {
        fprintf(f, "%c\"%c", comma, c);
        in_string = 1;
      }
    }
    else {
      if (!cc) {
	if (((c > 0) && (c < 128)) || ((c >= 0xEF00) && (c <= 0xEFFF))) {
	  sprintf(buf, "%d", c & 0xFF);
	} else if (c == DKY_VOID) {
	  strcpy(buf, "0");
	} else {
	  sprintf(buf, "\\u%04x", c);
	}
	cc = buf;
      }
      if (!in_string) fprintf(f, "%c%s", comma, cc);
      else {
        fprintf(f, "\",%s", cc);
        in_string = 0;
      }
    }
    if ((i & 15) == 15) {
      if (in_string) fputc('"', f);
      if (i < size) fputc(',', f);
      fputc('\n', f);
      in_string = 0;
      comma = ' ';
    }
    else comma = ',';
  }
  if (in_string) fputc('"', f);
  fputc('\n', f);
}


void dump_keytable(FILE *f, struct keytable_entry *kt)
{
    fprintf(f, "keytable %s {\n", kt->name);
    fprintf(f, "  0=\n");
    dump_keytable_part(f, kt->key_map, kt->sizemap);
    fprintf(f, "  shift 0=\n");
    dump_keytable_part(f, kt->shift_map, kt->sizemap);
    fprintf(f, "  alt 0=\n");
    dump_keytable_part(f, kt->alt_map, kt->sizemap);
    fprintf(f, "  numpad 0=\n");
    dump_keytable_part(f, kt->num_table, kt->sizepad-1);
    fprintf(f, "  ctrl 0=\n");
    dump_keytable_part(f, kt->ctrl_map, kt->sizemap);
    fprintf(f, "  shift-alt 0=\n");
    dump_keytable_part(f, kt->shift_alt_map, kt->sizemap);
    fprintf(f, "  ctrl-alt 0=\n");
    dump_keytable_part(f, kt->ctrl_alt_map, kt->sizemap);
    fprintf(f, "}\n\n\n");
}



	/* charset */
static struct char_set *get_charset(char *name)
{
	struct char_set *charset;

	charset = lookup_charset(name);
	if (!charset) {
		yyerror("Can't find charset %s", name);
	}
	return charset;

}

static void set_external_charset(char *charset_name)
{
	struct char_set *charset;
	charset = get_charset(charset_name);
	charset = get_terminal_charset(charset);
	if (charset) {
		if (!trconfig.output_charset) {
			trconfig.output_charset = charset;
		}
		if (!trconfig.keyb_charset) {
			trconfig.keyb_charset = charset;
		}
	}
	return;
}

static void set_internal_charset(char *charset_name)
{
	struct char_set *charset_video, *charset_config;
	charset_video = get_charset(charset_name);
	if (!is_display_charset(charset_video)) {
		yyerror("%s not suitable as an internal charset", charset_name);
	}
	charset_config = get_terminal_charset(charset_video);
	if (charset_video && !trconfig.video_mem_charset) {
		trconfig.video_mem_charset = charset_video;
	}
#if 0
	if (charset_config && !trconfig.keyb_config_charset) {
		trconfig.keyb_config_charset = charset_config;
	}
#endif
	if (charset_config && !trconfig.dos_charset) {
		trconfig.dos_charset = charset_config;
	}
	return;
}

