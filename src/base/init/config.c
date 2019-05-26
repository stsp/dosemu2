#include <stdio.h>
#include <termios.h>
#include <unistd.h>
#include <stdlib.h>
#include <ctype.h>
#include <string.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/utsname.h>

#include "version.h"
#include "emu.h"
#include "timers.h"
#include "video.h"
#include "vc.h"
#include "mouse.h"
#include "serial.h"
#include "keyboard/keymaps.h"
#include "memory.h"
#include "bios.h"
#include "lpt.h"
#include "int.h"
#include "dosemu_config.h"
#include "init.h"
#include "disks.h"
#include "pktdrvr.h"
#include "speaker.h"
#include "sound/sound.h"
#include "keyboard/keyb_clients.h"
#include "dos2linux.h"
#include "utilities.h"
#ifdef X86_EMULATOR
#include "cpu-emu.h"
#endif
#include "mhpdbg.h"
#include "mapping.h"

/*
 * Options used in config_init().
 *
 * Please keep "getopt_string", secure_option_preparse(), config_init(),
 * usage() and the manpage in sync!
 *
 * No more undocumented switches *please*.
 *
 * "--Fusers", "--Flibdir", "--Fimagedir" and "-n" not in "getopt_string"
 * they are eaten by secure_option_preparse().
 */


int config_check_only = 0;

int dosemu_argc;
char **dosemu_argv;
char *dosemu_proc_self_exe = NULL;
int dosemu_proc_self_maps_fd = -1;

static void     check_for_env_autoexec_or_config(void);
static void     usage(char *basename);

const char *config_script_name = DEFAULT_CONFIG_SCRIPT;
const char *config_script_path = 0;
const char *dosemu_users_file_path = "/etc/" DOSEMU_USERS;
const char *dosemu_loglevel_file_path = "/etc/" DOSEMU_LOGLEVEL;
const char *dosemu_rundir_path = "~/" LOCALDIR_BASE_NAME "/run";
const char *dosemu_localdir_path = "~/" LOCALDIR_BASE_NAME;

const char *dosemu_lib_dir_path = DOSEMULIB_DEFAULT;
const char *dosemu_image_dir_path = DOSEMUIMAGE_DEFAULT;
const char *dosemu_drive_c_path = DRIVE_C_DEFAULT;
char keymaploadbase_default[] = DOSEMULIB_DEFAULT "/";
char *keymap_load_base_path = keymaploadbase_default;
const char *keymap_dir_path = "keymap/";
const char *owner_tty_locks = "uucp";
const char *tty_locks_dir_path = "/var/lock";
const char *tty_locks_name_path = "LCK..";
const char *dosemu_midi_path = "~/" LOCALDIR_BASE_NAME "/run/" DOSEMU_MIDI;
const char *dosemu_midi_in_path = "~/" LOCALDIR_BASE_NAME "/run/" DOSEMU_MIDI_IN;
char *dosemu_map_file_name;
char *fddir_default;
char *fddir_boot;
char *commands_path;
struct config_info config;

#define STRING_STORE_SIZE 10
struct cfg_string_store {
    struct string_store base;
    char *strings[STRING_STORE_SIZE];
} cfg_store = { { .num = STRING_STORE_SIZE } };

/*
 * DANG_BEGIN_FUNCTION cpu_override
 *
 * description:
 * Process user CPU override from the config file ('cpu xxx') or
 * from the command line. Returns the selected CPU identifier or
 * -1 on error.
 *
 * DANG_END_FUNCTION
 *
 */
int cpu_override (int cpu)
{
    switch (cpu) {
	case 2:
	    return CPU_286;
	case 5: case 6:
	    return CPU_586;
	/* fall thru */
	case 4:
	    return CPU_486;
	/* fall thru */
	case 3:
	    return CPU_386;
    }
    return -1;
}

static void dump_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vfprintf(stderr, fmt, args);
    va_end(args);
}

static void log_dump_printf(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vlog_printf(-1, fmt, args);
    va_end(args);
}

void dump_config_status(void (*printfunc)(const char *, ...))
{
    const char *s;
    void (*print)(const char *, ...) = (printfunc ? printfunc : dump_printf);

    if (!printfunc) {
      (*print)("\n-------------------------------------------------------------\n");
      (*print)("------dumping the runtime configuration _after_ parsing -----\n");
    }
    else (*print)("dumping the current runtime configuration:\n");
    (*print)("Version: dosemu-" VERSTR " versioncode = 0x%08x\n\n", DOSEMU_VERSION_CODE);
    (*print)("Running Kernel Version: linux-%d.%d.%d\n", kernel_version_code >> 16, (kernel_version_code >> 8) & 255, kernel_version_code & 255);
    (*print)("cpu ");
    switch (vm86s.cpu_type) {
      case CPU_386: s = "386"; break;
      case CPU_486: s = "486"; break;
      case CPU_586: s = "586"; break;
      default:  s = "386"; break;
    }
    (*print)("%s\nrealcpu ", s);
    switch (config.realcpu) {
      case CPU_386: s = "386"; break;
      case CPU_486: s = "486"; break;
      case CPU_586: s = "586"; break;
      default:  s = "386"; break;
    }
    (*print)("%s\n", s);
    (*print)("CPUclock %g MHz\ncpu_spd 0x%lx\ncpu_tick_spd 0x%lx\n",
	(((double)LLF_US)/config.cpu_spd), config.cpu_spd, config.cpu_tick_spd);

    (*print)("pci %d\nrdtsc %d\nmathco %d\nsmp %d\n",
                 config.pci, config.rdtsc, config.mathco, config.smp);
    (*print)("cpuspeed %d\n", config.CPUSpeedInMhz);
#ifdef X86_EMULATOR
    (*print)("cpuemu %d\n", config.cpuemu);
#endif

    if (config_check_only) mapping_init();
    (*print)("mappingdriver %s\n", config.mappingdriver ? config.mappingdriver : "auto");
    if (config_check_only) mapping_close();
    (*print)("hdiskboot %d\n",
        config.hdiskboot);
    (*print)("mem_size %d\next_mem %d\n",
	config.mem_size, config.ext_mem);
    (*print)("ems_size 0x%x\nems_frame 0x%x\n",
        config.ems_size, config.ems_frame);
    (*print)("umb_a0 %i\numb_b0 %i\numb_f0 %i\ndpmi 0x%x\ndpmi_lin_rsv_base 0x%x\ndpmi_lin_rsv_size 0x%x\npm_dos_api %i\nignore_djgpp_null_derefs %i\n",
        config.umb_a0, config.umb_b0, config.umb_f0, config.dpmi, config.dpmi_lin_rsv_base, config.dpmi_lin_rsv_size, config.pm_dos_api, config.no_null_checks);
    (*print)("mapped_bios %d\nvbios_file %s\n",
        config.mapped_bios, (config.vbios_file ? config.vbios_file :""));
    (*print)("vbios_copy %d\nvbios_seg 0x%x\nvbios_size 0x%x\n",
        config.vbios_copy, config.vbios_seg, config.vbios_size);
    (*print)("console_keyb %d\nconsole_video %d\n",
        config.console_keyb, config.console_video);
    (*print)("kbd_tty %d\nexitearly %d\n",
        config.kbd_tty, config.exitearly);
    (*print)("fdisks %d\nhdisks %d\n",
        config.fdisks, config.hdisks);
    (*print)("term_esc_char 0x%x\nterm_color %d\n",
        config.term_esc_char, config.term_color);
    (*print)("xterm_title\n", config.xterm_title);
    (*print)("X_display \"%s\"\nX_title \"%s\"\nX_icon_name \"%s\"\n",
        (config.X_display ? config.X_display :""), config.X_title, config.X_icon_name);
    (*print)("X_title_show_appname %d\n",
	config.X_title_show_appname);
    (*print)("X_blinkrate %d\nX_sharecmap %d\nX_mitshm %d\n",
        config.X_blinkrate, config.X_sharecmap, config.X_mitshm);
    (*print)("X_fixed_aspect %d\nX_aspect_43 %d\nX_lin_filt %d\n",
        config.X_fixed_aspect, config.X_aspect_43, config.X_lin_filt);
    (*print)("X_bilin_filt %d\nX_mode13fact %d\nX_winsize_x %d\n",
        config.X_bilin_filt, config.X_mode13fact, config.X_winsize_x);
    (*print)("X_winsize_y %d\nX_gamma %d\nX_fullscreen %d\nvgaemu_memsize 0x%x\n",
        config.X_winsize_y, config.X_gamma, config.X_fullscreen,
	     config.vgaemu_memsize);
    (*print)("SDL_hwrend %d\nSDL_font \"%s\"\n",
        config.sdl_hwrend, config.sdl_font);
    (*print)("vesamode_list %p\nX_lfb %d\nX_pm_interface %d\n",
        config.vesamode_list, config.X_lfb, config.X_pm_interface);
    (*print)("X_font \"%s\"\n", config.X_font);
    (*print)("X_mgrab_key \"%s\"\n",  config.X_mgrab_key);
    (*print)("X_background_pause %d\n", config.X_background_pause);

    switch (config.chipset) {
      case PLAINVGA: s = "plainvga"; break;
#ifdef USE_SVGALIB
      case SVGALIB: s = "svgalib"; break;
#endif
      case VESA: s = "vesa"; break;
      default: s = "unknown"; break;
    }
    (*print)("config.X %d\nhogthreshold %d\nchipset \"%s\"\n",
        config.X, config.hogthreshold, s);
    switch (config.cardtype) {
      case CARD_VGA: s = "VGA"; break;
      case CARD_MDA: s = "MGA"; break;
      case CARD_CGA: s = "CGA"; break;
      case CARD_EGA: s = "EGA"; break;
      default: s = "unknown"; break;
    }
    (*print)("cardtype \"%s\"\npci_video %d\nfullrestore %d\n",
        s, config.pci_video, config.fullrestore);
    (*print)("gfxmemsize %d\nvga %d\n",
        config.gfxmemsize, config.vga);
    switch (config.speaker) {
      case SPKR_OFF: s = "off"; break;
      case SPKR_NATIVE: s = "native"; break;
      case SPKR_EMULATED: s = "emulated"; break;
      default: s = "wrong"; break;
    }
    (*print)("dualmon %d\nforce_vt_switch %d\nspeaker \"%s\"\n",
        config.dualmon, config.force_vt_switch, s);
    (*print)("update %d\nfreq %d\n",
        config.update, config.freq);
    (*print)("tty_lockdir \"%s\"\ntty_lockfile \"%s\"\nconfig.tty_lockbinary %d\n",
        config.tty_lockdir, config.tty_lockfile, config.tty_lockbinary);
    (*print)("num_ser %d\nnum_lpt %d\nfastfloppy %d\nfull_file_locks %d\n",
        config.num_ser, config.num_lpt, config.fastfloppy, config.full_file_locks);
    (*print)("emusys \"%s\"\n",
        (config.emusys ? config.emusys : ""));
    (*print)("dosbanner %d\nvbios_post %d\ndetach %d\n",
        config.dosbanner, config.vbios_post, config.detach);
    (*print)("debugout \"%s\"\n",
        (config.debugout ? config.debugout : ""));
    {
	char buf[256];
	GetDebugFlagsHelper(buf, 0);
	(*print)("debug_flags \"%s\"\n", buf);
    }
    if (!printfunc && config.keytable) {
        dump_keytable(stderr, config.keytable);
    } else {
        (*print) ("keytable not setup yet\n");
    }
    (*print)("pre_stroke \"%s\"\n", (config.pre_stroke ? config.pre_stroke : ""));
    (*print)("irqpassing= ");
    if (config.sillyint) {
      int i;
      for (i=0; i <16; i++) {
        if (config.sillyint & (1<<i)) {
          (*print)("IRQ%d", i);
          if (config.sillyint & (0x10000<<i))
            (*print)("(sigio) ");
          else
            (*print)(" ");
        }
      }
      (*print)("\n");
    }
    else (*print)("none\n");
    list_hardware_ram(print);
    (*print)("ipxsup %d\nvnet %d\npktflags 0x%x\n",
	config.ipxsup, config.vnet, config.pktflags);

    {
        int i;
	for (i = 0; i < config.num_lpt; i++)
          printer_print_config(i, print);
    }

    {
	int i;
	int size = sizeof(config.features) / sizeof(config.features[0]);
	for (i = 0; i < size; i++) {
	  (*print)("feature_%d %d\n", i, config.features[i]);
	}
    }

    (*print)("\nSOUND:\nengine %d\nsb_base 0x%x\nsb_dma %d\nsb_hdma %d\nsb_irq %d\n"
	"mpu401_base 0x%x\nmpu401_irq %i\nsound_driver \"%s\"\n",
        config.sound, config.sb_base, config.sb_dma, config.sb_hdma, config.sb_irq,
	config.mpu401_base, config.mpu401_irq, config.sound_driver);
    (*print)("pcm_hpf %i\nmidi_file %s\nwav_file %s\n",
	config.pcm_hpf, config.midi_file, config.wav_file);
    (*print)("\ncli_timeout %d\n", config.cli_timeout);
    (*print)("\nJOYSTICK:\njoy_device0 \"%s\"\njoy_device1 \"%s\"\njoy_dos_min %i\njoy_dos_max %i\njoy_granularity %i\njoy_latency %i\n",
        config.joy_device[0], config.joy_device[1], config.joy_dos_min, config.joy_dos_max, config.joy_granularity, config.joy_latency);
    (*print)("\nFS:\nset_int_hooks %i\nforce_int_revect %i\nforce_fs_redirect %i\n\n",
        config.int_hooks, config.force_revect, config.force_redir);

    if (!printfunc) {
      (*print)("\n--------------end of runtime configuration dump -------------\n");
      (*print)(  "-------------------------------------------------------------\n\n");
    }
}

static void
open_terminal_pipe(char *path)
{
    terminal_fd = DOS_SYSCALL(open(path, O_RDWR));
    if (terminal_fd == -1) {
	terminal_pipe = 0;
	error("open_terminal_pipe failed - cannot open %s!\n", path);
	return;
    } else
	terminal_pipe = 1;
}

static void our_envs_init(void)
{
    struct utsname unames;
    char *s;
    char buf[256];

    strcpy(buf, on_console() ? "1" : "0");
    setenv("DOSEMU_STDIN_IS_CONSOLE", buf, 1);
    uname(&unames);
    kernel_version_code = strtol(unames.release, &s,0) << 16;
    kernel_version_code += strtol(s+1, &s,0) << 8;
    kernel_version_code += strtol(s+1, &s,0);
    sprintf(buf, "%d", kernel_version_code);
    setenv("KERNEL_VERSION_CODE", buf, 1);
    sprintf(buf, "%d", DOSEMU_VERSION_CODE);
    setenv("DOSEMU_VERSION_CODE", buf, 1);
    setenv("DOSEMU_VERSION", VERSTR, 1);
    sprintf(buf, "%d", geteuid());
    setenv("DOSEMU_EUID", buf, 1);
    sprintf(buf, "%d", getuid());
    setenv("DOSEMU_UID", buf, 1);
}

static int check_comcom(const char *dir)
{
  char *path;
  int err;

  path = assemble_path(dir, "command.com");
  err = access(path, R_OK);
  free(path);
  if (err == 0)
    return 1;
  path = assemble_path(dir, "comcom32.exe");
  err = access(path, R_OK);
  free(path);
  if (err == 0)
    error("comcom32 found in %s but command.com symlink is missing\n", dir);
  return 0;
}

static void comcom_hook(struct sys_dsc *sfiles, fatfs_t *fat)
{
  char buf[1024];
  char *comcom;
  ssize_t res;
  const char *dir = fatfs_get_host_dir(fat);

  if (strcmp(dir, fddir_default) == 0) {
    sfiles[CMD_IDX].flags |= FLG_COMCOM32;
    return;
  }
  comcom = assemble_path(dir, "command.com");
  res = readlink(comcom, buf, sizeof(buf));
  free(comcom);
  if (res == -1)
    return;
  if (strncmp(buf, fddir_default, strlen(fddir_default)) != 0)
    return;
  sfiles[CMD_IDX].flags |= FLG_COMCOM32;
}

static void set_freedos_dir(void)
{
  char *fddir;
#ifdef USE_FDPP
  if (load_plugin("fdpp"))
    c_printf("fdpp: plugin loaded\n");
  else
    error("can't load fdpp\n");
#endif

  if (!fddir_boot)
    fddir_boot = assemble_path(dosemu_lib_dir_path, FDBOOT_DIR);
  if (access(fddir_boot, R_OK | X_OK) == 0) {
    setenv("FDBOOT_DIR", fddir_boot, 1);
    setenv("DOSEMU2_DRIVE_E", fddir_boot, 1);
  } else {
    error("No system files found at %s\n", fddir_boot);
    free(fddir_boot);
    fddir_boot = NULL;
  }

  fddir = getenv("DOSEMU2_FREEDOS_DIR");
  if (fddir)
    fddir = strdup(fddir);
  else
    fddir = assemble_path(dosemu_lib_dir_path, FREEDOS_DIR);
  if (access(fddir, R_OK | X_OK) == 0 && check_comcom(fddir)) {
    fddir_default = fddir;
    setenv("FREEDOS_DIR", fddir, 1);    // compat, unneeded
  } else {
    const char *comcom[] = {
      "/usr/share/comcom32",
      "/usr/local/share/comcom32",
      NULL,
    };
    int i;
    free(fddir);
    for (i = 0; comcom[i]; i++) {
      if (access(comcom[i], R_OK | X_OK) == 0 && check_comcom(comcom[i])) {
        fddir_default = strdup(comcom[i]);
        fatfs_set_sys_hook(comcom_hook);
        break;
      }
    }
  }
  if (!fddir_default) {
    error("Neither FreeDOS nor comcom32 installation found.\n"
        "Use DOSEMU2_FREEDOS_DIR env var to specify alternative location.\n");
  } else {
    setenv("DOSEMU2_DRIVE_F", fddir_default, 1);
  }
}

static void move_dosemu_lib_dir(void)
{
  char *old_cmd_path;

  setenv("DOSEMU2_DRIVE_C", dosemu_drive_c_path, 1);
  setenv("DOSEMU_LIB_DIR", dosemu_lib_dir_path, 1);
  set_freedos_dir();
  commands_path = assemble_path(dosemu_lib_dir_path, CMDS_SUFF);
  if (access(commands_path, R_OK | X_OK) == 0) {
    setenv("DOSEMU2_DRIVE_D", commands_path, 1);
  } else {
    error("dosemu2 commands not found at %s\n", commands_path);
    free(commands_path);
    commands_path = NULL;
  }
  old_cmd_path = assemble_path(dosemu_lib_dir_path, "dosemu2-cmds-0.1");
  if (access(old_cmd_path, R_OK | X_OK) == 0)
    setenv("DOSEMU_COMMANDS_DIR", old_cmd_path, 1);
  else if (commands_path)
    setenv("DOSEMU_COMMANDS_DIR", commands_path, 1);
  free(old_cmd_path);

  if (keymap_load_base_path != keymaploadbase_default)
    free(keymap_load_base_path);
  keymap_load_base_path = assemble_path(dosemu_lib_dir_path, "");
}

static int find_option(const char *option, int argc, char **argv)
{
  int i;
  if (argc <=1 ) return 0;
  for (i=1; i < argc; i++) {
    if (!strcmp(argv[i], option)) {
      return i;
    }
  }
  return 0;
}

static int option_delete(int option, int *argc, char **argv)
{
  int i;
  if (option >= *argc) return 0;
  for (i=option; i < *argc; i++) {
    argv[i] = argv[i+1];
  }
  *argc -= 1;
  return option;
}

/*
 * Please keep "getopt_string", secure_option_preparse(), config_init(),
 * usage() and the manpage in sync!
 */
static char * get_option(const char *key, int with_arg, int *argc,
    char **argv)
{
  char *p;
  char *basename;
  int o = find_option(key, *argc, argv);
  if (!o) return 0;
  o = option_delete(o, argc, argv);
  if (!with_arg) return NULL;
  if (!with_arg || o >= *argc) return NULL;
  if (argv[o][0] == '-') {
    basename = strrchr(argv[0], '/');   /* parse the program name */
    basename = basename ? basename + 1 : argv[0];
    usage(basename);
    exit(0);
  }
  p = strdup(argv[o]);
  option_delete(o, argc, argv);
  return p;
}

void secure_option_preparse(int *argc, char **argv)
{
  char *opt;
  int runningsuid = can_do_root_stuff && !under_root_login;

  if (runningsuid) unsetenv("DOSEMU_LAX_CHECKING");
  else setenv("DOSEMU_LAX_CHECKING", "on", 1);

  if (*argc <=1 ) return;

  opt = get_option("--Fusers", 1, argc, argv);
  if (opt && opt[0]) {
    if (runningsuid) {
      fprintf(stderr, "Bypassing /etc/dosemu.users not allowed %s\n",
	      using_sudo ? "with sudo" : "for suid-root");
      exit(0);
    }
    DOSEMU_USERS_FILE = opt;
  }

  opt = get_option("--Flibdir", 1, argc, argv);
  if (opt && opt[0]) {
    char *opt1 = realpath(opt, NULL);
    if (opt1) {
      replace_string(CFG_STORE, dosemu_lib_dir_path, opt1);
      dosemu_lib_dir_path = opt1;
    } else {
      error("--Flibdir: %s does not exist\n", opt);
    }
    free(opt);
  }

  opt = get_option("--Fimagedir", 1, argc, argv);
  if (opt && opt[0]) {
    char *opt1 = realpath(opt, NULL);
    if (opt1) {
      replace_string(CFG_STORE, dosemu_image_dir_path, opt1);
      dosemu_image_dir_path = opt1;
      config.alt_drv_c = 1;
    } else {
      error("--Fimagedir: %s does not exist\n", opt);
    }
    free(opt);
  }

  opt = get_option("--Fdrive_c", 1, argc, argv);
  if (opt && opt[0]) {
    char *opt1 = realpath(opt, NULL);
    if (opt1) {
      replace_string(CFG_STORE, dosemu_drive_c_path, opt1);
      dosemu_drive_c_path = opt1;
    } else {
      error("--Fdrive_c: %s does not exist\n", opt);
    }
    free(opt);
  }

  /* "-Xn" is enough to throw this parser off :( */
  opt = get_option("-n", 0, argc, argv);
  if (opt) {
    if (runningsuid) {
      fprintf(stderr, "The -n option to bypass the system configuration files "
	      "is not allowed with sudo/suid-root\n");
      exit(0);
    }
    DOSEMU_USERS_FILE = NULL;
  }
}

static void read_cpu_info(void)
{
    char *cpuflags, *cpu;
    int k = 3;

    open_proc_scan("/proc/cpuinfo");
    cpu = get_proc_string_by_key("cpu family");
    if (cpu) {
      k = atoi(cpu);
    } else { /* old kernels < 2.1.74 */
      cpu = get_proc_string_by_key("cpu");
      /* 386, 486, etc */
      if (cpu) k = atoi(cpu) / 100;
    }
    if (k > 5) k = 5;
    switch (k) {
      case 5:
        config.realcpu = CPU_586;
        cpuflags = get_proc_string_by_key("features");
        if (!cpuflags) {
          cpuflags = get_proc_string_by_key("flags");
        }
#ifdef X86_EMULATOR
        if (cpuflags && (strstr(cpuflags, "mmxext") ||
			 strstr(cpuflags, "sse"))) {
	  config.cpuprefetcht0 = 1;
        }
#endif
#ifdef __i386__
        if (cpuflags && (strstr(cpuflags, "fxsr")) &&
	    sizeof(*vm86_fpu_state) == (112+512)) {
          config.cpufxsr = 1;
	  if (cpuflags && strstr(cpuflags, "sse"))
	    config.cpusse = 1;
	}
#endif
        if (cpuflags && strstr(cpuflags, "tsc")) {
          /* bogospeed currently returns 0; should it deny
           * pentium features, fall back into 486 case */
	  if ((cpuflags = get_proc_string_by_key("cpu MHz"))) {
	    int di,df;
	    /* last known proc/cpuinfo format is xxx.xxxxxx, with 3
	     * int and 6 decimal digits - but what if there are less
	     * or more digits??? */
	    /* some broken kernel/cpu combinations apparently imply
	     * the existence of 0 Mhz CPUs */
	    if (sscanf(cpuflags,"%d.%d",&di,&df)==2 && (di || df)) {
		char cdd[8]; int i;
		long long chz = 0;
		char *p = cpuflags;
		while (*p!='.') p++;
		p++;
		for (i=0; i<6; i++) cdd[i]=(*p && isdigit(*p)? *p++:'0');
		cdd[6]=0; sscanf(cdd,"%d",&df);
		/* speed division factor to get 1us from CPU clocks - for
		 * details on fast division see timers.h */
		chz = (di * 1000000LL) + df;

		/* speed division factor to get 1us from CPU clock */
		config.cpu_spd = (LLF_US*1000000)/chz;

		/* speed division factor to get 838ns from CPU clock */
		config.cpu_tick_spd = (LLF_TICKS*1000000)/chz;

		warn ("Linux kernel %d.%d.%d; CPU speed is %lld Hz\n",
		   kernel_version_code >> 16, (kernel_version_code >> 8) & 255,
		   kernel_version_code & 255,chz);
/*		fprintf (stderr,"CPU speed factors %ld,%ld\n",
			config.cpu_spd, config.cpu_tick_spd); */
		config.CPUSpeedInMhz = di + (df>500000);
#ifdef X86_EMULATOR
		warn ("CPU-EMU speed is %d MHz\n",config.CPUSpeedInMhz);
#endif
		break;
	    }
	    else
	      cpuflags=NULL;
	  }
	  else
	    cpuflags=0;
	  if (!cpuflags) {
            if (!bogospeed(&config.cpu_spd, &config.cpu_tick_spd)) {
              break;
            }
          }
        }
        /* fall thru */
      case 4: config.realcpu = CPU_486;
        /* fall thru */
      case 3:
      	break;
      default:
        error("Unknown CPU type!\n");
	/* config.realcpu is set to CPU_386 at this point */
    }
    config.mathco = strcmp(get_proc_string_by_key("fpu"), "yes") == 0;
    reset_proc_bufferptr();
    k = 0;
    while (get_proc_string_by_key("processor")) {
      k++;
      advance_proc_bufferptr();
    }
    if (k > 1) {
      config.smp = 1;		/* for checking overrides, later */
    }
    close_proc_scan();
}

static void config_post_process(void)
{
    config.realcpu = CPU_386;
    if (vm86s.cpu_type > config.realcpu || config.rdtsc || config.mathco)
	read_cpu_info();
    if (vm86s.cpu_type > config.realcpu) {
	vm86s.cpu_type = config.realcpu;
	fprintf(stderr, "CONF: emulated CPU forced down to real CPU: %d86\n",(int)vm86s.cpu_type);
    }
#ifdef X86_EMULATOR
    if (config.cpu_vm != CPUVM_EMU) {
      config.cpuemu = 0;
    } else if (config.cpuemu == 0) {
	config.cpuemu = 3;
	c_printf("CONF: JIT CPUEMU set to 3 for %d86\n", (int)vm86s.cpu_type);
    }
    if (config.cpu_vm_dpmi != CPUVM_EMU) {
      if (config.cpuemu > 3 && config.cpu_vm_dpmi != -1) config.cpuemu = 3;
    } else if (config.cpuemu < 4) {
	config.cpuemu = 4;
	c_printf("CONF: JIT CPUEMU set to 4 for %d86\n", (int)vm86s.cpu_type);
    }
#endif
    if (config.rdtsc) {
	if (config.smp) {
		c_printf("CONF: Denying use of pentium timer on SMP machine\n");
		config.rdtsc = 0;
	}
	if (config.realcpu < CPU_586) {
		c_printf("CONF: Ignoring 'rdtsc' statement\n");
		config.rdtsc = 0;
	}
    }
    /* console scrub */
    if (!Video && getenv("DISPLAY") && !config.X && !config.term &&
        config.cardtype != CARD_NONE) {
	config.console_video = 0;
	config.emuretrace = 0;	/* already emulated */
#ifdef SDL_SUPPORT
	if (config.X_font && config.X_font[0])
#endif
	{
#ifdef X_SUPPORT
	    config.X = 1;
#endif
#ifdef SDL_SUPPORT
	} else {
	    config.sdl = 1;
	    config.sdl_sound = 1;
#endif
	}
    }
#ifdef USE_CONSOLE_PLUGIN
    if (on_console()) {
	c_printf("CONF: running on console, vga=%i cv=%i\n", config.vga,
	        config.console_video);
	if (!can_do_root_stuff && config.console_video) {
	    /* force use of Slang-terminal on console too */
	    config.console_video = 0;
	    dbug_printf("no console on low feature (non-suid root) DOSEMU\n");
	}
	if (config.console_keyb == -1)
	    config.console_keyb = KEYB_RAW;
	if (config.speaker == SPKR_EMULATED) {
	    register_speaker((void *)(uintptr_t)console_fd,
			     console_speaker_on, console_speaker_off);
	}
    } else
#endif
    {
	c_printf("CONF: not running on console\n");
	if (config.console_keyb == -1) {
	    config.console_keyb =
#ifdef USE_SLANG
		    /* Slang will take over KEYB_OTHER */
		    KEYB_OTHER
#else
		    KEYB_TTY
#endif
	    ;
	}
	config.console_video = 0;
	if (config.speaker == SPKR_NATIVE) {
	    config.speaker = SPKR_EMULATED;
	}
    }
    if (!config.console_video)
	config.vga = config.mapped_bios = 0;
    if (config.vga)
	config.mapped_bios = config.console_video = 1;
    else
	config.vbios_post = 0;
    if ((config.vga || config.X) && config.mem_size > 640) {
	error("$_dosmem = (%d) not allowed for X and VGA console graphics, "
              "restricting to 640K\n", config.mem_size);
        config.mem_size = 640;
    }
    if (config.umb_a0 == -1) {
	config.umb_a0 = config.term;
#if 0
	if (config.umb_a0) {
	    warn("work around FreeDOS UMB bug\n");
	    config.umb_a0++;
	}
#endif
    }
    if (!config.dpmi || !config.ems_size || config.ems_uma_pages < 4) {
	warn("CONF: disabling DPMI DOS support\n");
	config.pm_dos_api = 0;
    }

    /* page-align memory sizes */
    config.ext_mem &= ~3;
    config.xms_size &= ~3;
    config.ems_size &= ~3;
    config.dpmi &= ~3;

    /* UID scrub */
    if (under_root_login)  c_printf("CONF: running exclusively as ROOT:");
    else {
      c_printf("CONF: mostly running as USER:");
    }
    c_printf(" uid=%d (cached %d) gid=%d (cached %d)\n",
        geteuid(), get_cur_euid(), getegid(), get_cur_egid());
    c_printf("CONF: priv operations %s\n",
            can_do_root_stuff ? "available" : "unavailable");

    /* Speaker scrub */
#ifdef X86_EMULATOR
    if (config.cpuemu && config.speaker==SPKR_NATIVE) {
	c_printf("SPEAKER: can`t use native mode with cpu-emu\n");
	config.speaker=SPKR_EMULATED;
    }
#endif

    check_for_env_autoexec_or_config();

    if (config.pci && !can_do_root_stuff) {
        c_printf("CONF: Warning: PCI requires root, disabled\n");
        config.pci = 0;
    }
}

static config_scrub_t config_scrub_func[100];

/*
 * DANG_BEGIN_FUNCTION register_config_scrub
 *
 * description:
 * register a function Enforce consistency upon the `config` structure after
 * all values have been set to remove silly option combinations
 *
 * DANG_END_FUNCTION
 *
 */
int register_config_scrub(config_scrub_t new_config_scrub)
{
	int i;
	int result = -1;
	for(i = 0; i < sizeof(config_scrub_func)/sizeof(config_scrub_func[0]); i++) {
		if (!config_scrub_func[i]) {
			config_scrub_func[i] = new_config_scrub;
			result = 0;
			break;
		}
	}
	if (result < 0) {
		c_printf("register_config_scrub failed > %zu config_scrub functions\n",
			sizeof(config_scrub_func)/sizeof(config_scrub_func[0]));
	}
	return result;
}

/*
 * DANG_BEGIN_FUNCTION unregister_config_scrub
 *
 * description:
 * Complement of register_config_scrub
 * This removes a scrub function.
 *
 * DANG_END_FUNCTION
 *
 */
void unregister_config_scrub( config_scrub_t old_config_scrub)
{
	int i;
	for(i = 0; i < sizeof(config_scrub_func)/sizeof(config_scrub_func[0]); i++) {
		if (config_scrub_func[i] == old_config_scrub) {
			config_scrub_func[i] = 0;
		}
	}
}

/*
 * DANG_BEGIN_FUNCTION config_scrub
 *
 * description:
 * Enforce consistency upon the `config` structure after
 * all values have been set to remove silly option combinations
 *
 * DANG_END_FUNCTION
 *
 */
static void config_scrub(void)
{
	int i;
	for(i = 0; i < sizeof(config_scrub_func)/sizeof(config_scrub_func[0]); i++) {
		config_scrub_t func = config_scrub_func[i];
		if (func) {
			func();
		}
	}
}

/*
 * DANG_BEGIN_FUNCTION config_init
 *
 * description:
 * This is called to parse the command-line arguments and config
 * files.
 *
 * DANG_END_FUNCTION
 *
 */
void
config_init(int argc, char **argv)
{
    int             c=0;
#define I_MAX 5
    int             i_incr[I_MAX] = {};
    int             i_found = 0;
    int             i_cur;
    int             can_do_root_stuff_enabled = 0;
    const char     *confname = NULL;
    char           *dosrcname = NULL;
    char           *basename;
    const char * const getopt_string =
       "23456ABCcD:dE:e:F:f:H:hI:i::K:k::L:M:mNOo:P:qSsTt::u:VvwXx:U:Y"
       "gp"/*NOPs kept for compat (not documented in usage())*/;

    if (getenv("DOSEMU_INVOKED_NAME"))
	argv[0] = getenv("DOSEMU_INVOKED_NAME");
    basename = strrchr(argv[0], '/');   /* parse the program name */
    basename = basename ? basename + 1 : argv[0];

    dosemu_argc = argc;
    dosemu_argv = argv;
    if (dosemu_proc_self_exe == NULL)
	dosemu_proc_self_exe = dosemu_argv[0];

    memcheck_type_init();
    our_envs_init();
    parse_debugflags("+cw", 1);
    Video = NULL;

    /* options get parsed twice so show our own errors and only once */
    opterr = 0;
    if (strcmp(config_script_name, DEFAULT_CONFIG_SCRIPT))
      confname = config_script_path;
    while ((c = getopt(argc, argv, getopt_string)) != EOF) {
	switch (c) {
	case 's':
	    if (can_do_root_stuff)
		can_do_root_stuff_enabled = 1;
	    else
		error("The -s switch requires root privileges\n");
	    break;
	case 'h':
	    usage(basename);
	    exit(0);
	    break;
	case 'H': {
#ifdef USE_MHPDBG
	    dosdebug_flags = strtoul(optarg,0,0) & 255;
#else
	    error("debugger support not compiled in\n");
#endif
	    break;
            }
	case 'F':
	    if (get_orig_uid()) {
		FILE *f;
		if (!get_orig_euid()) {
		    /* we are running suid root as user */
		    fprintf(stderr, "Sorry, -F option not allowed here\n");
		    exit(1);
		}
		f=fopen(optarg, "r");
		if (!f) {
		  fprintf(stderr, "Sorry, no access to configuration script %s\n", optarg);
		  exit(1);
		}
		fclose(f);
	    }
	    confname = optarg;
	    break;
	case 'f':
	    {
		FILE *f;
		f=fopen(optarg, "r");
		if (!f) {
		  fprintf(stderr, "Sorry, no access to user configuration file %s\n", optarg);
		  exit(1);
		}
		fclose(f);
	        dosrcname = optarg;
	    }
	    break;
	case 'I':
	    assert(i_found < I_MAX);
	    commandline_statements = strdup(optarg);
	    if (commandline_statements[0] == '\'') {
		commandline_statements[0] = ' ';
		while (commandline_statements[strlen(commandline_statements) - 1] != '\'') {
		    commandline_statements = realloc(commandline_statements,
			    strlen(commandline_statements) + 1 +
			    strlen(argv[optind]) + 1);
		    strcat(commandline_statements, " ");
		    strcat(commandline_statements, argv[optind]);
		    optind++;
		    i_incr[i_found]++;
		}
		commandline_statements[strlen(commandline_statements) - 1] = 0;
	    }
	    i_found++;
	    break;
	case 'i':
	    if (optarg)
		config.install = optarg;
	    else
		config.install = "";
	    break;
	case 'd':
	    config.detach = 1;
	    break;
	case 'O':
	    fprintf(stderr, "using stderr for debug-output\n");
	    dbg_fd = stderr;
	    break;
	case 'o':
	    config.debugout = strdup(optarg);
	    break;
	case 'u': {
		char *s=malloc(strlen(optarg)+3);
		s[0]='u'; s[1]='_';
		strcpy(s+2,optarg);
		define_config_variable(s);
	    }
	    break;
	case 'v':
	    printf("dosemu2-" VERSTR "\n");
	    printf("Revision: %i\n", REVISION);
	    exit(0);
	}
    }

    if (!can_do_root_stuff_enabled)
	can_do_root_stuff = 0;
    else if (under_root_login)
    	fprintf(stderr,"\nRunning as root in full feature mode\n");
    else
    	fprintf(stderr,"\nRunning privileged (%s) in full feature mode\n",
		using_sudo ? "via sudo" : "suid-root");

    if (dbg_fd == 0) {
        if (config.debugout == NULL) {
            char *home = getenv("HOME");
            if (home) {
                const static char *debugout = "/.dosemu/boot.log";
                config.debugout = malloc(strlen(home) + strlen(debugout) + 1);
                strcpy(config.debugout, home);
                strcat(config.debugout, debugout);
            }
        }
        if (config.debugout != NULL) {
            dbg_fd = fopen(config.debugout, "w");
            if (!dbg_fd) {
                fprintf(stderr, "can't open \"%s\" for writing\n", config.debugout);
                exit(1);
            }
            setlinebuf(dbg_fd);
        }
    }

    if (config_check_only) set_debug_level('c',1);

    move_dosemu_lib_dir();
    parse_config(confname,dosrcname);

    if (config.exitearly && !config_check_only)
	exit(0);

    /* default settings before processing cmdline */
    config.exit_on_cmd = 1;

    i_cur = 0;
#ifdef __linux__
    optind = 0;
#endif
    opterr = 0;
    while ((c = getopt(argc, argv, getopt_string)) != EOF) {
	switch (c) {
	case 'F':		/* previously parsed config file argument */
	case 'f':
	case 'H':
	case 'i':
	case 'd':
	case 'o':
	case 'O':
	case 'L':
	case 'u':
	case 's':
	    break;
	case 'I':
	    assert(i_cur < i_found);
	    optind += i_incr[i_cur++];
	    break;
	case '2': case '3': case '4': case '5': case '6':
	    {
		int cpu = cpu_override (c-'0');
		if (cpu > 0) {
			fprintf(stderr,"CPU set to %d86\n",cpu);
			vm86s.cpu_type = cpu;
		}
		else
			fprintf(stderr,"error in CPU user override\n");
	    }
	    break;
	case 'g': /* obsolete "graphics" option */
	    break;
	case 'A':
	    config.hdiskboot = 0;
	    break;
	case 'B':
	    config.hdiskboot = 1;
	    break;
	case 'C':
	    config.hdiskboot = 2;
	    break;
	case 'c':
	    config.console_video = 1;
	    config.vga = 0;
	    break;
	case 'k':
	    if (optarg) {
		switch (optarg[0]) {
		case 's':
		    config.console_keyb = KEYB_STDIO;
		    break;
		case 't':
		    config.console_keyb = KEYB_TTY;
		    break;
		case 'r':
		    config.console_keyb = KEYB_RAW;
		    break;
		}
	    } else {
		config.console_keyb = KEYB_RAW;
	    }
	    break;
	case 't':
	    /* terminal mode */
	    config.X = config.console_video = 0;
	    config.term = 1;
	    if (optarg) {
		if (optarg[0] =='d')
		    config.dumb_video = 1;
	    }
	    break;
	case 'X':
	    config.X = 1;
	    break;
	case 'S':
	    config.sdl = 1;
	    config.sdl_sound = 1;
	    break;
	case 'w':
            config.X_fullscreen = !config.X_fullscreen;
	    break;
	case 'D':
	    parse_debugflags(optarg, 1);
	    break;
	case 'p':
	    /* unused */
	    break;
	case 'P':
	    if (terminal_fd == -1) {
		open_terminal_pipe(optarg);
	    } else
		error("terminal pipe already open\n");
	    break;
	case 'V':
	    g_printf("Configuring as VGA video card & mapped ROM\n");
	    config.vga = 1;
	    if (config.mem_size > 640)
		config.mem_size = 640;
	    break;
	case 'Y':
	    config.dos_trace = 1;
	    break;
	case 'N':
	    warn("DOS will not be started\n");
	    config.exitearly = 1;
	    break;

	case 'x':
	    config.xms_size = atoi(optarg);
	    x_printf("enabling %dK XMS memory\n", config.xms_size);
	    break;

	case 'e':
	    config.ems_size = atoi(optarg);
	    g_printf("enabling %dK EMS memory\n", config.ems_size);
	    break;

	case 'm':
	    g_printf("turning internal MOUSE driver %s\n",
		     config.mouse.intdrv ? "off" : "on");
	    config.mouse.intdrv = !config.mouse.intdrv;
	    break;

	case 'E':
	    g_printf("DOS command given on command line: %s\n", optarg);
	    config.dos_cmd = optarg;
	    break;
	case 'K':
	    g_printf("Unix path set to %s\n", optarg);
	    config.unix_path = optarg;
	    break;
	case 'U': {
	    int n;
	    sscanf(optarg, "%i%n", &config.cdup, &n);
	    if (n != strlen(optarg)) {
		fprintf(stderr, "Number expected after -U\n\r");
		exit(1);
	    }
	    break;
	}
	case 'T':
	    config.exit_on_cmd = 0;
	    break;
	case 'q':
	    config.quiet = 1;
	    break;

	case '?':
	default:
	    fprintf(stderr, "unrecognized option or missing argument: -%c\n\r", optopt);
	    usage(basename);
	    exit(1);
	}
    }
    /* make-style env vars passing */
    while (optind < argc) {
	if (strchr(argv[optind], '=') == NULL) {
	    fprintf(stderr, "unrecognized argument: %s\n\r", argv[optind]);
	    fprintf(stderr, "For passing DOS command use -E\n\r");
	    exit(1);
	}
	g_printf("DOS command given on command line: %s\n", argv[optind]);
	misc_e6_store_options(argv[optind]);
	optind++;
    }
    config_post_process();
    config_scrub();
    if (config_check_only) {
	dump_config_status(0);
	usage(basename);
	exit(1);
    } else {
	if (debug_level('c') >= 8)
	    dump_config_status(log_dump_printf);
    }
}


static void
check_for_env_autoexec_or_config(void)
{
    char           *cp;
    cp = getenv("CONFIG");
    if (cp) {
	free(config.emusys);
	config.emusys = strdup(cp);
    }


     /*
      * The below is already reported in the conf. It is in no way an error
      * so why the messages?
      */

#if 0
    if (config.emusys)
	fprintf(stderr, "config extension = %s\n", config.emusys);
#endif
}

/*
 * Please keep "getopt_string", secure_option_preparse(), config_init(),
 * usage() and the manpage in sync!
 */
static void
usage(char *basename)
{
    fprintf(stderr,
	"dosemu-" VERSTR "\n\n"
	"USAGE:\n"
	"  %s [options] [ [-E] linux path or dos command ]\n"
	"\n"
	"    -2,3,4,5,6 choose 286, 386, 486 or 586 or 686 CPU\n"
	"    -A boot from first defined floppy disk (A)\n"
	"    -B boot from second defined floppy disk (B) (#)\n"
	"    -C boot from first defined hard disk (C)\n"
	"    -c use PC console video (!%%)\n"
	"    -d detach console\n"
	"    -X run in X Window (#)\n"
	"    -S run in SDL (#)\n"
    , basename);
    print_debug_usage(stderr);
    fprintf(stderr,
	"    -E STRING pass DOS command on command line\n"
	"    -e SIZE enable SIZE K EMS RAM\n"
	"    -F use File as global config-file\n"
	"    -f use dosrcFile as user config-file\n"
	"    --Fusers bypass /etc/dosemu.users (^^)\n"
	"    --Flibdir change keymap and FreeDOS location\n"
	"    --Fimagedir bypass systemwide boot path\n"
	"    -n bypass the system configuration file (^^)\n"
	"    -L load and execute DEXE File\n"
	"    -I insert config statements (on commandline)\n"
	"    -i[bootdir] (re-)install a DOS from bootdir or interactively\n"
	"    -h display this help\n"
	"    -H wait for dosdebug terminal at startup and pass dflags\n"
	"    -k use PC console keyboard (!)\n"
	"    -M set memory size to SIZE kilobytes (!)\n"
	"    -m toggle internal mouse driver\n"
	"    -N No boot of DOS\n"
	"    -O write debug messages to stderr\n"
	"    -o FILE put debug messages in file\n"
	"    -P copy debugging output to FILE\n"
	"    -p stop for prompting with a non-fatal configuration problem\n"
	"    -s enable direct hardware access (full feature) (!%%)\n"
	"    -T don't exit after executing -E command\n"
	"    -t use terminal (S-Lang) mode\n"
	"    -u set user configuration variable 'confvar' prefixed by 'u_'.\n"
	"    -V use BIOS-VGA video modes (!#%%)\n"
	"    -v display version\n"
	"    -w toggle windowed/fullscreen mode in X\n"
	"    -x SIZE enable SIZE K XMS RAM\n"
	"\n"
	"    (!) BE CAREFUL! READ THE DOCS FIRST!\n"
	"    (%%) require DOSEMU be run as root (i.e. suid)\n"
	"    (^^) require DOSEMU not be run as root (i.e. not suid)\n"
	"    (#) options do not fully work yet\n"
	"\n");
    if(!strcmp (basename, "dos") || !strcmp (basename, "dosemu")) {
        fprintf (stderr,
            "  x%s [options]   == %s [options] -X\n"
            "\n",
            basename, basename);
    }
    fprintf(stderr,
	"  %s --help\n"
	"  %s --version    print version of dosemu (and show this help)\n",
        basename, basename);
}
